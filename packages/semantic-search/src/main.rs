//! `semantic-search`: a daemon-free, content-addressed semantic code search.
//!
//! Every run rebuilds a local manifest (cheap; unchanged files are not
//! re-hashed), uploads only content the store is missing, waits for it to
//! embed, then searches. No daemon, no `--sync` flag: new files are picked up
//! and embedded automatically at search time. `--no-sync` skips that for a pure
//! offline search. Results are scoped to the current checkout via the manifest.

use std::io::IsTerminal as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use clap::Parser;
use indicatif::{ProgressBar, ProgressStyle};
use semantic_search_core::{
    Config, DEFAULT_STORE, DisplayHit, MixedbreadStore, Query, SearchOptions, StoreStatus,
};

/// How long to wait for freshly uploaded files to finish embedding.
const INDEX_TIMEOUT: Duration = Duration::from_mins(2);

/// Command-line arguments. Flags mirror `mgrep search` where they overlap.
// A CLI naturally has many independent boolean flags; a state machine would
// obscure, not clarify, the argument surface.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Parser)]
#[command(name = "semantic-search", about, version)]
struct Cli {
    /// The query to search for.
    pattern: String,

    /// Directory to search in (defaults to the current directory).
    path: Option<String>,

    /// Maximum number of results to return.
    #[arg(short = 'm', long = "max-count", default_value_t = 10)]
    max_count: usize,

    /// Show the matched content under each result.
    #[arg(short = 'c', long)]
    content: bool,

    /// Synthesize an answer from the results instead of listing them.
    #[arg(short = 'a', long)]
    answer: bool,

    /// Search the store as-is: skip detecting and embedding new files.
    #[arg(long = "no-sync")]
    no_sync: bool,

    /// Disable result reranking (on by default).
    #[arg(long = "no-rerank")]
    no_rerank: bool,

    /// Include web results from the hosted web store.
    #[arg(short = 'w', long)]
    web: bool,

    /// Let the backend plan and run multiple searches.
    #[arg(long)]
    agentic: bool,

    /// Store name (one store holds every worktree's content).
    #[arg(long, env = "MXBAI_STORE")]
    store: Option<String>,

    /// Mixedbread API base URL.
    #[arg(long = "base-url", env = "MXBAI_BASE_URL")]
    base_url: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    run(Cli::parse()).await
}

async fn run(cli: Cli) -> anyhow::Result<()> {
    let root = resolve_root(cli.path.as_deref())?;
    anyhow::ensure!(
        !at_or_above_home(&root),
        "refusing to index {} (it is at or above your home directory); run from a project directory",
        root.display(),
    );

    let config = Config::default();
    let store_name = cli.store.unwrap_or_else(|| DEFAULT_STORE.to_owned());
    let base_url = cli
        .base_url
        .unwrap_or_else(|| mixedbread::DEFAULT_BASE_URL.to_owned());
    let store = MixedbreadStore::from_login(base_url).await?;

    let query = Query {
        root: &root,
        store_name: &store_name,
        text: &cli.pattern,
        top_k: cli.max_count.max(1),
        options: SearchOptions {
            rerank: !cli.no_rerank,
            agentic: cli.agentic,
        },
        sync: !cli.no_sync,
        include_web: cli.web,
        index_timeout: INDEX_TIMEOUT,
    };

    // Progress UI, terminal only: an upload bar that flips to an embedding
    // spinner on the first poll. Piped output stays clean (no bar).
    let bar = std::io::stderr()
        .is_terminal()
        .then(ProgressBar::new_spinner);
    if let Some(bar) = &bar {
        bar.set_style(upload_style());
    }
    let embedding = AtomicBool::new(false);
    // Captured during upload so the embedding bar knows its length: the number
    // of files uploaded is exactly the number that will embed.
    let embed_total = AtomicU64::new(0);
    let on_upload = |done: usize, total: usize| {
        if let (Some(bar), true) = (&bar, total > 0) {
            let total = u64::try_from(total).unwrap_or(u64::MAX);
            embed_total.store(total, Ordering::Relaxed);
            bar.set_length(total);
            bar.set_position(u64::try_from(done).unwrap_or(u64::MAX));
        }
    };
    let on_poll = |status: StoreStatus| {
        if let Some(bar) = &bar {
            let len = embed_total.load(Ordering::Relaxed);
            if !embedding.swap(true, Ordering::Relaxed) {
                bar.set_style(embed_style());
                bar.set_length(len);
                bar.enable_steady_tick(Duration::from_millis(120));
            }
            // store_status is store-wide, so the pending count can exceed our
            // batch; clamp to len so the bar never reads past full.
            let remaining = (status.pending + status.in_progress).min(len);
            bar.set_position(len - remaining);
        }
    };

    if cli.answer {
        let view =
            semantic_search_core::index_and_answer(&store, &query, &config, on_upload, on_poll)
                .await?;
        if let Some(bar) = &bar {
            bar.finish_and_clear();
        }
        println!("{}", view.answer);
        if !view.sources.is_empty() {
            println!();
            for (index, hit) in view.sources.iter().enumerate() {
                println!("{index}: {}", render(hit, cli.content));
            }
        }
    } else {
        let hits =
            semantic_search_core::index_and_search(&store, &query, &config, on_upload, on_poll)
                .await?;
        if let Some(bar) = &bar {
            bar.finish_and_clear();
        }
        for hit in &hits {
            println!("{}", render(hit, cli.content));
        }
    }

    Ok(())
}

fn upload_style() -> ProgressStyle {
    ProgressStyle::with_template(
        "{spinner:.green} indexing {pos}/{len} files {wide_bar:.cyan/blue} {elapsed}",
    )
    .expect("valid progress template")
    .progress_chars("=>-")
}

fn embed_style() -> ProgressStyle {
    ProgressStyle::with_template(
        "{spinner:.green} embedding {pos}/{len} files {wide_bar:.magenta/blue} {elapsed}",
    )
    .expect("valid progress template")
    .progress_chars("=>-")
}

fn resolve_root(path: Option<&str>) -> anyhow::Result<PathBuf> {
    let cwd = std::env::current_dir()?;
    let root = match path {
        Some(p) if Path::new(p).is_absolute() => PathBuf::from(p),
        Some(p) => cwd.join(p),
        None => cwd,
    };
    Ok(root.canonicalize().unwrap_or(root))
}

fn at_or_above_home(path: &Path) -> bool {
    let Some(home) = dirs::home_dir() else {
        return false;
    };
    let home = home.canonicalize().unwrap_or(home);
    path == home || home.starts_with(path)
}

fn render(hit: &DisplayHit, show_content: bool) -> String {
    let location = match (hit.start_line, hit.num_lines) {
        (Some(start), Some(num)) => format!(":{}-{}", start + 1, start + 1 + num),
        (Some(start), None) => format!(":{}", start + 1),
        _ => String::new(),
    };
    let prefix = if hit.is_web { "" } else { "./" };
    let percent = hit.score * 100.0;
    let head = format!("{prefix}{}{location} ({percent:.2}% match)", hit.label);
    if show_content && !hit.text.is_empty() {
        format!("{head}\n{}", hit.text)
    } else {
        head
    }
}
