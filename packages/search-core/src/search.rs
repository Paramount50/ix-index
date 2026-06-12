//! Search orchestration and projection onto displayable hits.
//!
//! The backend holds one shared entry per unique record across every source. A
//! raw result set can therefore include code from other worktrees. Projection
//! decides what survives, per source:
//!
//! - **Code** in worktree-exact scope is kept only when its content hash is in
//!   this checkout's manifest, then mapped back to the local path. In a coarser
//!   scope (a repo or all-repos filter), the server filter already decided, so
//!   code passes through labeled by its stored path.
//! - **Slack / Linear** records have no checkout; the server-side metadata filter
//!   is authoritative, so they always pass through (an absent manifest hash is
//!   not a reason to drop them).
//! - **Web** results pass through only when the caller asked for them.

use std::collections::HashSet;

use mixedbread::{Filter, SortBy};
use source_meta::{Source, keys};

use crate::backend::{GrepOptions, SearchHit, SearchOptions, Store};
use crate::config::WEB_STORE;
use crate::error::Result;
use crate::manifest::Manifest;

/// Snippet cap applied by [`RenderMode::Compact`], in characters.
///
/// Chosen so a default `top_k = 10` response stays in the low thousands of
/// tokens (the uncapped median chunk measured ~8 KiB, ~2k tokens, per hit).
pub const COMPACT_SNIPPET_CHARS: usize = 400;

/// How hits are projected for consumption.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RenderMode {
    /// Every chunk passes through with its full text.
    #[default]
    Full,
    /// Token-frugal projection for agents: overlapping chunks of the same
    /// document are collapsed to the best-scoring one (refilled from the
    /// overfetch buffer, so `top_k` distinct documents still come back) and
    /// each snippet is capped at [`COMPACT_SNIPPET_CHARS`] characters.
    Compact,
}

/// A search result projected for display.
///
/// Serializes to the stable `search --json` object. `label` is renamed to `path`
/// there to match the [`search-py`](../search-py) binding's dict, the other
/// established machine-readable contract over the same hits. The provenance
/// fields (`timestamp` through `project`) are skipped when absent, so sources
/// that never write them add no key.
#[derive(Debug, Clone, serde::Serialize)]
pub struct DisplayHit {
    /// Repo-relative path, record title, or a URL for a web result.
    #[serde(rename = "path")]
    pub label: String,
    /// Which corpus the hit came from.
    pub source: Source,
    /// Zero-based start line within the file, when known.
    pub start_line: Option<u32>,
    /// Number of lines in the chunk (a count, not a span), when known.
    pub num_lines: Option<u32>,
    /// Relevance score in `0.0..=1.0`.
    pub score: f32,
    /// Matched snippet text.
    pub text: String,
    /// Epoch-second timestamp of the record (the primary recency axis).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<i64>,
    /// OS user that authored the record.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    /// Short hostname the record was recorded on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// Session id (Claude Code transcript, codex, or shell session).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// The record's caller-assigned external id (e.g. `claude:{session}:{uuid}`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    /// Canonical web URL (GitHub items, Linear issues).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// Repository slug for code and git-commit records.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    /// Project slug (the working directory a transcript was recorded under).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
}

impl DisplayHit {
    /// Build a hit from a backend [`SearchHit`] under `label`, carrying the
    /// provenance through. Construction lives here so every projection branch
    /// keeps the same metadata.
    fn from_hit(label: String, hit: SearchHit) -> Self {
        let provenance = hit.provenance;
        Self {
            label,
            source: hit.source,
            start_line: hit.start_line,
            num_lines: hit.num_lines,
            score: hit.score,
            text: hit.text,
            timestamp: provenance.timestamp,
            user: provenance.user,
            host: provenance.host,
            session_id: provenance.session_id,
            external_id: provenance.external_id,
            url: provenance.url,
            repo: provenance.repo,
            project: provenance.project,
        }
    }
}

/// Serialize hits as the machine-readable JSON array `search --json` prints.
///
/// Lives here, at the owner of [`DisplayHit`], so both the CLI and any other
/// consumer share one serialization and the JSON shape stays defined in one
/// place.
///
/// # Errors
/// Returns an error if serialization fails, which is not expected for these
/// scalar/string fields.
pub fn hits_to_json(hits: &[DisplayHit]) -> serde_json::Result<String> {
    serde_json::to_string(hits)
}

/// A question-answering result projected for display.
#[derive(Debug, Clone)]
pub struct AnswerView {
    /// The synthesized answer.
    pub answer: String,
    /// Sources, filtered and mapped like search hits.
    pub sources: Vec<DisplayHit>,
}

/// How code hits are scoped. Record sources are always scoped by the server-side
/// metadata filter, so this only governs code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodeScope {
    /// Keep only code whose content hash is in this checkout's manifest.
    WorktreeExact,
    /// Trust the server-side filter (a repo or all-repos query); do not intersect
    /// with the manifest.
    ServerFiltered,
}

/// Search `store_name` (and optionally the web store) and project the hits.
///
/// # Errors
/// Returns an error if the backend search request fails.
#[allow(
    clippy::too_many_arguments,
    reason = "thin pass-through of the query surface"
)]
pub async fn semantic(
    store: &(impl Store + Sync),
    store_name: &str,
    manifest: &Manifest,
    query: &str,
    top_k: usize,
    options: SearchOptions,
    include_web: bool,
    filters: Option<&Filter>,
    code_scope: CodeScope,
    mode: RenderMode,
) -> Result<Vec<DisplayHit>> {
    let stores = store_identifiers(store_name, include_web);
    let hits = store
        .search(&stores, query, overfetch(top_k), options, filters)
        .await?;
    Ok(project(manifest, hits, include_web, top_k, code_scope, mode))
}

/// Grep `store_name` with a regular expression and project the hits.
///
/// # Errors
/// Returns an error if the pattern is not a valid regular expression or the
/// backend grep request fails.
#[allow(
    clippy::too_many_arguments,
    reason = "thin pass-through of the query surface"
)]
pub async fn grep(
    store: &(impl Store + Sync),
    store_name: &str,
    manifest: &Manifest,
    pattern: &str,
    top_k: usize,
    options: GrepOptions,
    filters: Option<&Filter>,
    code_scope: CodeScope,
    mode: RenderMode,
) -> Result<Vec<DisplayHit>> {
    let stores = store_identifiers(store_name, false);
    let hits = store
        .grep(&stores, pattern, overfetch(top_k), options, filters)
        .await?;
    Ok(project(manifest, hits, false, top_k, code_scope, mode))
}

/// List the newest records (descending [`keys::TIMESTAMP`]) matching `filters`.
///
/// A deterministic recency feed with no semantic scoring, backed by the
/// store's metadata-only chunk listing. The score on each hit is the API's
/// placeholder, not a relevance signal.
///
/// # Errors
/// Returns an error if the backend listing fails.
pub async fn recent(
    store: &(impl Store + Sync),
    store_name: &str,
    top_k: usize,
    filters: Option<&Filter>,
    mode: RenderMode,
) -> Result<Vec<DisplayHit>> {
    let stores = store_identifiers(store_name, false);
    let sort = SortBy::desc(keys::TIMESTAMP);
    // Overfetch only matters in compact mode, where duplicate documents are
    // collapsed and the feed refills from the buffer.
    let fetch = match mode {
        RenderMode::Full => top_k,
        RenderMode::Compact => overfetch(top_k),
    };
    let hits = store
        .list_chunks(&stores, fetch, filters, Some(&sort))
        .await?;
    // No manifest: this is a pure server-side listing, so code hits pass
    // through labeled by their stored path.
    Ok(project(
        &Manifest::default(),
        hits,
        false,
        top_k,
        CodeScope::ServerFiltered,
        mode,
    ))
}

/// Ask a question against `store_name` (and optionally the web store).
///
/// # Errors
/// Returns an error if the backend request fails.
#[allow(
    clippy::too_many_arguments,
    reason = "thin pass-through of the query surface"
)]
pub async fn ask(
    store: &(impl Store + Sync),
    store_name: &str,
    manifest: &Manifest,
    query: &str,
    top_k: usize,
    options: SearchOptions,
    include_web: bool,
    filters: Option<&Filter>,
    code_scope: CodeScope,
) -> Result<AnswerView> {
    let stores = store_identifiers(store_name, include_web);
    let answer = store
        .ask(&stores, query, overfetch(top_k), options, filters)
        .await?;
    Ok(AnswerView {
        answer: answer.answer,
        sources: project(
            manifest,
            answer.sources,
            include_web,
            top_k,
            code_scope,
            RenderMode::Full,
        ),
    })
}

fn store_identifiers(store_name: &str, include_web: bool) -> Vec<String> {
    let mut stores = vec![store_name.to_owned()];
    if include_web {
        stores.push(WEB_STORE.to_owned());
    }
    stores
}

/// Over-fetch so that client-side filtering still leaves enough results. Other
/// checkouts' code can crowd the raw top-k, so we ask for more than we show.
fn overfetch(top_k: usize) -> usize {
    top_k.saturating_mul(4).max(top_k.saturating_add(10))
}

fn project(
    manifest: &Manifest,
    hits: Vec<SearchHit>,
    include_web: bool,
    top_k: usize,
    code_scope: CodeScope,
    mode: RenderMode,
) -> Vec<DisplayHit> {
    let local = manifest.hashes();
    // Compact mode collapses repeated chunks of one document: the raw top-k is
    // often dominated by overlapping chunks of a single file. Hits arrive
    // relevance-sorted (the reranker's order), so the first chunk seen for a
    // document is its best-scoring one; later chunks are dropped and the list
    // refills from the overfetch buffer.
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::with_capacity(top_k);
    for hit in hits {
        if out.len() >= top_k {
            break;
        }
        let source = hit.source.clone();
        let display = if source.is_web() {
            if !include_web {
                continue;
            }
            let label = hit.path.clone().unwrap_or_else(|| "(web)".to_owned());
            let mut display = DisplayHit::from_hit(label, hit);
            // Web chunks report line metadata that is meaningless for a page;
            // keep the established shape of web hits line-free.
            display.start_line = None;
            display.num_lines = None;
            display
        } else if source.is_code() {
            let in_manifest = hit.hash.as_deref().is_some_and(|hash| local.contains(hash));
            // Worktree-exact keeps only this checkout's code; a server-filtered
            // scope (a repo / all-repos query) trusts the backend filter.
            if code_scope == CodeScope::WorktreeExact && !in_manifest {
                continue;
            }
            let label = hit
                .hash
                .as_deref()
                .and_then(|hash| manifest.path_for_hash(hash))
                .map(str::to_owned)
                .or_else(|| hit.path.clone())
                .or_else(|| hit.hash.clone())
                .unwrap_or_default();
            DisplayHit::from_hit(label, hit)
        } else {
            // Any other tag (slack, linear, claude_history, ...) is a record
            // source: no checkout to scope against, so the server-side metadata
            // filter is authoritative and the record passes through.
            let label = hit.path.clone().unwrap_or_default();
            DisplayHit::from_hit(label, hit)
        };
        if mode == RenderMode::Compact {
            if !seen.insert(document_key(&display)) {
                continue;
            }
            out.push(truncate_snippet(display, COMPACT_SNIPPET_CHARS));
        } else {
            out.push(display);
        }
    }
    out
}

/// The identity under which compact mode collapses chunks: the stored
/// `external_id` when present (one per document), else source + label, which
/// groups chunks of one file or record.
fn document_key(hit: &DisplayHit) -> String {
    hit.external_id.clone().unwrap_or_else(|| {
        format!("{}\u{1f}{}", hit.source.as_str(), hit.label)
    })
}

/// Cap a hit's snippet at `max_chars` characters (on a char boundary), marking
/// the cut with an ellipsis. `start_line`/`num_lines` keep describing the full
/// chunk, so the pointer back into the source stays valid.
fn truncate_snippet(mut hit: DisplayHit, max_chars: usize) -> DisplayHit {
    if hit.text.chars().count() > max_chars {
        let mut text: String = hit.text.chars().take(max_chars).collect();
        text.push('…');
        hit.text = text;
    }
    hit
}

#[cfg(test)]
mod tests {
    use source_meta::{Document, Source};

    use super::{CodeScope, RenderMode, grep, recent, semantic};
    use crate::backend::{GrepOptions, GrepTargets, MemoryStore, SearchOptions, Store};
    use crate::content::ContentHash;
    use crate::manifest::{FileEntry, Manifest};

    fn opts() -> SearchOptions {
        SearchOptions {
            rerank: mixedbread::Rerank::server_default(),
            agentic: false,
        }
    }

    async fn put_code(store: &MemoryStore, path: &str, content: &str) -> ContentHash {
        let hash = ContentHash::of_bytes(content.as_bytes());
        let meta = serde_json::json!({
            "source": "code",
            "external_id": hash.as_str(),
            "content_hash": hash.as_str(),
            "title": path,
            "repo": "indexable-inc/index",
            "path": path,
        });
        store
            .upload(
                "s",
                Document {
                    external_id: hash.as_str().to_owned(),
                    file_name: path.to_owned(),
                    mime: "text/plain",
                    body: content.as_bytes().to_vec(),
                    meta_json: meta,
                    content_hash: hash.as_str().to_owned(),
                },
            )
            .await
            .expect("upload");
        hash
    }

    async fn put_slack(store: &MemoryStore, external_id: &str, title: &str, content: &str) {
        let hash = source_meta::hash_body(content.as_bytes());
        let meta = serde_json::json!({
            "source": "slack",
            "external_id": external_id,
            "content_hash": hash,
            "title": title,
            "channel_name": "craft",
        });
        store
            .upload(
                "s",
                Document {
                    external_id: external_id.to_owned(),
                    file_name: "thread.txt".to_owned(),
                    mime: "text/plain",
                    body: content.as_bytes().to_vec(),
                    meta_json: meta,
                    content_hash: hash,
                },
            )
            .await
            .expect("upload");
    }

    fn manifest_with(entries: &[(&str, &ContentHash)]) -> Manifest {
        Manifest {
            entries: entries
                .iter()
                .map(|(path, hash)| FileEntry {
                    rel_path: (*path).to_owned(),
                    hash: (*hash).clone(),
                    mtime_ms: 0,
                    size: 0,
                })
                .collect(),
        }
    }

    #[tokio::test]
    async fn code_outside_this_checkout_is_filtered() {
        let store = MemoryStore::new();
        let mine = put_code(&store, "mine.rs", "needle in mine").await;
        let _theirs = put_code(&store, "theirs.rs", "needle in theirs").await;

        let manifest = manifest_with(&[("mine.rs", &mine)]);
        let hits = semantic(
            &store,
            "s",
            &manifest,
            "needle",
            10,
            opts(),
            false,
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("search");

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].label, "mine.rs");
        assert_eq!(hits[0].source, Source::code());
    }

    #[tokio::test]
    async fn slack_passes_through_without_a_manifest_hash() {
        let store = MemoryStore::new();
        put_slack(
            &store,
            "slack:C0:1.2",
            "craft: ship it",
            "needle decision in slack",
        )
        .await;
        // The manifest knows no code; the Slack thread must still surface, because
        // record sources are scoped by the server filter, not the manifest.
        let manifest = Manifest::default();
        let hits = semantic(
            &store,
            "s",
            &manifest,
            "needle",
            10,
            opts(),
            false,
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("search");

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].source, Source::new("slack"));
        assert_eq!(hits[0].label, "craft: ship it");
    }

    #[tokio::test]
    async fn source_filter_excludes_a_source() {
        let store = MemoryStore::new();
        let mine = put_code(&store, "mine.rs", "needle in code").await;
        put_slack(&store, "slack:C0:1.2", "craft", "needle in slack").await;
        let manifest = manifest_with(&[("mine.rs", &mine)]);

        // Exclude slack: only the code hit should survive.
        let filter = mixedbread::Filter::none(vec![mixedbread::Filter::eq("source", "slack")]);
        let hits = semantic(
            &store,
            "s",
            &manifest,
            "needle",
            10,
            opts(),
            false,
            Some(&filter),
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("search");

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].source, Source::code());
    }

    /// Upload a claude_history-shaped record with full provenance metadata.
    async fn put_history(
        store: &MemoryStore,
        external_id: &str,
        title: &str,
        content: &str,
        timestamp: i64,
    ) {
        let hash = source_meta::hash_body(content.as_bytes());
        let meta = serde_json::json!({
            "source": "claude_history",
            "external_id": external_id,
            "content_hash": hash,
            "title": title,
            "timestamp": timestamp,
            "user": "andrew",
            "host": "hydra",
            "session_id": "sess-1",
            "project": "/home/andrew/index",
        });
        store
            .upload(
                "s",
                Document {
                    external_id: external_id.to_owned(),
                    file_name: "message.txt".to_owned(),
                    mime: "text/plain",
                    body: content.as_bytes().to_vec(),
                    meta_json: meta,
                    content_hash: hash,
                },
            )
            .await
            .expect("upload");
    }

    #[tokio::test]
    async fn hits_carry_provenance_metadata() {
        let store = MemoryStore::new();
        put_history(
            &store,
            "claude:sess-1:uuid-1",
            "assistant @ index: fixed the bug",
            "needle: the fix was reverting the cursor",
            1_781_000_000,
        )
        .await;

        let hits = semantic(
            &store,
            "s",
            &Manifest::default(),
            "needle",
            10,
            opts(),
            false,
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("search");

        assert_eq!(hits.len(), 1);
        let hit = &hits[0];
        assert_eq!(hit.timestamp, Some(1_781_000_000));
        assert_eq!(hit.user.as_deref(), Some("andrew"));
        assert_eq!(hit.host.as_deref(), Some("hydra"));
        assert_eq!(hit.session_id.as_deref(), Some("sess-1"));
        assert_eq!(hit.external_id.as_deref(), Some("claude:sess-1:uuid-1"));
        assert_eq!(hit.project.as_deref(), Some("/home/andrew/index"));

        // The JSON contract: provenance keys present, and no `url`/`repo` keys
        // for a record that never wrote them.
        let json: serde_json::Value =
            serde_json::from_str(&super::hits_to_json(&hits).expect("json")).expect("parse");
        assert_eq!(json[0]["session_id"], "sess-1");
        assert_eq!(json[0]["timestamp"], 1_781_000_000);
        assert!(json[0].get("url").is_none(), "absent url adds no key");
        assert!(json[0].get("repo").is_none(), "absent repo adds no key");
    }

    #[tokio::test]
    async fn compact_collapses_chunks_of_one_document_and_caps_snippets() {
        let store = MemoryStore::new();
        // One document whose body matches the query on many lines: the
        // MemoryStore emits one chunk per matching line, modeling the
        // overlapping-chunks-of-one-file pathology.
        let long_line = format!("needle {}", "x".repeat(600));
        let body = format!("{long_line}\nneedle two\nneedle three");
        put_history(&store, "claude:sess-1:uuid-1", "spam", &body, 1).await;
        put_history(&store, "claude:sess-1:uuid-2", "other", "needle other", 2).await;

        let compact = semantic(
            &store,
            "s",
            &Manifest::default(),
            "needle",
            10,
            opts(),
            false,
            None,
            CodeScope::WorktreeExact,
            RenderMode::Compact,
        )
        .await
        .expect("search");
        // Two documents, not four chunks.
        assert_eq!(compact.len(), 2);
        let mut ids: Vec<&str> = compact
            .iter()
            .filter_map(|hit| hit.external_id.as_deref())
            .collect();
        ids.sort_unstable();
        assert_eq!(ids, vec!["claude:sess-1:uuid-1", "claude:sess-1:uuid-2"]);
        // The long snippet is capped with an ellipsis marker.
        let long_hit = compact
            .iter()
            .find(|hit| hit.external_id.as_deref() == Some("claude:sess-1:uuid-1"))
            .expect("long hit");
        assert!(long_hit.text.chars().count() <= super::COMPACT_SNIPPET_CHARS + 1);
        assert!(long_hit.text.ends_with('…'));

        // Full mode keeps every chunk and the whole text.
        let full = semantic(
            &store,
            "s",
            &Manifest::default(),
            "needle",
            10,
            opts(),
            false,
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("search");
        assert_eq!(full.len(), 4);
        assert!(full.iter().any(|hit| hit.text.len() > 600));
    }

    #[tokio::test]
    async fn recent_lists_newest_first_and_honors_since() {
        let store = MemoryStore::new();
        put_history(&store, "id:old", "old", "alpha", 1_000).await;
        put_history(&store, "id:mid", "mid", "beta", 2_000).await;
        put_history(&store, "id:new", "new", "gamma", 3_000).await;

        let hits = recent(&store, "s", 10, None, RenderMode::Full)
            .await
            .expect("recent");
        let stamps: Vec<i64> = hits.iter().filter_map(|hit| hit.timestamp).collect();
        assert_eq!(stamps, vec![3_000, 2_000, 1_000], "newest first");

        // A since window built through the shared FilterSpec excludes the old
        // record server-side (the MemoryStore models numeric gte).
        let spec = crate::FilterSpec {
            since: Some(1_500),
            ..crate::FilterSpec::default()
        };
        let filter = crate::build_filter(&spec).expect("filter");
        let windowed = recent(&store, "s", 10, Some(&filter), RenderMode::Full)
            .await
            .expect("recent windowed");
        let stamps: Vec<i64> = windowed.iter().filter_map(|hit| hit.timestamp).collect();
        assert_eq!(stamps, vec![3_000, 2_000]);
    }

    fn grep_opts(case_sensitive: bool) -> GrepOptions {
        GrepOptions {
            case_sensitive,
            targets: GrepTargets::Text,
        }
    }

    #[tokio::test]
    async fn grep_matches_regex_and_projects_to_local_paths() {
        let store = MemoryStore::new();
        let alpha = put_code(&store, "alpha.rs", "fn handler() {}\nlet other = 1;").await;
        let beta = put_code(&store, "beta.rs", "struct Thing;\nfn render() {}").await;

        let manifest = manifest_with(&[("alpha.rs", &alpha), ("beta.rs", &beta)]);
        let hits = grep(
            &store,
            "s",
            &manifest,
            r"fn \w+\(\)",
            10,
            grep_opts(false),
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("grep");

        assert_eq!(hits.len(), 2);
        let mut labels: Vec<&str> = hits.iter().map(|hit| hit.label.as_str()).collect();
        labels.sort_unstable();
        assert_eq!(labels, vec!["alpha.rs", "beta.rs"]);
        assert!(hits.iter().all(|hit| hit.source.is_code()));
    }

    #[tokio::test]
    async fn grep_case_sensitive_excludes_differently_cased_match() {
        let store = MemoryStore::new();
        let lower = put_code(&store, "lower.rs", "let token = read();").await;
        let upper = put_code(&store, "upper.rs", "let TOKEN = read();").await;

        let manifest = manifest_with(&[("lower.rs", &lower), ("upper.rs", &upper)]);

        let insensitive = grep(
            &store,
            "s",
            &manifest,
            "token",
            10,
            grep_opts(false),
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("grep");
        assert_eq!(insensitive.len(), 2);

        let sensitive = grep(
            &store,
            "s",
            &manifest,
            "token",
            10,
            grep_opts(true),
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await
        .expect("grep");
        assert_eq!(sensitive.len(), 1);
        assert_eq!(sensitive[0].label, "lower.rs");
    }

    #[tokio::test]
    async fn grep_invalid_pattern_is_an_error() {
        let store = MemoryStore::new();
        let only = put_code(&store, "only.rs", "anything").await;
        let manifest = manifest_with(&[("only.rs", &only)]);

        let result = grep(
            &store,
            "s",
            &manifest,
            "fn (",
            10,
            grep_opts(false),
            None,
            CodeScope::WorktreeExact,
            RenderMode::Full,
        )
        .await;
        assert!(result.is_err());
    }
}
