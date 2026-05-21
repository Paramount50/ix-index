from __future__ import annotations

import asyncio
import typing
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from pydantic import ValidationError

import ix_fleet


def fleet_node(name: str, *, depends_on: list[str] | None = None) -> dict[str, typing.Any]:
    return {
        "name": name,
        "baseName": name,
        "system": f"/nix/store/{name}-system",
        "switch": {
            "target": f"/nix/store/{name}-system.drv",
            "sourceInstallable": f".#{name}",
        },
        "bootstrapImage": "registry.ix.dev/ix/base:latest",
        "replacementImage": {
            "imageName": name,
            "imageTag": "latest",
            "destination": f"registry.ix.dev/example/{name}:latest",
            "source": f"/nix/store/{name}-image.tar",
            "sourceDrv": f"/nix/store/{name}-image.drv",
        },
        "region": "us-west-1",
        "ipv4": False,
        "snapshot": True,
        "dependsOn": depends_on or [],
    }


def fleet_plan(order: list[str], nodes: list[dict[str, typing.Any]]) -> dict[str, typing.Any]:
    return {
        "order": order,
        "nodes": {node["name"]: node for node in nodes},
    }


class FleetPlanValidationTests(unittest.TestCase):
    def test_rejects_nodes_missing_from_order(self) -> None:
        data = fleet_plan(["web"], [fleet_node("web"), fleet_node("db")])

        with self.assertRaisesRegex(ValidationError, "order is missing node 'db'"):
            ix_fleet.FleetPlan.model_validate(data)

    def test_rejects_duplicate_order_entries(self) -> None:
        data = fleet_plan(["web", "web"], [fleet_node("web")])

        with self.assertRaisesRegex(ValidationError, "order contains duplicate node 'web'"):
            ix_fleet.FleetPlan.model_validate(data)

    def test_selected_nodes_keeps_dependencies_before_selected_node(self) -> None:
        plan = ix_fleet.FleetPlan.model_validate(
            fleet_plan(["db", "web"], [fleet_node("web", depends_on=["db"]), fleet_node("db")])
        )

        self.assertEqual(
            [node.name for node in ix_fleet.selected_nodes(plan, ["web"])],
            ["db", "web"],
        )


class PushReplacementImageTests(unittest.TestCase):
    def test_uses_image_subcommand(self) -> None:
        with TemporaryDirectory() as temporary_directory:
            source = Path(temporary_directory) / "image.tar"
            source.write_text("")
            calls: list[list[str]] = []

            def fake_run_cli(command: list[str], *, dry_run: bool, timeout: int | None = None) -> str:
                del timeout
                calls.append(command)
                if command[0] == "nix-store":
                    return f"{source}\n"
                self.assertFalse(dry_run)
                return "registry.ix.dev/example/health-check-nginx:nginx-lifecycle\n"

            node = ix_fleet.FleetNode.model_validate(
                {
                    "name": "health-check-nginx",
                    "baseName": "nginx",
                    "system": "/nix/store/example-system",
                    "switch": {
                        "target": "/nix/store/example-system.drv",
                        "sourceInstallable": ".#health-check-nginx-system",
                    },
                    "bootstrapImage": "registry.ix.dev/ix/base:latest",
                    "replacementImage": {
                        "imageName": "health-check-nginx",
                        "imageTag": "nginx-lifecycle",
                        "destination": "health-check-nginx:nginx-lifecycle",
                        "source": str(source),
                        "sourceDrv": "/nix/store/example-image.drv",
                    },
                    "region": "us-west-1",
                    "ipv4": False,
                    "snapshot": True,
                }
            )

            with patch.object(ix_fleet, "run_cli", fake_run_cli):
                image = asyncio.run(ix_fleet.push_replacement_image(node, dry_run=False))

            self.assertEqual(
                calls,
                [
                    ["nix-store", "--realise", "/nix/store/example-image.drv"],
                    ["ix", "image", "push", str(source), "health-check-nginx:nginx-lifecycle"],
                ],
            )
            self.assertEqual(image, "registry.ix.dev/example/health-check-nginx:nginx-lifecycle")


if __name__ == "__main__":
    unittest.main()
