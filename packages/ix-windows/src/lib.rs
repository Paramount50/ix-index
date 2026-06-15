//! The reusable engine behind `ix-windows`: map a stream of dashboard
//! [`ProducerSnapshot`]s onto one borderless webview window per live MCP
//! resource.
//!
//! A [`WindowManager`] owns the open windows and reconciles them against each
//! snapshot: a new resource opens a window, a changed one re-renders in place
//! (no reload, so scroll and focus survive), a vanished one closes. It is
//! deliberately decoupled from the event source and the user-event type so an
//! embedder can drive it from its own `tao` event loop — the binary
//! ([`crate`]'s `main`) is a thin wrapper that feeds it
//! [`dashboard_core::subscribe`] events.
//!
//! ## What counts as a resource
//!
//! The MCP publishes every `register_resource()` view (a terminal, a TUI screen,
//! a custom widget — all already rendered to HTML) as an [`HtmlView`] pane keyed
//! `resource/<id>` (see `packages/mcp/ix_notebook_mcp/pane_bridge.py`). This
//! engine windows exactly those panes; a producer's exec runs, namespace, and
//! cells stay on the web canvas.

use std::collections::{HashMap, HashSet};

use dashboard_core::{Pane, ProducerSnapshot, View};
use tao::dpi::{LogicalPosition, LogicalSize};
use tao::event_loop::EventLoopWindowTarget;
use tao::window::{Window, WindowId};
use wry::{WebView, WebViewBuilder};

/// Pane-id prefix marking an MCP resource. Mirrors the key built in
/// `pane_bridge.py` (`f"resource/{res['id']}"`).
const RESOURCE_PREFIX: &str = "resource/";

/// A pane's global identity across producers: `(producer id, pane id)`. A pane id
/// is unique only within its producer, so the producer scopes it.
type PaneKey = (String, String);

/// One open resource window: its `tao` window, its `wry` webview, and the last
/// content rendered into it (so an unchanged snapshot is a no-op).
struct OpenWindow {
    // Held to keep the OS window alive; dropping `OpenWindow` closes the window.
    window: Window,
    webview: WebView,
    last_html: String,
    last_title: String,
}

impl OpenWindow {
    /// Re-render in place if the resource's html or title changed. The body swap
    /// targets `#ix-root` so the document, its scroll position, and focus survive
    /// an update — a full reload would flicker and reset them.
    fn refresh(&mut self, pane: &Pane, html: &str) {
        if self.last_html != html {
            // `serde_json::to_string` emits a valid JS string literal (quoted and
            // escaped), so arbitrary resource HTML is injected safely.
            let literal = serde_json::to_string(html).unwrap_or_else(|_| "\"\"".to_owned());
            let js = format!("document.getElementById('ix-root').innerHTML = {literal};");
            let _ = self.webview.evaluate_script(&js);
            html.clone_into(&mut self.last_html);
        }
        if self.last_title != pane.title {
            self.window.set_title(&pane.title);
            self.last_title.clone_from(&pane.title);
        }
    }
}

/// Owns the resource windows and reconciles them against producer snapshots.
#[derive(Default)]
pub struct WindowManager {
    windows: HashMap<PaneKey, OpenWindow>,
    /// Reverse index so an OS close event (the user closing a window) maps back
    /// to the pane it represented.
    by_window: HashMap<WindowId, PaneKey>,
    /// Resources the user explicitly closed while still live. Without this, the
    /// next snapshot (any resource content change republishes one) would find
    /// the window gone and re-open it, fighting the user. Cleared when the
    /// resource actually vanishes or its producer disconnects, so a genuine
    /// re-registration opens a fresh window.
    dismissed: HashSet<PaneKey>,
    /// How many windows have been opened, used to cascade each new one so they
    /// do not stack exactly on top of each other on a plain desktop. A tiling
    /// WM ignores the position hint and lays them out itself.
    opened: u32,
}

impl WindowManager {
    /// An empty manager with no windows.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Reconcile this producer's resource windows against its latest snapshot:
    /// open new resources, refresh changed ones, and close those that vanished.
    ///
    /// `target` is the running event loop, needed to create windows; it is
    /// generic over the loop's user-event type so the engine stays independent of
    /// the binary's event enum.
    pub fn apply_snapshot<T: 'static>(
        &mut self,
        target: &EventLoopWindowTarget<T>,
        snapshot: &ProducerSnapshot,
    ) {
        let mut present: HashSet<&str> = HashSet::new();
        for pane in &snapshot.panes {
            let View::Html(view) = &pane.view else {
                continue;
            };
            if !pane.id.starts_with(RESOURCE_PREFIX) {
                continue;
            }
            present.insert(pane.id.as_str());
            let key = (snapshot.producer.clone(), pane.id.clone());
            if let Some(open) = self.windows.get_mut(&key) {
                open.refresh(pane, &view.html);
            } else if !self.dismissed.contains(&key) {
                self.open(target, key, pane, &view.html);
            }
        }

        // Close windows for resources this producer no longer reports.
        let stale: Vec<PaneKey> = self
            .windows
            .keys()
            .filter(|(producer, id)| {
                *producer == snapshot.producer && !present.contains(id.as_str())
            })
            .cloned()
            .collect();
        for key in stale {
            self.close(&key);
        }

        // Forget dismissals for this producer's resources that are gone, so a
        // later re-registration of the same id opens a fresh window.
        self.dismissed
            .retain(|(producer, id)| *producer != snapshot.producer || present.contains(id.as_str()));
    }

    /// Drop every window belonging to a producer that has disconnected.
    pub fn producer_gone(&mut self, producer: &str) {
        let gone: Vec<PaneKey> = self
            .windows
            .keys()
            .filter(|(p, _)| p == producer)
            .cloned()
            .collect();
        for key in gone {
            self.close(&key);
        }
        self.dismissed.retain(|(p, _)| p != producer);
    }

    /// Forget a window the user closed (an OS `CloseRequested`) and remember the
    /// dismissal so a later snapshot for the still-live resource does not re-open
    /// it. Returns whether the window was one of ours.
    pub fn window_closed(&mut self, window: WindowId) -> bool {
        let Some(key) = self.by_window.remove(&window) else {
            return false;
        };
        self.windows.remove(&key);
        self.dismissed.insert(key);
        true
    }

    /// Whether any resource windows are currently open.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.windows.is_empty()
    }

    /// Create a borderless, transparent webview window for a resource pane.
    fn open<T: 'static>(
        &mut self,
        target: &EventLoopWindowTarget<T>,
        key: PaneKey,
        pane: &Pane,
        html: &str,
    ) {
        // Cascade each window so they do not perfectly overlap on a plain
        // desktop; a tiling WM ignores the position and tiles them itself.
        let step = f64::from(self.opened % 8) * 28.0;
        self.opened = self.opened.wrapping_add(1);
        let window = match tao::window::WindowBuilder::new()
            .with_title(&pane.title)
            .with_decorations(false)
            .with_transparent(true)
            .with_inner_size(LogicalSize::new(720.0, 480.0))
            .with_position(LogicalPosition::new(96.0 + step, 96.0 + step))
            .build(target)
        {
            Ok(window) => window,
            Err(error) => {
                eprintln!("ix-windows: window for {}: {error}", pane.id);
                return;
            }
        };
        let id = window.id();
        let webview = match WebViewBuilder::new()
            .with_transparent(true)
            .with_html(shell(&pane.title, html))
            .build(&window)
        {
            Ok(webview) => webview,
            Err(error) => {
                eprintln!("ix-windows: webview for {}: {error}", pane.id);
                return;
            }
        };

        // Let WebKit render at the display's native rate (120Hz on ProMotion)
        // rather than its default ~60fps cap.
        #[cfg(target_os = "macos")]
        enable_high_refresh(&webview);

        self.by_window.insert(id, key.clone());
        self.windows.insert(
            key,
            OpenWindow {
                window,
                webview,
                last_html: html.to_owned(),
                last_title: pane.title.clone(),
            },
        );
    }

    /// Close one window and clear both indexes.
    fn close(&mut self, key: &PaneKey) {
        if let Some(open) = self.windows.remove(key) {
            self.by_window.remove(&open.window.id());
            // `open` drops here, closing the OS window.
        }
    }
}

/// The chrome-less, ghostty-flavored document a resource renders inside: a dark
/// monospace shell whose `#ix-root` holds the resource's own HTML, swapped in
/// place on update.
fn shell(title: &str, body: &str) -> String {
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\
<title>{title}</title><style>{STYLE}</style></head>\
<body><div id=\"ix-root\">{body}</div></body></html>",
        title = escape_text(title),
    )
}

/// Minimal escaping for text placed in an HTML text/attribute context (the
/// `<title>`). The body is producer-rendered HTML and is injected verbatim, the
/// same trust model as the web dashboard's sandboxed html pane.
fn escape_text(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Ghostty-flavored shell styling: a dark background, system monospace, comfy
/// padding, and a themed scrollbar. Catppuccin-ish tones to match the dashboard.
const STYLE: &str = "\
:root { color-scheme: dark; }
html, body { margin: 0; height: 100%; }
body {
  background: #1e1e2e;
  color: #cdd6f4;
  font: 14px/1.5 ui-monospace, 'SF Mono', Menlo, monospace;
}
#ix-root { padding: 14px; }
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-thumb { background: #45475a; border-radius: 5px; }
::-webkit-scrollbar-track { background: transparent; }
";

/// Let the webview render at the display's native refresh rate (120Hz on
/// `ProMotion`) instead of `WebKit`'s default ~60fps cap, by disabling the
/// "Prefer Page Rendering Updates near 60fps" experimental feature.
///
/// That feature is not a `KVC` property (`setValue:forKey:` raises
/// `NSUnknownKeyException`), so it goes through the private
/// `_setEnabled:forExperimentalFeature:` API, gated by `respondsToSelector:`
/// checks. Best-effort: on an OS without these selectors the webview is simply
/// left at the default cap.
#[cfg(target_os = "macos")]
fn enable_high_refresh(webview: &WebView) {
    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, Bool, NSObjectProtocol};
    use objc2::{ClassType, msg_send, sel};
    use objc2_foundation::NSString;
    use objc2_web_kit::WKPreferences;
    use wry::WebViewExtMacOS;

    /// The `WebKit` experimental-feature key for the ~60fps render cap.
    const FEATURE_KEY: &str = "PreferPageRenderingUpdatesNear60FPSEnabled";

    let wk = webview.webview();
    // SAFETY: ordinary Objective-C message sends to a live WKWebView and its
    // preferences on the main thread; the two private selectors are each gated by
    // a `responds_to` / `respondsToSelector:` check before use.
    unsafe {
        let prefs = wk.configuration().preferences();
        let class = WKPreferences::class();
        if !class.metaclass().responds_to(sel!(_experimentalFeatures))
            || !prefs.respondsToSelector(sel!(_setEnabled:forExperimentalFeature:))
        {
            return;
        }
        let features: Retained<AnyObject> = msg_send![class, _experimentalFeatures];
        let count: usize = msg_send![&*features, count];
        for i in 0..count {
            let feature: Retained<AnyObject> = msg_send![&*features, objectAtIndex: i];
            let key: Retained<NSString> = msg_send![&*feature, key];
            if key.to_string() == FEATURE_KEY {
                let _: () = msg_send![
                    &*prefs,
                    _setEnabled: Bool::new(false),
                    forExperimentalFeature: &*feature,
                ];
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{escape_text, shell};

    #[test]
    fn shell_wraps_body_in_ix_root_and_escapes_title() {
        let out = shell("a <b> & c", "<p>hi</p>");
        assert!(out.contains("<div id=\"ix-root\"><p>hi</p></div>"));
        assert!(out.contains("<title>a &lt;b&gt; &amp; c</title>"));
    }

    #[test]
    fn escape_text_covers_markup_metachars() {
        assert_eq!(escape_text("<&>"), "&lt;&amp;&gt;");
    }
}
