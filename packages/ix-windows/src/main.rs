//! `ix-windows`: open one borderless native webview window per live MCP
//! resource.
//!
//! A thin wrapper around [`ix_windows::WindowManager`]. It subscribes to the
//! shared dashboard producer sockets ([`dashboard_core::subscribe`]) on a side
//! tokio runtime and forwards each event to the main-thread `tao` event loop,
//! where windows must live. The MCP already publishes every resource onto those
//! sockets as a `resource/<id>` html pane, so this process renders them with no
//! change to the MCP.

use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use clap::Parser;
use dashboard_core::{ProducerEvent, discovery_dir, subscribe};
use ix_windows::WindowManager;
use tao::event::{Event, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder};

/// Render live MCP resources as borderless webview windows.
#[derive(Parser)]
#[command(name = "ix-windows", version, about)]
struct Cli {
    /// Directory of producer sockets to watch. Defaults to the ix discovery
    /// directory (`$IX_DASH_DIR`, `$XDG_RUNTIME_DIR/ix-dash`, or
    /// `/tmp/ix-dash-*`), matching the `dashboard` aggregator.
    #[arg(long)]
    dir: Option<PathBuf>,

    /// How often to rescan the directory for new or removed sockets, in
    /// milliseconds.
    #[arg(long, default_value_t = 500)]
    rescan_ms: u64,
}

fn main() {
    let cli = Cli::parse();
    let dir = cli.dir.unwrap_or_else(discovery_dir);
    let rescan = Duration::from_millis(cli.rescan_ms);

    // The user-event loop carries `ProducerEvent`s from the subscriber thread.
    let event_loop = EventLoopBuilder::<ProducerEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    // Windows must be created and driven on the main thread, but the subscriber
    // is async. Run it on its own tokio runtime in a side thread and forward
    // every event into the event loop via the proxy.
    thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("build tokio runtime");
        runtime.block_on(async move {
            let mut events = subscribe(dir, rescan, &tokio::runtime::Handle::current());
            while let Some(event) = events.recv().await {
                if proxy.send_event(event).is_err() {
                    break; // the event loop has exited; stop forwarding.
                }
            }
        });
    });

    let mut manager = WindowManager::new();
    event_loop.run(move |event, target, control_flow| {
        // Idle until the next OS or producer event; this is a reactive viewer,
        // not an animation loop.
        *control_flow = ControlFlow::Wait;
        match event {
            Event::UserEvent(ProducerEvent::Snapshot(snapshot)) => {
                manager.apply_snapshot(target, &snapshot);
            }
            Event::UserEvent(ProducerEvent::Gone { producer }) => {
                manager.producer_gone(&producer);
            }
            Event::WindowEvent {
                window_id,
                event: WindowEvent::CloseRequested,
                ..
            } => {
                manager.window_closed(window_id);
            }
            _ => {}
        }
    });
}
