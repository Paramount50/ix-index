//! Lint findings: every row of a `(lint ...)`-declared relation becomes one
//! located finding, minus the rows an `astlog-ignore` comment suppresses.
//!
//! Suppression is an emission-time filter only: the underlying Datalog rows
//! still exist for joins and `query` output. A comment node (any tree-sitter
//! kind containing "comment") whose text contains `astlog-ignore` suppresses
//! findings on the lines the comment spans (trailing comment) and the line
//! immediately below it; `astlog-ignore: name1, name2` limits suppression to
//! those rule names, a bare `astlog-ignore` suppresses every rule there.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use crate::corpus::{Corpus, Value};
use crate::error::{Error, InternalSnafu, LintNoNodeSnafu};
use crate::eval::{Database, Row};
use crate::program::{Lint, Program, Segment, Severity};

/// One scan finding: a lint-declared relation row located at its first
/// node-valued column.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub rule: String,
    pub severity: Severity,
    pub message: String,
    pub file: PathBuf,
    /// 1-based start position of the located node.
    pub line: usize,
    pub column: usize,
    /// 1-based position just past the located node.
    pub end_line: usize,
    pub end_column: usize,
    /// The node's source text, collapsed to one bounded line.
    pub text: String,
}

/// Findings for every lint declaration, suppression applied, sorted by
/// (file, line, column, rule).
///
/// # Errors
///
/// Fails with [`Error::LintNoNode`] when a lint relation derives a row with
/// no node-valued column to locate the finding at.
pub fn findings(program: &Program, corpus: &Corpus, db: &Database) -> Result<Vec<Finding>, Error> {
    let suppressions = Suppressions::collect(corpus);
    let mut findings = Vec::new();
    for lint in &program.lints {
        let relation = db.relations.get(&lint.relation).ok_or_else(|| {
            InternalSnafu {
                what: format!("lint relation `{}` missing from database", lint.relation),
            }
            .build()
        })?;
        for row in relation.rows() {
            let node = row
                .iter()
                .find_map(|value| match value {
                    Value::Node(node) => Some(*node),
                    Value::Text(_) => None,
                })
                .ok_or_else(|| {
                    LintNoNodeSnafu {
                        rule: lint.relation.clone(),
                        line: lint.line,
                    }
                    .build()
                })?;
            let info = corpus.node_info(node);
            let start = corpus.position(node.file, info.start);
            if suppressions.suppressed(node.file, start.line, &lint.relation) {
                continue;
            }
            let end = corpus.position(node.file, info.end);
            findings.push(Finding {
                rule: lint.relation.clone(),
                severity: lint.severity,
                message: render_message(lint, &relation.columns, row, corpus)?,
                file: corpus.files[node.file].path.clone(),
                line: start.line,
                column: start.column,
                end_line: end.line,
                end_column: end.column,
                text: one_line(corpus.node_text(node)),
            });
        }
    }
    findings.sort_by(|a, b| {
        (&a.file, a.line, a.column, &a.rule).cmp(&(&b.file, b.line, b.column, &b.rule))
    });
    Ok(findings)
}

/// Instantiate a lint message template against one relation row. Spliced
/// values are flattened with [`one_line`] so a message never spans lines.
fn render_message(
    lint: &Lint,
    columns: &[String],
    row: &Row,
    corpus: &Corpus,
) -> Result<String, Error> {
    let mut message = String::new();
    for segment in &lint.message.segments {
        match segment {
            Segment::Lit(lit) => message.push_str(lit),
            Segment::Var(var) => {
                let index = columns
                    .iter()
                    .position(|column| column == var)
                    .ok_or_else(|| {
                        InternalSnafu {
                            what: format!(
                                "lint `{}` message variable `{var}` survived checking \
                                 without a relation column",
                                lint.relation
                            ),
                        }
                        .build()
                    })?;
                message.push_str(&one_line(corpus.value_text(&row[index])));
            }
        }
    }
    Ok(message)
}

/// Collapse a node's source text to one bounded line for terminal output.
#[must_use]
pub fn one_line(text: &str) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out: String = flat.chars().take(60).collect();
    if out.chars().count() < flat.chars().count() {
        out.push('…');
    }
    out
}

/// What an `astlog-ignore` comment suppresses on one line.
#[derive(Debug, Default)]
struct LineSuppression {
    all: bool,
    rules: HashSet<String>,
}

/// Per-file, per-line suppression entries gathered from comment nodes.
struct Suppressions {
    by_file: Vec<HashMap<usize, LineSuppression>>,
}

impl Suppressions {
    fn collect(corpus: &Corpus) -> Self {
        let by_file = corpus
            .files
            .iter()
            .enumerate()
            .map(|(file_index, file)| {
                let mut lines: HashMap<usize, LineSuppression> = HashMap::new();
                for info in &file.nodes {
                    if !info.kind.contains("comment") {
                        continue;
                    }
                    let Some(directive) = parse_directive(&file.text[info.start..info.end]) else {
                        continue;
                    };
                    let first = corpus.position(file_index, info.start).line;
                    // `end` is exclusive; the comment's last line is the line
                    // of its final byte, and suppression extends one further.
                    let last = corpus
                        .position(file_index, info.end.saturating_sub(1))
                        .line;
                    for line in first..=last + 1 {
                        let entry = lines.entry(line).or_default();
                        match &directive {
                            Directive::All => entry.all = true,
                            Directive::Rules(rules) => entry.rules.extend(rules.iter().cloned()),
                        }
                    }
                }
                lines
            })
            .collect();
        Self { by_file }
    }

    fn suppressed(&self, file: usize, line: usize, rule: &str) -> bool {
        self.by_file[file]
            .get(&line)
            .is_some_and(|entry| entry.all || entry.rules.contains(rule))
    }
}

enum Directive {
    All,
    Rules(Vec<String>),
}

/// Parse a comment's text into a suppression directive. `astlog-ignore`
/// anywhere in the comment suppresses everything; `astlog-ignore: a, b`
/// limits suppression to those rule names. Name tokens stop at the first
/// character outside `[A-Za-z0-9_-]` so block-comment terminators never leak
/// into a name.
fn parse_directive(comment: &str) -> Option<Directive> {
    let at = comment.find("astlog-ignore")?;
    let rest = comment[at + "astlog-ignore".len()..].trim_start();
    let Some(names) = rest.strip_prefix(':') else {
        return Some(Directive::All);
    };
    let rules: Vec<String> = names
        .split(',')
        .filter_map(|token| {
            let name: String = token
                .trim_start()
                .chars()
                .take_while(|c| c.is_alphanumeric() || matches!(c, '-' | '_'))
                .collect();
            (!name.is_empty()).then_some(name)
        })
        .collect();
    if rules.is_empty() {
        Some(Directive::All)
    } else {
        Some(Directive::Rules(rules))
    }
}
