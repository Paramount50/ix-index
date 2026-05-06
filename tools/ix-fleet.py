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


class FleetNode(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1)
    imageName: str = Field(min_length=1)
    imageTag: str = Field(min_length=1)
    destination: str = Field(min_length=1)
    source: str = Field(min_length=1)
    region: str = Field(min_length=1)
    ipv4: bool
    replace: bool
    tags: list[str] = Field(default_factory=empty_str_list)
    env: dict[str, str] = Field(default_factory=empty_str_dict)
    l7ProxyPorts: list[int] = Field(default_factory=empty_int_list)
    dependsOn: list[str] = Field(default_factory=empty_str_list)


class FleetPlan(BaseModel):
    model_config = ConfigDict(extra="forbid")

    order: list[str]
    nodes: dict[str, FleetNode]

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


def import_ix_sdk() -> tuple[typing.Any, typing.Any | None]:
    try:
        import ix_sdk  # type: ignore[import-not-found]
    except ModuleNotFoundError:
        return None, None
    client = getattr(ix_sdk, "Client", None) or getattr(ix_sdk, "IxClient", None)
    branch = getattr(ix_sdk, "Branch", None)
    if client is None:
        return None, branch
    return client(), branch


async def maybe_await(value: typing.Any) -> typing.Any:
    if typing.is_awaitable(value):
        return await value
    return value


async def push_node(client: typing.Any, node: FleetNode, *, dry_run: bool) -> str:
    push_archive = getattr(client, "push_image_archive", None) if client is not None else None
    if push_archive is not None:
        step(f"push {node.source} -> {node.destination}")
        if dry_run:
            return node.destination
        pushed = await maybe_await(push_archive(source=node.source, destination=node.destination))
        if not isinstance(pushed, str):
            raise TypeError("ix_sdk.Client.push_image_archive must return the pushed image ref")
        return pushed

    out = run_cli(["ix", "push", node.source, node.destination], dry_run=dry_run)
    refs = [line.strip() for line in out.splitlines() if line.strip()]
    return refs[-1] if refs else node.destination


async def deploy_node(
    client: typing.Any,
    branch_type: typing.Any | None,
    node: FleetNode,
    image: str,
    *,
    dry_run: bool,
) -> None:
    deploy = getattr(client, "deploy", None) if client is not None else None
    if deploy is not None:
        step(f"deploy {node.name} from {image}")
        if dry_run:
            return
        result = await maybe_await(
            deploy(
                name=node.name,
                image=image,
                region=node.region,
                env=node.env,
                l7_proxy_ports=node.l7ProxyPorts,
                ipv4=node.ipv4,
                replace=node.replace,
            )
        )
        if branch_type is not None and not isinstance(result, branch_type):
            raise TypeError("ix_sdk.Client.deploy returned an unexpected object")
        return

    if node.env or node.l7ProxyPorts or node.replace is False:
        raise RuntimeError(
            f"node {node.name!r} needs typed ix_sdk deploy support "
            "(env/l7 ports/non-replace are not representable through the current ix CLI fallback)"
        )

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
    if node.ipv4:
        command.append("--ipv4")
    run_cli(command, dry_run=dry_run)


async def cmd_push(plan: FleetPlan, args: argparse.Namespace) -> None:
    client, _branch_type = import_ix_sdk()
    refs: dict[str, str] = {}
    for node in selected_nodes(plan, args.on):
        refs[node.name] = await push_node(client, node, dry_run=args.dry_run)
    print(json.dumps(refs, indent=2))


async def cmd_deploy(plan: FleetPlan, args: argparse.Namespace) -> None:
    client, branch_type = import_ix_sdk()
    for node in selected_nodes(plan, args.on):
        image = node.destination
        if not args.skip_push:
            image = await push_node(client, node, dry_run=args.dry_run)
        await deploy_node(client, branch_type, node, image, dry_run=args.dry_run)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ix-fleet")
    p.add_argument("--plan", required=True, type=Path)
    p.add_argument("--on", action="append", default=[], metavar="NODE_OR_@TAG")
    p.add_argument("--dry-run", action="store_true")

    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("show")
    sub.add_parser("push")
    deploy = sub.add_parser("deploy")
    deploy.add_argument("--skip-push", action="store_true")
    return p


async def main() -> None:
    args = parser().parse_args()
    plan = load_plan(args.plan)
    if args.command == "show":
        nodes = [node.model_dump() for node in selected_nodes(plan, args.on)]
        print(json.dumps({"nodes": nodes}, indent=2))
    elif args.command == "push":
        await cmd_push(plan, args)
    elif args.command == "deploy":
        await cmd_deploy(plan, args)
    else:
        raise AssertionError(args.command)


def run() -> None:
    try:
        asyncio.run(main())
    except (OSError, ValidationError, ValueError, TypeError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ix-fleet: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    run()
