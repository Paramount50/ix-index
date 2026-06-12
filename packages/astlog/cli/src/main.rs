//! Thin CLI over `astlog-core`: evaluate a rules file against paths, print
//! derived relations or apply rewrites.

use std::path::PathBuf;
use std::process::ExitCode;

use astlog_core::{Analysis, Value};
use clap::{Parser, Subcommand};
use snafu::{ResultExt as _, Snafu};

#[derive(Parser)]
#[command(name = "astlog", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Evaluate rules and print derived relations.
    Query {
        /// Rules file (`.astlog`).
        rules: PathBuf,
        /// Files or directories to load (directories walk gitignore-aware).
        #[arg(required = true)]
        paths: Vec<PathBuf>,
        /// Print only this relation.
        #[arg(long)]
        relation: Option<String>,
        /// Emit JSON instead of text.
        #[arg(long)]
        json: bool,
        /// Exit nonzero when this relation derived any row (repeatable).
        /// Turns a rules file into a lint gate for CI.
        #[arg(long)]
        deny: Vec<String>,
        /// Deny every relation the rules file defines, so adding a rule
        /// extends the lint gate without touching the invocation.
        #[arg(long)]
        deny_all: bool,
    },
    /// Evaluate rules and apply `(rewrite ...)` edits.
    Fix {
        /// Rules file (`.astlog`).
        rules: PathBuf,
        /// Files or directories to load.
        #[arg(required = true)]
        paths: Vec<PathBuf>,
        /// Write changes to disk instead of printing the diff.
        #[arg(long)]
        write: bool,
    },
}

#[derive(Debug, Snafu)]
enum Error {
    #[snafu(display("read rules {}", path.display()))]
    ReadRules {
        path: PathBuf,
        source: std::io::Error,
    },

    #[snafu(transparent)]
    Core { source: astlog_core::Error },

    #[snafu(display("relation `{name}` is not defined; available: {available}"))]
    NoRelation { name: String, available: String },

    #[snafu(display("write {}", path.display()))]
    WriteFixed {
        path: PathBuf,
        source: std::io::Error,
    },

    #[snafu(display("denied: {findings}"))]
    Denied { findings: String },
}

fn main() -> ExitCode {
    match run(&Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let mut message = error.to_string();
            let mut source = std::error::Error::source(&error);
            while let Some(cause) = source {
                message.push_str(": ");
                message.push_str(&cause.to_string());
                source = cause.source();
            }
            eprintln!("astlog: {message}");
            ExitCode::FAILURE
        }
    }
}

fn run(cli: &Cli) -> Result<(), Error> {
    match &cli.command {
        Command::Query {
            rules,
            paths,
            relation,
            json,
            deny,
            deny_all,
        } => {
            let analysis = load(rules, paths)?;
            let selected = select(&analysis, relation.as_deref())?;
            if *json {
                print_json(&analysis, &selected);
            } else {
                print_text(&analysis, &selected);
            }
            let denied = effective_deny(deny, *deny_all, analysis.database.relations.keys());
            check_denied(&analysis, &denied)
        }
        Command::Fix {
            rules,
            paths,
            write,
        } => {
            let analysis = load(rules, paths)?;
            if *write {
                for fixed in analysis.rewritten() {
                    std::fs::write(&fixed.path, fixed.content)
                        .context(WriteFixedSnafu { path: &fixed.path })?;
                }
                eprintln!("astlog: applied {} edit(s)", analysis.edits.len());
            } else {
                print!("{}", analysis.diff());
            }
            Ok(())
        }
    }
}

fn load(rules: &PathBuf, paths: &[PathBuf]) -> Result<Analysis, Error> {
    let source = std::fs::read_to_string(rules).context(ReadRulesSnafu { path: rules })?;
    Ok(astlog_core::analyze(&source, paths)?)
}

/// The deny list a query run enforces: the explicit `--deny` names, extended
/// by every defined relation when `--deny-all` is set. Names stay
/// deduplicated and sorted by first appearance so failure output is stable.
fn effective_deny<'a>(
    deny: &[String],
    deny_all: bool,
    relations: impl Iterator<Item = &'a String>,
) -> Vec<String> {
    let mut denied: Vec<String> = deny.to_vec();
    if deny_all {
        for name in relations {
            if !denied.contains(name) {
                denied.push(name.clone());
            }
        }
    }
    denied
}

/// Fail when any `--deny` relation derived rows, naming each with its count.
/// A `--deny` name that no rule defines is itself an error, never a silent pass.
fn check_denied(analysis: &Analysis, deny: &[String]) -> Result<(), Error> {
    let mut findings = Vec::new();
    for name in deny {
        let relation = analysis.database.relations.get(name).ok_or_else(|| {
            NoRelationSnafu {
                name,
                available: analysis
                    .database
                    .relations
                    .keys()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", "),
            }
            .build()
        })?;
        let rows = relation.rows().len();
        if rows > 0 {
            findings.push(format!("{name} ({rows} row(s))"));
        }
    }
    if findings.is_empty() {
        Ok(())
    } else {
        DeniedSnafu {
            findings: findings.join(", "),
        }
        .fail()
    }
}

fn select(analysis: &Analysis, relation: Option<&str>) -> Result<Vec<String>, Error> {
    let all: Vec<String> = analysis.database.relations.keys().cloned().collect();
    match relation {
        None => Ok(all),
        Some(name) if all.iter().any(|key| key == name) => Ok(vec![name.to_owned()]),
        Some(name) => NoRelationSnafu {
            name,
            available: all.join(", "),
        }
        .fail(),
    }
}

fn render_value(analysis: &Analysis, value: &Value) -> String {
    match value {
        Value::Node(node) => {
            let info = analysis.corpus.node_info(*node);
            let at = analysis.corpus.position(node.file, info.start);
            let path = analysis.corpus.files[node.file].path.display();
            let text = one_line(analysis.corpus.node_text(*node));
            format!("{path}:{line}:{column} `{text}`", line = at.line, column = at.column)
        }
        Value::Text(text) => format!("\"{text}\""),
    }
}

/// Collapse a node's source text to one bounded line for terminal output.
fn one_line(text: &str) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out: String = flat.chars().take(60).collect();
    if out.chars().count() < flat.chars().count() {
        out.push('…');
    }
    out
}

fn print_text(analysis: &Analysis, selected: &[String]) {
    for name in selected {
        let relation = &analysis.database.relations[name.as_str()];
        for row in relation.rows() {
            let cells: Vec<String> = relation
                .columns
                .iter()
                .zip(row)
                .map(|(column, value)| format!("{column} = {}", render_value(analysis, value)))
                .collect();
            println!("{name}({cells})", cells = cells.join(", "));
        }
    }
}

fn print_json(analysis: &Analysis, selected: &[String]) {
    let mut output = serde_json::Map::new();
    for name in selected {
        let relation = &analysis.database.relations[name.as_str()];
        let rows: Vec<serde_json::Value> = relation
            .rows()
            .iter()
            .map(|row| {
                let cells: serde_json::Map<String, serde_json::Value> = relation
                    .columns
                    .iter()
                    .zip(row)
                    .map(|(column, value)| (column.clone(), json_value(analysis, value)))
                    .collect();
                serde_json::Value::Object(cells)
            })
            .collect();
        output.insert(name.clone(), serde_json::Value::Array(rows));
    }
    println!("{}", serde_json::Value::Object(output));
}

fn json_value(analysis: &Analysis, value: &Value) -> serde_json::Value {
    match value {
        Value::Node(node) => {
            let info = analysis.corpus.node_info(*node);
            let at = analysis.corpus.position(node.file, info.start);
            serde_json::json!({
                "path": analysis.corpus.files[node.file].path,
                "kind": info.kind,
                "start": info.start,
                "end": info.end,
                "line": at.line,
                "column": at.column,
                "text": analysis.corpus.node_text(*node),
            })
        }
        Value::Text(text) => serde_json::Value::String(text.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::effective_deny;

    #[test]
    fn deny_all_extends_explicit_denies_without_duplicates() {
        let relations = ["a".to_owned(), "b".to_owned(), "c".to_owned()];
        let explicit = ["b".to_owned()];
        let denied = effective_deny(&explicit, true, relations.iter());
        assert_eq!(denied, ["b", "a", "c"]);
    }

    #[test]
    fn without_deny_all_only_explicit_names_are_denied() {
        let relations = ["a".to_owned(), "b".to_owned()];
        let explicit = ["a".to_owned()];
        let denied = effective_deny(&explicit, false, relations.iter());
        assert_eq!(denied, ["a"]);
    }
}
