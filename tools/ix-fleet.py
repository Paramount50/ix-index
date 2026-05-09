#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
import typing
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator


def empty_str_list() -> list[str]:
    return []


def empty_int_list() -> list[int]:
    return []


def empty_str_dict() -> dict[str, str]:
    return {}


class BootstrapImage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    imageName: str = Field(min_length=1)
    imageTag: str = Field(min_length=1)
    destination: str = Field(min_length=1)
    source: str = Field(min_length=1)
    sourceDrv: str = Field(min_length=1)


class SwitchSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    target: str = Field(min_length=1)
    buildOn: typing.Literal["auto", "local", "remote"] = "auto"


class FleetNode(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1)
    baseName: str = Field(min_length=1)
    replicaIndex: int | None = None
    system: str = Field(min_length=1)
    switch: SwitchSpec
    bootstrapImage: BootstrapImage
    region: str = Field(min_length=1)
    ipv4: bool
    snapshot: bool
    tags: list[str] = Field(default_factory=empty_str_list)
    env: dict[str, str] = Field(default_factory=empty_str_dict)
    l7ProxyPorts: list[int] = Field(default_factory=empty_int_list)
    dependsOn: list[str] = Field(default_factory=empty_str_list)


class FleetPlan(BaseModel):
    model_config = ConfigDict(extra="forbid")

    order: list[str]
    nodes: dict[str, FleetNode]
    secrets: dict[str, typing.Any] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_graph(self) -> typing.Self:
        for name in self.order:
            if name not in self.nodes:
                raise ValueError(f"order references missing node {name!r}")
        for key, node in self.nodes.items():
            if key != node.name:
                raise ValueError(f"node key {key!r} does not match name {node.name!r}")
            for dep in node.dependsOn:
                if dep not in self.nodes:
                    raise ValueError(f"node {key!r} depends on unknown node {dep!r}")
        return self


def load_plan(path: Path) -> FleetPlan:
    return FleetPlan.model_validate_json(path.read_text())


def selected_names(plan: FleetPlan, selectors: list[str]) -> set[str]:
    if not selectors:
        return set(plan.order)

    selected: set[str] = set()
    for selector in selectors:
        if selector.startswith("@"):
            tag = selector[1:]
            if not tag:
                raise ValueError("empty tag selector")
            selected.update(name for name, node in plan.nodes.items() if tag in node.tags)
        elif selector in plan.nodes:
            selected.add(selector)
        else:
            raise ValueError(f"unknown node {selector!r}")
    return selected


def selected_nodes(plan: FleetPlan, selectors: list[str]) -> list[FleetNode]:
    selected = selected_names(plan, selectors)
    ordered: list[FleetNode] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visited:
            return
        if name in visiting:
            raise ValueError(f"dependency cycle at {name!r}")
        visiting.add(name)
        node = plan.nodes[name]
        for dep in node.dependsOn:
            visit(dep)
        visiting.remove(name)
        visited.add(name)
        ordered.append(node)

    for name in plan.order:
        if name in selected:
            visit(name)

    return ordered


def step(message: str) -> None:
    print(message, flush=True)


def run_cli(command: list[str], *, dry_run: bool) -> str:
    step("+ " + " ".join(command))
    if dry_run:
        return ""
    result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE)
    if result.stdout:
        print(result.stdout, end="")
    return result.stdout


async def push_bootstrap_image(node: FleetNode, *, dry_run: bool) -> str:
    image = node.bootstrapImage
    source = image.source
    if not dry_run and not Path(source).exists():
        out = run_cli(["nix-store", "--realise", image.sourceDrv], dry_run=False)
        realised = [line.strip() for line in out.splitlines() if line.strip()]
        if realised:
            source = realised[-1]

    out = run_cli(["ix", "push", source, image.destination], dry_run=dry_run)
    refs = [line.strip() for line in out.splitlines() if line.strip()]
    return refs[-1] if refs else image.destination


async def node_exists(node: FleetNode) -> bool:
    out = run_cli(["ix", "ls", "--output", "json"], dry_run=False)
    rows = json.loads(out)
    if not isinstance(rows, list):
        raise TypeError("ix ls --output json must return a list")
    return any(isinstance(row, dict) and row.get("name") == node.name for row in rows)


async def create_node(node: FleetNode, image: str, *, dry_run: bool) -> None:
    command = [
        "ix",
        "new",
        image,
        "--name",
        node.name,
        "--region",
        node.region,
        "--no-shell",
    ]
    for name, value in sorted(node.env.items()):
        command.extend(["--env", f"{name}={value}"])
    for port in node.l7ProxyPorts:
        command.extend(["--l7-proxy-port", str(port)])
    if node.ipv4:
        command.append("--ipv4")
    run_cli(command, dry_run=dry_run)


async def ensure_node(node: FleetNode, *, dry_run: bool) -> bool:
    if dry_run:
        step(f"ensure {node.name} exists from {node.bootstrapImage.destination}")
        return False
    if await node_exists(node):
        return False

    image = await push_bootstrap_image(node, dry_run=False)
    await create_node(node, image, dry_run=False)
    return True


async def snapshot_node(node: FleetNode, *, dry_run: bool) -> None:
    run_cli(["ix", "snapshot", "create", node.name], dry_run=dry_run)


async def switch_node(node: FleetNode, *, dry_run: bool) -> None:
    run_cli(
        ["ix", "switch", node.name, node.switch.target, "--build-on", node.switch.buildOn],
        dry_run=dry_run,
    )


async def replace_node(node: FleetNode, image: str, *, dry_run: bool) -> None:
    command = [
        "ix",
        "new",
        image,
        "--name",
        node.name,
        "--region",
        node.region,
        "--no-shell",
    ]
    for name, value in sorted(node.env.items()):
        command.extend(["--env", f"{name}={value}"])
    for port in node.l7ProxyPorts:
        command.extend(["--l7-proxy-port", str(port)])
    if node.ipv4:
        command.append("--ipv4")
    run_cli(command, dry_run=dry_run)


async def cmd_diff(plan: FleetPlan, args: argparse.Namespace) -> None:
    for node in selected_nodes(plan, args.on):
        print(f"{node.name}\twant {node.switch.target} ({node.switch.buildOn})")


async def cmd_switch(plan: FleetPlan, args: argparse.Namespace) -> None:
    for node in selected_nodes(plan, args.on):
        created = await ensure_node(node, dry_run=args.dry_run)
        if not created and node.snapshot and not args.no_snapshot:
            await snapshot_node(node, dry_run=args.dry_run)
        if not created:
            await switch_node(node, dry_run=args.dry_run)


async def cmd_replace(plan: FleetPlan, args: argparse.Namespace) -> None:
    for node in selected_nodes(plan, args.on):
        image = node.bootstrapImage.destination
        if not args.skip_push:
            image = await push_bootstrap_image(node, dry_run=args.dry_run)
        await replace_node(node, image, dry_run=args.dry_run)


def parser() -> argparse.ArgumentParser:
    def add_common_options(target: argparse.ArgumentParser, *, defaults: bool) -> None:
        target.add_argument(
            "--on",
            action="append",
            default=[] if defaults else argparse.SUPPRESS,
            metavar="NODE_OR_@TAG",
        )
        target.add_argument(
            "--dry-run",
            action="store_true",
            default=False if defaults else argparse.SUPPRESS,
        )

    p = argparse.ArgumentParser(prog="ix-fleet")
    p.add_argument("--plan", required=True, type=Path)
    add_common_options(p, defaults=True)

    sub = p.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    add_common_options(plan, defaults=False)
    diff = sub.add_parser("diff")
    add_common_options(diff, defaults=False)
    switch = sub.add_parser("switch")
    add_common_options(switch, defaults=False)
    switch.add_argument("--no-snapshot", action="store_true")
    replace = sub.add_parser("replace")
    add_common_options(replace, defaults=False)
    replace.add_argument("--skip-push", action="store_true")
    return p


async def main() -> None:
    args = parser().parse_args()
    plan = load_plan(args.plan)
    if args.command == "plan":
        nodes = [node.model_dump() for node in selected_nodes(plan, args.on)]
        print(json.dumps({"nodes": nodes}, indent=2))
    elif args.command == "diff":
        await cmd_diff(plan, args)
    elif args.command == "switch":
        await cmd_switch(plan, args)
    elif args.command == "replace":
        await cmd_replace(plan, args)
    else:
        raise AssertionError(args.command)


def run() -> None:
    try:
        asyncio.run(main())
    except (
        OSError,
        ValidationError,
        ValueError,
        TypeError,
        RuntimeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"ix-fleet: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    run()
