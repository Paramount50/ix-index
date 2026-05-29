mod assets;
mod audio;

use std::env;
use std::io::Write;
use std::process::{Command, Stdio};

use anyhow::Result;
use clap::{Args, Parser, Subcommand};

use crate::assets::MinecraftAssets;

#[derive(Parser)]
#[command(
    name = "minecraft-sound",
    about = "Play Minecraft sounds from the command line",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// List available sounds, optionally filtered by a substring
    List { pattern: Option<String> },
    /// Play a sound by name (e.g. mob/zombie/death)
    Play(PlayArgs),
}

#[derive(Args)]
struct PlayArgs {
    /// Sound path (e.g. mob/zombie/death). If empty, does nothing.
    sound: Option<String>,

    /// Wait for playback to finish instead of returning immediately
    #[arg(short, long)]
    wait: bool,

    /// Internal: run playback in the foreground (used by the background spawn)
    #[arg(long, hide = true)]
    foreground: bool,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::List { pattern } => {
            let assets = MinecraftAssets::load()?;
            let mut out = std::io::stdout().lock();
            for sound in assets.list_sounds(pattern.as_deref())? {
                // Stop quietly when the reader goes away (e.g. `| head`)
                // instead of panicking on a broken pipe.
                if writeln!(out, "{sound}").is_err() {
                    break;
                }
            }
        }
        Commands::Play(args) => play(args)?,
    }

    Ok(())
}

fn play(args: PlayArgs) -> Result<()> {
    // Skip silently when no sound is given, so hooks can pass an empty string
    // to disable a particular event.
    let Some(sound) = args.sound.filter(|sound| !sound.is_empty()) else {
        return Ok(());
    };

    if args.wait || args.foreground {
        let assets = MinecraftAssets::load()?;
        let path = assets.resolve_sound(&sound)?;
        audio::play_ogg(&path)?;
    } else {
        // Re-spawn ourselves detached so the caller returns immediately while
        // the sound keeps playing in the background.
        let exe = env::current_exe()?;
        Command::new(exe)
            .args(["play", "--foreground", &sound])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
    }

    Ok(())
}
