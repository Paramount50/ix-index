use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct AssetIndex {
    objects: HashMap<String, AssetObject>,
}

#[derive(Debug, Deserialize)]
struct AssetObject {
    hash: String,
}

/// Where sound `.ogg` files are read from.
pub enum MinecraftAssets {
    /// A flat `<name>.ogg` tree produced by the Nix sound pack and pointed at
    /// by `MCSOUND_ASSETS`. This needs no Minecraft install on the machine.
    Bundled { root: PathBuf },
    /// A real Minecraft install: the asset index maps sound names to hashed
    /// objects under `assets/objects/`.
    Install {
        minecraft_dir: PathBuf,
        objects: HashMap<String, String>,
    },
}

impl MinecraftAssets {
    /// Resolve the sound backend. A `MCSOUND_ASSETS` directory wins so the
    /// Nix-packaged build works with zero configuration; otherwise fall back
    /// to auto-detecting a Minecraft (or `MINECRAFT_HOME`) install.
    ///
    /// # Errors
    /// Returns an error if no install can be found or its asset index cannot
    /// be read or parsed.
    pub fn load() -> Result<Self> {
        if let Some(dir) = env::var_os("MCSOUND_ASSETS") {
            let root = PathBuf::from(dir);
            if root.is_dir() {
                return Ok(Self::Bundled { root });
            }
        }

        let minecraft_dir = find_minecraft_dir()?;
        let index_path = find_latest_index(&minecraft_dir)?;
        let content = fs::read_to_string(&index_path)
            .with_context(|| format!("Failed to read index file: {}", index_path.display()))?;
        let index: AssetIndex =
            serde_json::from_str(&content).context("Failed to parse asset index JSON")?;

        let objects = index
            .objects
            .into_iter()
            .filter(|(key, _)| key.starts_with("minecraft/sounds/") && is_ogg(key))
            .map(|(key, value)| (key, value.hash))
            .collect();

        Ok(Self::Install {
            minecraft_dir,
            objects,
        })
    }

    /// List available sound names, optionally keeping only those containing
    /// `pattern`. Names are the path with the `minecraft/sounds/` prefix and
    /// `.ogg` suffix stripped, e.g. `mob/zombie/death`.
    ///
    /// # Errors
    /// Returns an error if a bundled sound directory cannot be walked.
    pub fn list_sounds(&self, pattern: Option<&str>) -> Result<Vec<String>> {
        let mut sounds = match self {
            Self::Bundled { root } => {
                let mut names = Vec::new();
                collect_bundled(root, root, &mut names)?;
                names
            }
            Self::Install { objects, .. } => objects
                .keys()
                .filter_map(|key| {
                    key.strip_prefix("minecraft/sounds/")?
                        .strip_suffix(".ogg")
                        .map(str::to_owned)
                })
                .collect(),
        };

        if let Some(pattern) = pattern {
            sounds.retain(|name| name.contains(pattern));
        }
        sounds.sort();
        Ok(sounds)
    }

    /// Resolve a sound name (e.g. `mob/zombie/death`) to a file on disk.
    ///
    /// # Errors
    /// Returns an error if the sound is unknown or its file is missing.
    pub fn resolve_sound(&self, name: &str) -> Result<PathBuf> {
        let path = match self {
            Self::Bundled { root } => root.join(format!("{name}.ogg")),
            Self::Install {
                minecraft_dir,
                objects,
            } => {
                let key = format!("minecraft/sounds/{name}.ogg");
                let hash = objects
                    .get(&key)
                    .with_context(|| format!("Sound not found: {name}"))?;
                let prefix = hash
                    .get(..2)
                    .with_context(|| format!("Malformed hash: {hash}"))?;
                minecraft_dir
                    .join("assets")
                    .join("objects")
                    .join(prefix)
                    .join(hash)
            }
        };

        if !path.exists() {
            bail!("Sound file missing from disk: {}", path.display());
        }
        Ok(path)
    }
}

/// Recursively collect `<name>` for every `<name>.ogg` under `root`.
fn collect_bundled(root: &Path, dir: &Path, names: &mut Vec<String>) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("reading {}", dir.display()))? {
        let entry = entry.with_context(|| format!("reading entry in {}", dir.display()))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .with_context(|| format!("reading file type for {}", path.display()))?;

        if file_type.is_dir() {
            collect_bundled(root, &path, names)?;
        } else if path
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("ogg"))
            && let Some(name) = path
                .strip_prefix(root)
                .ok()
                .and_then(Path::to_str)
                .and_then(|rel| rel.strip_suffix(".ogg"))
        {
            names.push(name.to_owned());
        }
    }
    Ok(())
}

/// Case-insensitive `.ogg` extension check for asset-index keys (plain `&str`).
fn is_ogg(name: &str) -> bool {
    Path::new(name)
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("ogg"))
}

/// Auto-detect the Minecraft directory, honoring `MINECRAFT_HOME` first.
fn find_minecraft_dir() -> Result<PathBuf> {
    if let Some(home) = env::var_os("MINECRAFT_HOME") {
        let path = PathBuf::from(home);
        if path.exists() {
            return Ok(path);
        }
    }

    let path = if cfg!(target_os = "macos") {
        dirs::home_dir().map(|home| home.join("Library/Application Support/minecraft"))
    } else if cfg!(target_os = "windows") {
        dirs::data_dir().map(|data| data.join(".minecraft"))
    } else {
        dirs::home_dir().map(|home| home.join(".minecraft"))
    };

    let path = path.context("Could not determine home directory")?;
    if path.exists() {
        Ok(path)
    } else {
        bail!(
            "Minecraft directory not found at {}. Set MCSOUND_ASSETS or MINECRAFT_HOME, or install Minecraft.",
            path.display()
        )
    }
}

/// Numeric version of an asset-index file (`30.json` -> `Some(30)`).
fn index_version(entry: &fs::DirEntry) -> Option<u32> {
    entry
        .path()
        .file_stem()
        .and_then(|stem| stem.to_str())
        .and_then(|stem| stem.parse().ok())
}

/// Pick the highest-versioned `assets/indexes/<n>.json`.
fn find_latest_index(minecraft_dir: &Path) -> Result<PathBuf> {
    let indexes_dir = minecraft_dir.join("assets").join("indexes");
    if !indexes_dir.exists() {
        bail!("No asset indexes found. Have you launched Minecraft at least once?");
    }

    let indexes: Vec<fs::DirEntry> = fs::read_dir(&indexes_dir)
        .with_context(|| format!("reading {}", indexes_dir.display()))?
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "json"))
        .collect();

    indexes
        .into_iter()
        .max_by(|a, b| {
            index_version(a)
                .cmp(&index_version(b))
                .then_with(|| a.file_name().cmp(&b.file_name()))
        })
        .map(|entry| entry.path())
        .with_context(|| format!("No asset index files found in {}", indexes_dir.display()))
}
