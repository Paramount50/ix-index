#!/usr/bin/env python3
from __future__ import annotations

import argparse
import secrets
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import cast


@dataclass(frozen=True)
class Config:
    data_dir: Path
    drop_dir: str
    managed_root: Path
    plugman_reload: bool
    plugman_ignored_plugins: frozenset[str]
    rcon_port: int
    rcon_password_file: Path


def managed_files(source_dir: Path) -> list[str]:
    if not source_dir.exists():
        return []

    files: list[str] = []
    for path in source_dir.rglob("*"):
        if not (path.is_file() or path.is_symlink()):
            continue
        rel = path.relative_to(source_dir).as_posix()
        if rel.endswith(".plugin-name"):
            continue
        files.append(rel)
    return sorted(files)


def manifest_rel(line: str) -> str:
    return line.split(" ", 1)[0]


def read_manifest_lines(manifest: Path) -> list[str]:
    if not manifest.exists():
        return []
    return manifest.read_text(encoding="utf-8").splitlines()


def remove_if_present(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return


def sync_tree(source_dir: Path, target_dir: Path, manifest: Path) -> None:
    target_dir.mkdir(parents=True, exist_ok=True)
    manifest.parent.mkdir(parents=True, exist_ok=True)

    for line in read_manifest_lines(manifest):
        rel = manifest_rel(line)
        if rel:
            remove_if_present(target_dir / rel)

    tmp = manifest.with_name(f"{manifest.name}.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        for rel in managed_files(source_dir):
            source_path = source_dir / rel
            target_path = target_dir / rel
            target_path.parent.mkdir(parents=True, exist_ok=True)
            remove_if_present(target_path)
            target_path.symlink_to(source_path)
            _ = handle.write(f"{rel} {source_path.resolve()}\n")

    _ = tmp.replace(manifest)


def managed_target_for(manifest: Path, rel: str) -> str | None:
    prefix = f"{rel} "
    for line in read_manifest_lines(manifest):
        if line.startswith(prefix):
            return line[len(prefix) :]
    return None


def plugin_name_for(managed_root: Path, rel: str) -> str:
    metadata = managed_root / "managed-dropins" / f"{rel}.plugin-name"
    if metadata.exists():
        first_line = metadata.read_text(encoding="utf-8").splitlines()[0:1]
        if first_line:
            return first_line[0]
    return Path(rel).stem


def plugin_name_from_config_path(rel: str) -> str | None:
    parts = rel.split("/")
    if len(parts) >= 3 and parts[0] == "plugins":
        return parts[1]
    return None


def add_plan(plan: set[tuple[str, str]], action: str, plugin: str) -> None:
    plan.add((action, plugin))


def write_plan(plan_path: Path, plan: set[tuple[str, str]]) -> None:
    lines = [f"{action} {plugin}" for action, plugin in sorted(plan)]
    _ = plan_path.write_text(("\n".join(lines) + "\n") if lines else "", encoding="utf-8")


def plan_dropin_reloads(cfg: Config, plan: set[tuple[str, str]]) -> None:
    dropin_manifest = cfg.data_dir / f".ix-managed-{cfg.drop_dir}"
    managed_dropins = cfg.managed_root / "managed-dropins"
    if not (dropin_manifest.exists() and managed_dropins.exists()):
        return

    for rel in managed_files(managed_dropins):
        if rel == "PlugManX.jar" or not rel.endswith(".jar"):
            continue

        target = str((managed_dropins / rel).resolve())
        old_target = managed_target_for(dropin_manifest, rel)
        plugin = plugin_name_for(cfg.managed_root, rel)
        if plugin in cfg.plugman_ignored_plugins:
            continue

        if old_target is None:
            add_plan(plan, "load", plugin)
        elif old_target != target:
            add_plan(plan, "reload", plugin)

    for line in read_manifest_lines(dropin_manifest):
        rel = manifest_rel(line)
        if not rel.endswith(".jar") or rel == "PlugManX.jar":
            continue

        plugin = plugin_name_for(cfg.managed_root, rel)
        if plugin in cfg.plugman_ignored_plugins:
            continue
        if not (managed_dropins / rel).exists():
            add_plan(plan, "unload", plugin)


def plan_server_file_reloads(cfg: Config, plan: set[tuple[str, str]]) -> None:
    server_manifest = cfg.data_dir / ".ix-managed-server-files"
    managed_server_files = cfg.managed_root / "managed-server-files"
    if not (server_manifest.exists() and managed_server_files.exists()):
        return

    for rel in managed_files(managed_server_files):
        plugin = plugin_name_from_config_path(rel)
        if plugin is None or plugin in cfg.plugman_ignored_plugins:
            continue

        target = str((managed_server_files / rel).resolve())
        old_target = managed_target_for(server_manifest, rel)
        if old_target is None or old_target != target:
            add_plan(plan, "reload", plugin)

    for line in read_manifest_lines(server_manifest):
        rel = manifest_rel(line)
        plugin = plugin_name_from_config_path(rel)
        if plugin is None or plugin in cfg.plugman_ignored_plugins:
            continue

        if not (managed_server_files / rel).exists():
            add_plan(plan, "reload", plugin)


def plan_plugman_reload(cfg: Config) -> None:
    plan_path = cfg.data_dir / f".ix-managed-{cfg.drop_dir}.reload-plan"
    plan_path.parent.mkdir(parents=True, exist_ok=True)
    plan: set[tuple[str, str]] = set()
    plan_dropin_reloads(cfg, plan)
    plan_server_file_reloads(cfg, plan)
    write_plan(plan_path, plan)


def ensure_rcon_password(cfg: Config) -> None:
    cfg.rcon_password_file.parent.mkdir(parents=True, exist_ok=True)
    if cfg.rcon_password_file.exists() and cfg.rcon_password_file.read_text(encoding="utf-8").strip():
        return

    _ = cfg.rcon_password_file.write_text(f"{secrets.token_hex(32)}\n", encoding="utf-8")
    cfg.rcon_password_file.chmod(0o600)


def set_property(file: Path, key: str, value: str) -> None:
    lines = file.read_text(encoding="utf-8").splitlines() if file.exists() else []
    replacement = f"{key}={value}"
    found = False
    next_lines: list[str] = []

    for line in lines:
        if line.startswith(f"{key}="):
            next_lines.append(replacement)
            found = True
        else:
            next_lines.append(line)

    if not found:
        next_lines.append(replacement)

    _ = file.write_text("\n".join(next_lines) + "\n", encoding="utf-8")


def configure_rcon(cfg: Config) -> None:
    ensure_rcon_password(cfg)
    server_properties = cfg.data_dir / "server.properties"

    if server_properties.is_symlink():
        tmp = server_properties.with_name(f"{server_properties.name}.tmp")
        _ = tmp.write_bytes(server_properties.read_bytes())
        _ = tmp.replace(server_properties)
    elif not server_properties.exists():
        _ = server_properties.write_text("", encoding="utf-8")

    server_properties.chmod(0o600)
    password = cfg.rcon_password_file.read_text(encoding="utf-8").splitlines()[0]
    set_property(server_properties, "enable-rcon", "true")
    set_property(server_properties, "rcon.port", str(cfg.rcon_port))
    set_property(server_properties, "rcon.password", password)
    set_property(server_properties, "broadcast-rcon-to-ops", "false")


def parse_args(argv: Sequence[str] | None = None) -> Config:
    parser = argparse.ArgumentParser(description="Sync ix-managed Minecraft files into the mutable data directory")
    _ = parser.add_argument("--data-dir", required=True)
    _ = parser.add_argument("--drop-dir", required=True)
    _ = parser.add_argument("--managed-root", required=True)
    _ = parser.add_argument("--plugman-reload", action="store_true")
    _ = parser.add_argument("--plugman-ignored-plugin", action="append", default=[])
    _ = parser.add_argument("--rcon-port", type=int, required=True)
    _ = parser.add_argument("--rcon-password-file", required=True)
    args = parser.parse_args(argv)

    return Config(
        data_dir=Path(cast(str, args.data_dir)),
        drop_dir=cast(str, args.drop_dir),
        managed_root=Path(cast(str, args.managed_root)),
        plugman_reload=cast(bool, args.plugman_reload),
        plugman_ignored_plugins=frozenset(cast(list[str], args.plugman_ignored_plugin)),
        rcon_port=cast(int, args.rcon_port),
        rcon_password_file=Path(cast(str, args.rcon_password_file)),
    )


def main(argv: Sequence[str] | None = None) -> int:
    cfg = parse_args(argv)

    if cfg.plugman_reload:
        plan_plugman_reload(cfg)

    sync_tree(cfg.managed_root / "managed-dropins", cfg.data_dir / cfg.drop_dir, cfg.data_dir / f".ix-managed-{cfg.drop_dir}")
    sync_tree(cfg.managed_root / "managed-config", cfg.data_dir / "config", cfg.data_dir / ".ix-managed-config")
    sync_tree(cfg.managed_root / "managed-server-files", cfg.data_dir, cfg.data_dir / ".ix-managed-server-files")

    if cfg.plugman_reload:
        configure_rcon(cfg)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
