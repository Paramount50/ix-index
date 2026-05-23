use std::{
    collections::{BTreeMap, VecDeque},
    env,
    net::SocketAddr,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail};
use axum::{
    Json, Router,
    extract::State,
    response::{
        IntoResponse,
        sse::{Event, KeepAlive, Sse},
    },
    routing::get,
};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use clap::{Args, Parser, Subcommand};
use futures::{stream, stream::Stream};
use loro::{ExportMode, LoroDoc, ToJson};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::Command,
    sync::{Mutex, broadcast},
};
use tower_http::services::{ServeDir, ServeFile};

#[derive(Parser)]
#[command(
    version,
    about = "Run agent loops and health checks with a Loro-backed web view"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<CommandMode>,

    #[command(flatten)]
    loop_args: LoopArgs,
}

#[derive(Subcommand)]
enum CommandMode {
    HealthChecksLoro(HealthChecksArgs),
}

#[derive(Args, Clone)]
struct LoopArgs {
    #[arg(long, default_value = "main")]
    branch: String,

    #[arg(long)]
    prompt: Option<String>,

    #[arg(long)]
    prompt_file: Option<PathBuf>,

    #[arg(long, default_value = "loop: improve repo quality")]
    commit_message: String,

    #[arg(long)]
    lint_program: Vec<PathBuf>,

    #[arg(long, default_value = "codex")]
    agent_program: PathBuf,

    #[arg(long, default_value = "xhigh")]
    reasoning_effort: String,

    #[arg(long, default_value_t = true)]
    bypass_sandbox: bool,

    #[arg(long)]
    iterations: Option<u64>,

    #[arg(long, default_value_t = 30)]
    sleep_secs: u64,

    #[arg(long)]
    once: bool,

    #[arg(long, default_value_t = 7878)]
    port: u16,

    #[arg(long, env = "LOOP_VIEWER_DIR")]
    viewer_dir: PathBuf,
}

#[derive(Args)]
struct HealthChecksArgs {
    spec: PathBuf,

    #[arg(long, default_value_t = 7879)]
    port: u16,

    #[arg(long, env = "LOOP_VIEWER_DIR")]
    viewer_dir: PathBuf,
}

#[derive(Clone)]
struct AppState {
    doc: Arc<Mutex<LoroDoc>>,
    lines: Arc<Mutex<VecDeque<String>>>,
    tx: broadcast::Sender<String>,
}

#[derive(Serialize)]
struct StatePayload {
    json: Value,
    snapshot: String,
    lines: Vec<String>,
}

#[derive(Deserialize)]
struct DagSpec {
    nodes: BTreeMap<String, DagNode>,
}

#[derive(Deserialize)]
struct DagNode {
    command: Vec<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Some(CommandMode::HealthChecksLoro(args)) => run_health_checks(args).await,
        None => run_agent_loop(cli.loop_args).await,
    }
}

async fn run_agent_loop(args: LoopArgs) -> Result<()> {
    let state = AppState::new()?;
    let addr = serve(state.clone(), args.port, args.viewer_dir.clone()).await?;
    publish(
        &state,
        json!({"kind": "server", "url": format!("http://{addr}")}),
    )
    .await?;
    println!("loop: web ui at http://{}:{}", web_host(), args.port);

    let runner = tokio::spawn(agent_loop(args, state.clone()));
    tokio::select! {
        result = runner => result??,
        signal = tokio::signal::ctrl_c() => signal.context("wait for Ctrl-C")?,
    }

    Ok(())
}

async fn run_health_checks(args: HealthChecksArgs) -> Result<()> {
    let state = AppState::new()?;
    let addr = serve(state.clone(), args.port, args.viewer_dir.clone()).await?;
    publish(
        &state,
        json!({"kind": "server", "url": format!("http://{addr}"), "mode": "health-checks-loro"}),
    )
    .await?;
    println!(
        "health-checks-loro: web ui at http://{}:{}",
        web_host(),
        args.port
    );

    let spec: DagSpec = serde_json::from_slice(
        &tokio::fs::read(&args.spec)
            .await
            .with_context(|| format!("read {}", args.spec.display()))?,
    )
    .context("parse health-check DAG")?;

    let mut handles = Vec::new();
    for (name, node) in spec.nodes {
        let state = state.clone();
        handles.push(tokio::spawn(async move {
            run_health_node(state, name, node.command).await
        }));
    }

    let mut worst_status = 0;
    for handle in handles {
        let status = handle.await??;
        worst_status = worst_status.max(status);
    }

    publish(
        &state,
        json!({"kind": "health-checks-complete", "exit_code": worst_status}),
    )
    .await?;

    if worst_status == 0 {
        Ok(())
    } else {
        std::process::exit(worst_status);
    }
}

async fn agent_loop(args: LoopArgs, state: AppState) -> Result<()> {
    let prompt = resolve_prompt(&args).await?;
    let lint_program = args
        .lint_program
        .last()
        .cloned()
        .context("--lint-program is required")?;
    let max_iterations = if args.once { Some(1) } else { args.iterations };
    let mut iteration = 1;

    loop {
        if max_iterations.is_some_and(|max| iteration > max) {
            return Ok(());
        }

        publish(
            &state,
            json!({"kind": "iteration-start", "iteration": iteration}),
        )
        .await?;
        ensure_branch(&args.branch).await?;
        ensure_clean().await?;
        git(&["fetch", "origin", &args.branch]).await?;
        git(&["merge", "--ff-only", &format!("origin/{}", args.branch)]).await?;

        let status = run_agent(&args, &prompt, &state).await?;
        if status != 0 {
            bail!("{} exited {status}", args.agent_program.display());
        }

        let paths = changed_paths().await?;
        if paths.is_empty() {
            publish(
                &state,
                json!({"kind": "iteration-clean", "iteration": iteration}),
            )
            .await?;
        } else {
            let lint_status =
                run_streamed(&lint_program, &[], &state, "lint", StreamMode::Lines).await?;
            if lint_status != 0 {
                bail!("lint failed ({lint_status})");
            }

            commit(&args.commit_message, &paths).await?;
            git(&["push", "origin", &args.branch]).await?;
            publish(
                &state,
                json!({"kind": "pushed", "iteration": iteration, "path_count": paths.len()}),
            )
            .await?;
        }

        iteration += 1;
        if max_iterations.is_none() && args.sleep_secs > 0 {
            tokio::time::sleep(std::time::Duration::from_secs(args.sleep_secs)).await;
        }
    }
}

async fn run_agent(args: &LoopArgs, prompt: &str, state: &AppState) -> Result<i32> {
    let is_codex = args
        .agent_program
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == "codex");

    let command_args = if is_codex {
        codex_argv(args, prompt).await?
    } else {
        vec![prompt.to_owned()]
    };

    run_streamed(
        &args.agent_program,
        &command_args,
        state,
        "agent",
        if is_codex {
            StreamMode::CodexJson
        } else {
            StreamMode::Lines
        },
    )
    .await
}

async fn codex_argv(args: &LoopArgs, prompt: &str) -> Result<Vec<String>> {
    let mut command_args = vec![
        "exec".to_owned(),
        "--json".to_owned(),
        "--enable".to_owned(),
        "goals".to_owned(),
        "--cd".to_owned(),
        ".".to_owned(),
        "-c".to_owned(),
        format!("model_reasoning_effort=\"{}\"", args.reasoning_effort),
        "-c".to_owned(),
        "model_reasoning_summary=\"auto\"".to_owned(),
    ];

    if let Some((name, email)) = git_user().await? {
        command_args.extend([
            "-c".to_owned(),
            "features.codex_git_commit=true".to_owned(),
            "-c".to_owned(),
            format!("commit_attribution.name=\"{}\"", escape_toml_string(&name)),
            "-c".to_owned(),
            format!(
                "commit_attribution.email=\"{}\"",
                escape_toml_string(&email)
            ),
        ]);
    }

    if args.bypass_sandbox {
        command_args.push("--dangerously-bypass-approvals-and-sandbox".to_owned());
    }

    command_args.push(codex_goal_prompt(prompt));
    Ok(command_args)
}

fn codex_goal_prompt(prompt: &str) -> String {
    format!(
        "\
Run this task as a Codex goal-backed non-interactive task.

Before doing substantive work:
1. Call create_goal with a concise objective derived from the task below.
2. Call get_goal.
3. If get_goal returns no active goal, print GOAL_NOT_CREATED and stop.
4. If get_goal shows an active goal, continue working toward that goal.

Use the goal tools directly. Do not write a /goal command as prose.
Before the final answer, call update_goal(status=\"complete\") only when the objective is achieved and no required work remains.

Task:
{prompt}"
    )
}

async fn run_health_node(state: AppState, name: String, command: Vec<String>) -> Result<i32> {
    if command.is_empty() {
        bail!("health-check node {name} has an empty command");
    }

    publish(&state, json!({"kind": "node-start", "node": name})).await?;
    let program = PathBuf::from(&command[0]);
    let args = command[1..].to_vec();
    let status = run_streamed(&program, &args, &state, &name, StreamMode::Lines).await?;
    publish(
        &state,
        json!({"kind": "node-finish", "node": name, "exit_code": status}),
    )
    .await?;
    Ok(status)
}

async fn run_streamed(
    program: &Path,
    args: &[String],
    state: &AppState,
    stream_name: &str,
    mode: StreamMode,
) -> Result<i32> {
    publish(
        state,
        json!({"kind": "process-start", "name": stream_name, "program": program.display().to_string(), "args": args}),
    )
    .await?;

    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .envs(identity_env().await?)
        .spawn()
        .with_context(|| format!("spawn {}", program.display()))?;

    let stdout = child.stdout.take().context("take child stdout")?;
    let stderr = child.stderr.take().context("take child stderr")?;
    let state_stdout = state.clone();
    let state_stderr = state.clone();
    let name_stdout = stream_name.to_owned();
    let name_stderr = stream_name.to_owned();

    let stdout_task = tokio::spawn(async move {
        stream_lines(state_stdout, name_stdout, "stdout", stdout, mode).await
    });
    let stderr_task = tokio::spawn(async move {
        stream_lines(state_stderr, name_stderr, "stderr", stderr, mode).await
    });

    let status = child.wait().await.context("wait for child")?;
    stdout_task.await??;
    stderr_task.await??;
    let code = status.code().unwrap_or(1);
    publish(
        state,
        json!({"kind": "process-finish", "name": stream_name, "exit_code": code}),
    )
    .await?;
    Ok(code)
}

#[derive(Clone, Copy)]
enum StreamMode {
    Lines,
    CodexJson,
}

async fn stream_lines<R>(
    state: AppState,
    name: String,
    stream: &str,
    reader: R,
    mode: StreamMode,
) -> Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    while let Some(line) = lines.next_line().await? {
        let event = match mode {
            StreamMode::Lines => {
                json!({"kind": "line", "name": name, "stream": stream, "text": line})
            }
            StreamMode::CodexJson => codex_event(&name, stream, &line),
        };

        publish(&state, event).await?;
    }

    Ok(())
}

fn codex_event(name: &str, stream: &str, line: &str) -> Value {
    let Ok(raw) = serde_json::from_str::<Value>(line) else {
        return json!({"kind": "line", "name": name, "stream": stream, "text": line});
    };
    let Ok(event) = serde_json::from_value::<CodexJsonEvent>(raw.clone()) else {
        return json!({"kind": "line", "name": name, "stream": stream, "text": line});
    };

    let codex_kind = event.kind.as_deref().unwrap_or("event");
    let (category, text) = event.classify(&raw);

    json!({
        "kind": format!("codex-{codex_kind}"),
        "name": name,
        "stream": stream,
        "category": category,
        "text": text,
        "event": raw,
    })
}

#[derive(Deserialize)]
struct CodexJsonEvent {
    #[serde(alias = "type", alias = "kind")]
    kind: Option<String>,
    text: Option<String>,
    message: Option<String>,
    content: Option<String>,
    delta: Option<String>,
    summary: Option<Value>,
    input: Option<String>,
    aggregated_output: Option<String>,
    #[serde(alias = "cmd", alias = "command")]
    command: Option<CodexCommand>,
    item: Option<Box<Self>>,
    payload: Option<Box<Self>>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum CodexCommand {
    Args(Vec<String>),
    Text(String),
    Json(Value),
}

impl CodexJsonEvent {
    fn classify(&self, raw: &Value) -> (&'static str, String) {
        if let Some(item) = self.item.as_ref() {
            return item.classify(raw);
        }
        let item_type = self.kind.as_deref().unwrap_or("");
        match item_type {
            "command_execution" | "exec_command" | "exec" => {
                ("shell", self.text().unwrap_or_else(|| raw.to_string()))
            }
            "agent_message" | "message" => {
                ("message", self.text().unwrap_or_else(|| raw.to_string()))
            }
            "reasoning" | "agent_reasoning" => (
                "reasoning",
                self.text()
                    .or_else(|| self.summary_text())
                    .unwrap_or_else(|| raw.to_string()),
            ),
            "apply_patch" | "patch_apply" | "file_change" => (
                "patch",
                self.text()
                    .or_else(|| self.input.clone())
                    .unwrap_or_else(|| raw.to_string()),
            ),
            "web_search_call" | "web_search" => (
                "tool",
                self.text().unwrap_or_else(|| "web_search".to_owned()),
            ),
            "custom_tool_call" | "function_call" => {
                ("tool", self.text().unwrap_or_else(|| raw.to_string()))
            }
            _ => ("event", self.text().unwrap_or_else(|| raw.to_string())),
        }
    }

    fn text(&self) -> Option<String> {
        [
            self.text.as_deref(),
            self.message.as_deref(),
            self.content.as_deref(),
            self.delta.as_deref(),
            self.aggregated_output.as_deref(),
        ]
        .into_iter()
        .flatten()
        .find(|value| !value.is_empty())
        .map(str::to_owned)
        .or_else(|| self.command.as_ref().map(CodexCommand::text))
        .or_else(|| self.input.clone())
        .or_else(|| self.item.as_ref().and_then(|item| item.text()))
        .or_else(|| self.payload.as_ref().and_then(|payload| payload.text()))
    }

    fn summary_text(&self) -> Option<String> {
        let summary = self.summary.as_ref()?;
        match summary {
            Value::String(text) if !text.is_empty() => Some(text.clone()),
            Value::Array(items) => {
                let joined: Vec<String> = items
                    .iter()
                    .filter_map(|entry| match entry {
                        Value::String(text) => Some(text.clone()),
                        Value::Object(map) => {
                            map.get("text").and_then(Value::as_str).map(str::to_owned)
                        }
                        _ => None,
                    })
                    .filter(|value| !value.is_empty())
                    .collect();
                (!joined.is_empty()).then(|| joined.join("\n\n"))
            }
            _ => None,
        }
    }
}

impl CodexCommand {
    fn text(&self) -> String {
        match self {
            Self::Args(parts) => parts.join(" "),
            Self::Text(command) => command.to_owned(),
            Self::Json(command) => command.to_string(),
        }
    }
}

async fn serve(state: AppState, port: u16, viewer_dir: PathBuf) -> Result<SocketAddr> {
    let index = viewer_dir.join("index.html");
    let app = Router::new()
        .route("/api/state", get(api_state))
        .route("/events", get(events))
        .fallback_service(ServeDir::new(viewer_dir).fallback(ServeFile::new(index)))
        .with_state(state);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    let local_addr = listener.local_addr()?;
    tokio::spawn(async move {
        if let Err(err) = axum::serve(listener, app).await {
            eprintln!("loop: web server failed: {err:#}");
        }
    });
    Ok(local_addr)
}

async fn api_state(State(state): State<AppState>) -> Result<Json<StatePayload>, AppError> {
    let doc = state.doc.lock().await;
    let snapshot = doc
        .export(ExportMode::Snapshot)
        .map_err(|err| AppError(anyhow!(err)))?;
    let json = doc.get_deep_value().to_json_value();
    drop(doc);

    let lines = state.lines.lock().await.iter().cloned().collect();
    Ok(Json(StatePayload {
        json,
        snapshot: BASE64.encode(snapshot),
        lines,
    }))
}

async fn events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, std::convert::Infallible>>> {
    let stream = stream::unfold(state.tx.subscribe(), |mut rx| async move {
        loop {
            match rx.recv().await {
                Ok(data) => return Some((Ok(Event::default().event("loro").data(data)), rx)),
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => return None,
            }
        }
    });

    Sse::new(stream).keep_alive(KeepAlive::default())
}

async fn publish(state: &AppState, mut event: Value) -> Result<()> {
    event["ts_ms"] = json!(now_ms()?);
    let line = serde_json::to_string(&event)?;

    {
        let mut lines = state.lines.lock().await;
        lines.push_back(line.clone());
        while lines.len() > 500 {
            lines.pop_front();
        }
        drop(lines);
    }

    {
        let doc = state.doc.lock().await;
        let events = doc.get_list("events");
        events.insert(events.len(), event)?;
        doc.commit();
    }

    let _ = state.tx.send(line);
    Ok(())
}

impl AppState {
    fn new() -> Result<Self> {
        let doc = LoroDoc::new();
        doc.set_peer_id(1)?;
        Ok(Self {
            doc: Arc::new(Mutex::new(doc)),
            lines: Arc::new(Mutex::new(VecDeque::new())),
            tx: broadcast::channel(1024).0,
        })
    }
}

#[derive(Debug)]
struct AppError(anyhow::Error);

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            self.0.to_string(),
        )
            .into_response()
    }
}

impl<E> From<E> for AppError
where
    E: Into<anyhow::Error>,
{
    fn from(value: E) -> Self {
        Self(value.into())
    }
}

async fn resolve_prompt(args: &LoopArgs) -> Result<String> {
    if let Some(prompt) = &args.prompt {
        return Ok(prompt.clone());
    }

    if let Some(path) = &args.prompt_file {
        return read_prompt(path).await;
    }

    if let Some(path) = env::var_os("LOOP_PROMPT_FILE") {
        return read_prompt(Path::new(&path)).await;
    }

    let default = Path::new("loop-prompt.md");
    if default.exists() {
        return read_prompt(default).await;
    }

    bail!(
        "no prompt provided. pass --prompt, --prompt-file, set LOOP_PROMPT_FILE, or create loop-prompt.md"
    );
}

async fn read_prompt(path: &Path) -> Result<String> {
    Ok(tokio::fs::read_to_string(path)
        .await
        .with_context(|| format!("read {}", path.display()))?
        .trim()
        .to_owned())
}

async fn ensure_branch(expected: &str) -> Result<()> {
    let branch = git_output(&["branch", "--show-current"]).await?;
    if branch.trim() == expected {
        Ok(())
    } else {
        bail!("expected branch {expected}, found {}", branch.trim());
    }
}

async fn ensure_clean() -> Result<()> {
    let status = git_output(&["status", "--porcelain"]).await?;
    if status.trim().is_empty() {
        Ok(())
    } else {
        bail!("working tree dirty before agent starts");
    }
}

async fn changed_paths() -> Result<Vec<String>> {
    Ok(git_output(&["status", "--porcelain"])
        .await?
        .lines()
        .filter_map(|line| line.get(3..))
        .map(str::to_owned)
        .collect())
}

async fn commit(message: &str, paths: &[String]) -> Result<()> {
    let mut add_args = vec!["add".to_owned(), "--".to_owned()];
    add_args.extend(paths.iter().cloned());
    git_owned(&add_args).await?;

    let mut args = vec![
        "commit".to_owned(),
        "-m".to_owned(),
        message.to_owned(),
        "--".to_owned(),
    ];
    args.extend(paths.iter().cloned());
    git_owned(&args).await
}

async fn git_user() -> Result<Option<(String, String)>> {
    let name = git_output(&["config", "--get", "user.name"]).await.ok();
    let email = git_output(&["config", "--get", "user.email"]).await.ok();
    Ok(match (name, email) {
        (Some(name), Some(email)) => Some((name.trim().to_owned(), email.trim().to_owned())),
        _ => None,
    })
}

async fn identity_env() -> Result<Vec<(String, String)>> {
    let Some((name, email)) = git_user().await? else {
        return Ok(Vec::new());
    };

    Ok(vec![
        ("GIT_AUTHOR_NAME".to_owned(), name.clone()),
        ("GIT_COMMITTER_NAME".to_owned(), name),
        ("GIT_AUTHOR_EMAIL".to_owned(), email.clone()),
        ("GIT_COMMITTER_EMAIL".to_owned(), email),
    ])
}

async fn git(args: &[&str]) -> Result<()> {
    let output = Command::new("git").args(args).output().await?;
    if output.status.success() {
        Ok(())
    } else {
        bail!("{}", String::from_utf8_lossy(&output.stderr));
    }
}

async fn git_owned(args: &[String]) -> Result<()> {
    let output = Command::new("git").args(args).output().await?;
    if output.status.success() {
        Ok(())
    } else {
        bail!("{}", String::from_utf8_lossy(&output.stderr));
    }
}

async fn git_output(args: &[&str]) -> Result<String> {
    let output = Command::new("git").args(args).output().await?;
    if output.status.success() {
        Ok(String::from_utf8(output.stdout)?)
    } else {
        Err(anyhow!("{}", String::from_utf8_lossy(&output.stderr)))
    }
}

fn escape_toml_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn web_host() -> String {
    hostname_from_env().unwrap_or_else(|| "localhost".to_owned())
}

fn hostname_from_env() -> Option<String> {
    env::var("HOSTNAME").ok().filter(|name| !name.is_empty())
}

fn now_ms() -> Result<u128> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_goal_prompt_requests_goal_tools_without_replacing_task() {
        let wrapped = codex_goal_prompt("fix the loop package");

        assert!(wrapped.contains("Call create_goal"));
        assert!(wrapped.contains("Call get_goal"));
        assert!(wrapped.contains("GOAL_NOT_CREATED"));
        assert!(wrapped.contains("update_goal(status=\"complete\")"));
        assert!(wrapped.contains("fix the loop package"));
    }
}
