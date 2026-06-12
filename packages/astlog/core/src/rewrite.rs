//! Rewrites: template instantiation over rewrite-body bindings, then
//! non-overlapping byte-range splices applied per file.

use std::collections::HashMap;
use std::path::PathBuf;

use crate::corpus::{Corpus, Value};
use crate::error::{Error, OverlappingEditsSnafu, ReplaceNotNodeSnafu, TemplateVarSnafu};
use crate::eval::{Database, Evaluator};
use crate::program::{Program, Rewrite, Segment};

/// One pending replacement of a byte range in a corpus file.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Edit {
    pub file: usize,
    pub start: usize,
    pub end: usize,
    pub replacement: String,
}

/// A file with all of its edits applied.
#[derive(Debug)]
pub struct FileRewrite {
    pub path: PathBuf,
    pub content: String,
}

pub fn collect(
    program: &Program,
    corpus: &Corpus,
    evaluator: &Evaluator<'_>,
    db: &Database,
) -> Result<Vec<Edit>, Error> {
    let mut edits = Vec::new();
    for rewrite in &program.rewrites {
        for env in evaluator.bindings(db, &rewrite.body)? {
            edits.push(edit_of(corpus, rewrite, &env)?);
        }
    }
    edits.sort();
    edits.dedup();
    check_overlaps(corpus, &edits)?;
    Ok(edits)
}

fn edit_of(
    corpus: &Corpus,
    rewrite: &Rewrite,
    env: &HashMap<String, Value>,
) -> Result<Edit, Error> {
    let target = env.get(&rewrite.target).ok_or_else(|| {
        TemplateVarSnafu {
            var: rewrite.target.clone(),
            line: rewrite.line,
        }
        .build()
    })?;
    let Value::Node(node) = target else {
        return ReplaceNotNodeSnafu {
            name: rewrite.name.clone(),
            var: rewrite.target.clone(),
        }
        .fail();
    };
    let mut replacement = String::new();
    for segment in &rewrite.template.segments {
        match segment {
            Segment::Lit(lit) => replacement.push_str(lit),
            Segment::Var(var) => {
                let value = env.get(var).ok_or_else(|| {
                    TemplateVarSnafu {
                        var: var.clone(),
                        line: rewrite.template.line,
                    }
                    .build()
                })?;
                replacement.push_str(corpus.value_text(value));
            }
        }
    }
    let info = corpus.node_info(*node);
    Ok(Edit {
        file: node.file,
        start: info.start,
        end: info.end,
        replacement,
    })
}

fn check_overlaps(corpus: &Corpus, edits: &[Edit]) -> Result<(), Error> {
    for pair in edits.windows(2) {
        let [first, second] = pair else {
            continue;
        };
        // `edits` is sorted, so the pair overlaps exactly when the later edit
        // starts before the earlier one ends.
        #[expect(
            clippy::suspicious_operation_groupings,
            reason = "comparing second.start against first.end is the overlap test, not a typo"
        )]
        if first.file == second.file && second.start < first.end {
            return OverlappingEditsSnafu {
                path: corpus.files[first.file].path.clone(),
                first_start: first.start,
                first_end: first.end,
                second_start: second.start,
                second_end: second.end,
            }
            .fail();
        }
    }
    Ok(())
}

/// Apply edits, returning only the files that changed.
#[must_use]
pub fn apply(corpus: &Corpus, edits: &[Edit]) -> Vec<FileRewrite> {
    let mut by_file: Vec<Vec<&Edit>> = vec![Vec::new(); corpus.files.len()];
    for edit in edits {
        by_file[edit.file].push(edit);
    }
    by_file
        .into_iter()
        .enumerate()
        .filter(|(_, edits)| !edits.is_empty())
        .map(|(file, edits)| {
            let source = &corpus.files[file];
            let mut content = source.text.clone();
            for edit in edits.into_iter().rev() {
                content.replace_range(edit.start..edit.end, &edit.replacement);
            }
            FileRewrite {
                path: source.path.clone(),
                content,
            }
        })
        .collect()
}

/// Unified diff of every pending rewrite against the loaded corpus.
#[must_use]
pub fn unified_diff(corpus: &Corpus, rewrites: &[FileRewrite]) -> String {
    let mut out = String::new();
    for rewrite in rewrites {
        let original = corpus
            .files
            .iter()
            .find(|file| file.path == rewrite.path)
            .map_or("", |file| file.text.as_str());
        let label = rewrite.path.display();
        let diff = similar::TextDiff::from_lines(original, &rewrite.content)
            .unified_diff()
            .header(&format!("a/{label}"), &format!("b/{label}"))
            .to_string();
        out.push_str(&diff);
    }
    out
}
