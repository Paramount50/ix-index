use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::env;
use std::error::Error;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::fs::symlink;
use std::path::Path;
use std::process::{Command, Stdio};
use tempfile::tempdir;

#[derive(Deserialize)]
struct Config {
    architecture: String,
    config: Value,
    from_image: Value,
    store_layers: Vec<Vec<String>>,
    customisation_layer: String,
    created: String,
    mtime: String,
    uid: String,
    gid: String,
    store_dir: String,
}

#[derive(Serialize)]
struct Layer {
    checksum: String,
    size: u64,
    paths: Vec<String>,
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = env::args().collect();
    if args.len() != 3 {
        return Err(format!("usage: {} <conf.json> <out.tar>", args[0]).into());
    }

    let conf_path = Path::new(&args[1]);
    let out_path = Path::new(&args[2]);
    let conf: Config = serde_json::from_reader(File::open(conf_path)?)?;

    if !conf.from_image.is_null() {
        return Err("oci-image-builder: fromImage is not supported".into());
    }

    let created = parse_time(&conf.created)?.to_rfc3339_opts(SecondsFormat::Secs, false);
    let mtime = parse_time(&conf.mtime)?.timestamp().to_string();
    let work = tempdir()?;
    let image_dir = work.path().join("image");
    let blobs_dir = image_dir.join("blobs/sha256");
    let layers_dir = work.path().join("layers");
    fs::create_dir_all(&blobs_dir)?;
    fs::create_dir_all(&layers_dir)?;
    fs::write(
        image_dir.join("oci-layout"),
        r#"{"imageLayoutVersion":"1.0.0"}"#,
    )?;

    eprintln!("No 'fromImage' provided");

    let mut layers = Vec::with_capacity(conf.store_layers.len() + 1);
    for (index, paths) in conf.store_layers.iter().enumerate() {
        layers.push(make_store_layer(
            index + 1,
            paths,
            &conf,
            &mtime,
            &layers_dir,
            &blobs_dir,
        )?);
    }

    layers.push(make_customisation_layer(
        conf.store_layers.len() + 1,
        &conf.customisation_layer,
        &blobs_dir,
    )?);

    eprintln!("Adding manifests...");
    write_metadata(&conf, &created, &layers, &image_dir, &mtime, out_path)?;
    eprintln!("Done.");

    Ok(())
}

fn parse_time(value: &str) -> Result<DateTime<Utc>, Box<dyn Error>> {
    if value == "now" {
        return Ok(Utc::now());
    }

    Ok(DateTime::parse_from_rfc3339(value)?.with_timezone(&Utc))
}

fn make_store_layer(
    number: usize,
    paths: &[String],
    conf: &Config,
    mtime: &str,
    layers_dir: &Path,
    blobs_dir: &Path,
) -> Result<Layer, Box<dyn Error>> {
    let store_prefix = format!("{}/", conf.store_dir);
    for path in paths {
        if !path.starts_with(&store_prefix) {
            return Err(format!(
                "oci-image-builder: store layer contains path outside {}: {}",
                conf.store_dir, path
            )
            .into());
        }
    }

    eprintln!("Creating layer {number} from paths: {}", paths.join(" "));

    let paths_file = layers_dir.join(format!("{number}.paths"));
    fs::write(&paths_file, paths.join("\n"))?;

    let layer_tmp = layers_dir.join(format!("{number}.layer.tar"));
    let (checksum, size) = write_tar_layer(&layer_tmp, &paths_file, conf, mtime)?;
    fs::rename(&layer_tmp, blobs_dir.join(&checksum))?;

    Ok(Layer {
        checksum,
        size,
        paths: paths.to_vec(),
    })
}

fn make_customisation_layer(
    number: usize,
    customisation_layer: &str,
    blobs_dir: &Path,
) -> Result<Layer, Box<dyn Error>> {
    eprintln!("Creating layer {number} with customisation...");

    let customisation_layer = Path::new(customisation_layer);
    let checksum = fs::read_to_string(customisation_layer.join("checksum"))?
        .trim()
        .to_owned();
    if checksum.len() != 64 || !checksum.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(format!("oci-image-builder: invalid layer checksum: {checksum}").into());
    }

    let layer_path = customisation_layer.join("layer.tar");
    let size = fs::metadata(&layer_path)?.len();
    symlink(&layer_path, blobs_dir.join(&checksum))?;

    Ok(Layer {
        checksum,
        size,
        paths: vec![customisation_layer.display().to_string()],
    })
}

fn write_metadata(
    conf: &Config,
    created: &str,
    layers: &[Layer],
    image_dir: &Path,
    mtime: &str,
    out_path: &Path,
) -> Result<(), Box<dyn Error>> {
    let diff_ids: Vec<_> = layers
        .iter()
        .map(|layer| format!("sha256:{}", layer.checksum))
        .collect();
    let history: Vec<_> = layers
        .iter()
        .map(|layer| {
            serde_json::json!({
                "created": created,
                "comment": format!("store paths: {}", serde_json::to_string(&layer.paths).unwrap()),
            })
        })
        .collect();
    let image_config = serde_json::json!({
        "created": created,
        "architecture": conf.architecture,
        "os": "linux",
        "config": conf.config,
        "rootfs": {
            "diff_ids": diff_ids,
            "type": "layers",
        },
        "history": history,
    });
    let image_config = serde_json::to_vec_pretty(&image_config)?;
    let config_checksum = sha256_bytes(&image_config);
    let config_size = image_config.len();
    fs::write(
        image_dir.join("blobs/sha256").join(&config_checksum),
        image_config,
    )?;

    let manifest_layers: Vec<_> = layers
        .iter()
        .map(|layer| {
            serde_json::json!({
                "mediaType": "application/vnd.oci.image.layer.v1.tar",
                "digest": format!("sha256:{}", layer.checksum),
                "size": layer.size,
            })
        })
        .collect();
    let manifest = serde_json::json!({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {
            "mediaType": "application/vnd.oci.image.config.v1+json",
            "digest": format!("sha256:{config_checksum}"),
            "size": config_size,
        },
        "layers": manifest_layers,
    });
    let manifest = serde_json::to_vec_pretty(&manifest)?;
    let manifest_checksum = sha256_bytes(&manifest);
    let manifest_size = manifest.len();
    fs::write(
        image_dir.join("blobs/sha256").join(&manifest_checksum),
        manifest,
    )?;

    let index = serde_json::json!({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": format!("sha256:{manifest_checksum}"),
                "size": manifest_size,
            }
        ],
    });
    fs::write(
        image_dir.join("index.json"),
        serde_json::to_vec_pretty(&index)?,
    )?;

    let outer_files = image_dir.join("../outer-files");
    let mut entries = vec!["oci-layout".to_owned(), "index.json".to_owned()];
    let mut blobs = fs::read_dir(image_dir.join("blobs/sha256"))?
        .map(|entry| {
            entry.map(|entry| format!("blobs/sha256/{}", entry.file_name().to_string_lossy()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    blobs.sort();
    entries.extend(blobs);
    fs::write(&outer_files, entries.join("\n"))?;

    run(Command::new("tar")
        .arg("--create")
        .arg("--file")
        .arg(out_path)
        .arg("--no-recursion")
        .arg("--hard-dereference")
        .arg("--sort=name")
        .arg(format!("--mtime=@{mtime}"))
        .arg("--owner=0")
        .arg("--group=0")
        .arg("--numeric-owner")
        .arg("--directory")
        .arg(image_dir)
        .arg("--files-from")
        .arg(outer_files))?;

    Ok(())
}

fn write_tar_layer(
    layer_path: &Path,
    paths_file: &Path,
    conf: &Config,
    mtime: &str,
) -> Result<(String, u64), Box<dyn Error>> {
    let mut child = Command::new("tar")
        .arg("--create")
        .arg("--file")
        .arg("-")
        .arg("--absolute-names")
        .arg("--sort=name")
        .arg(format!("--mtime=@{mtime}"))
        .arg(format!("--owner={}", conf.uid))
        .arg(format!("--group={}", conf.gid))
        .arg("--numeric-owner")
        .arg("--no-recursion")
        .arg("/nix")
        .arg("/nix/store")
        .arg("--recursion")
        .arg("--hard-dereference")
        .arg("--files-from")
        .arg(paths_file)
        .stdout(Stdio::piped())
        .spawn()?;

    let mut stdout = child.stdout.take().ok_or("failed to capture tar stdout")?;
    let mut layer = File::create(layer_path)?;
    let mut hasher = Sha256::new();
    let mut size = 0;
    let mut buf = [0u8; 1024 * 1024];

    loop {
        let read = stdout.read(&mut buf)?;
        if read == 0 {
            break;
        }
        size += read as u64;
        hasher.update(&buf[..read]);
        layer.write_all(&buf[..read])?;
    }

    let status = child.wait()?;
    if !status.success() {
        return Err(format!("command failed with {status}: tar layer stream").into());
    }

    Ok((format!("{:x}", hasher.finalize()), size))
}

fn sha256_bytes(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

fn run(command: &mut Command) -> Result<(), Box<dyn Error>> {
    let status = command.status()?;
    if !status.success() {
        return Err(format!("command failed with {status}: {command:?}").into());
    }
    Ok(())
}
