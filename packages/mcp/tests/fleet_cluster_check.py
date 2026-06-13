"""Self-contained checks for the `fleet` cluster surface (run with mcpPython,
not pytest, matching the other bundled-module smokes). Prints `fleet-cluster-ok`
on success. No live Ray cluster or network: the two discovery sources, the Ray
remote, and the kernel are all stubbed by attribute assignment.

Defends three contracts:
- `fleet.nodes()` joins the tailscale view with the Ray view on the IPv4, and
  stays informative with only one source present.
- `fleet.submit` return shape follows `on` (fan-out -> keyed dict; single
  explicit target -> bare value), independent of how many nodes are alive.
- `/api/exec` is gated: disabled without a token, 401 on a wrong token, runs on
  the live kernel with the right one.
"""

import asyncio
import pathlib
import tempfile

import fleet
from fleet import cluster


def check_nodes_merge():
    status = {
        "Self": {
            "DNSName": "hydra.ts.net.",
            "HostName": "hydra",
            "TailscaleIPs": ["100.0.0.1"],
            "Online": True,
        },
        "Peer": {
            "p": {"DNSName": "hc1.ts.net.", "TailscaleIPs": ["100.0.0.2"], "Online": True},
        },
    }
    ray_nodes = [
        {
            "NodeManagerAddress": "100.0.0.1",
            "Alive": True,
            "NodeID": "abc",
            "Resources": {"CPU": 8.0, "memory": 16_000_000_000},
        }
    ]

    async def fake_status():
        return status

    cluster._tailscale_status = fake_status
    cluster._ray_nodes = lambda: ray_nodes
    df = asyncio.run(fleet.nodes())
    rows = {r["host"]: r for r in df.to_dicts()}

    assert rows["hydra.ts.net"]["self"] is True, rows["hydra.ts.net"]
    assert rows["hydra.ts.net"]["ray_alive"] is True, rows["hydra.ts.net"]
    assert rows["hydra.ts.net"]["cpu"] == 8.0, rows["hydra.ts.net"]
    assert rows["hydra.ts.net"]["memory_gb"] == 16.0, rows["hydra.ts.net"]
    # A tailnet peer with no Ray match still appears, Ray columns null.
    assert rows["hc1.ts.net"]["ray_alive"] is None, rows["hc1.ts.net"]
    assert rows["hc1.ts.net"]["tailscale_ip"] == "100.0.0.2", rows["hc1.ts.net"]


class _FakeRemote:
    """Stands in for ray.remote(fn).options(...); .remote() records the pinned
    node instead of scheduling anything."""

    def __init__(self, node_id):
        self._node_id = node_id

    def remote(self, *args, **kwargs):
        return "ref:" + str(self._node_id)


def check_submit_shape():
    cluster.connect = lambda *a, **k: None
    cluster._alive_ray_nodes = lambda: [
        {"NodeID": "n1", "NodeManagerHostname": "a", "NodeManagerAddress": "100.0.0.1"},
        {"NodeID": "n2", "NodeManagerHostname": "b", "NodeManagerAddress": "100.0.0.2"},
    ]
    cluster._remote = lambda fn, nid, opts: _FakeRemote(nid)

    assert fleet.submit(lambda: None, on="all") == {"a": "ref:n1", "b": "ref:n2"}
    assert fleet.submit(lambda: None, on=["a", "b"]) == {"a": "ref:n1", "b": "ref:n2"}
    assert fleet.submit(lambda: None, on="any") == "ref:None"
    assert fleet.submit(lambda: None, on="a") == "ref:n1"

    try:
        fleet.submit(lambda: None, on="nope")
    except cluster.ClusterError:
        pass
    else:
        raise AssertionError("expected ClusterError for an unknown target")


def check_in_kernel_requires_token():
    import os

    os.environ.pop("IX_MCP_EXEC_TOKEN", None)
    os.environ.pop("IX_MCP_EXEC_TOKEN_FILE", None)
    try:
        asyncio.run(fleet.in_kernel("all", "1+1"))
    except cluster.ClusterError as exc:
        assert "token" in str(exc), exc
    else:
        raise AssertionError("expected ClusterError without a token")


def check_exec_auth():
    from aiohttp.test_utils import TestClient, TestServer

    from ix_notebook_mcp import dashboard, kernel, store
    from ix_notebook_mcp.config import Config

    tmp = pathlib.Path(tempfile.mkdtemp())

    class _FakeKernel:
        async def python_exec(self, code, budget):
            return [], {"output": "", "result": "2", "error": None, "status": "ok"}

    kernel.current_kernel = lambda: _FakeKernel()

    async def request(token, auth):
        conn = store.connect(tmp / "store.db")
        cfg = Config(workdir=tmp, store_path=tmp / "store.db", exec_token=token)
        app = dashboard.build_app(cfg, conn)
        async with TestClient(TestServer(app)) as client:
            headers = {"Authorization": auth} if auth else {}
            resp = await client.post("/api/exec", json={"code": "1+1"}, headers=headers)
            body = await resp.json() if resp.status == 200 else None
            return resp.status, body

    status, _ = asyncio.run(request(None, None))
    assert status == 403, status  # disabled when no token configured
    status, _ = asyncio.run(request("secret", "Bearer wrong"))
    assert status == 401, status  # wrong token rejected
    status, body = asyncio.run(request("secret", "Bearer secret"))
    assert status == 200 and body["result"] == "2", (status, body)


check_nodes_merge()
check_submit_shape()
check_in_kernel_requires_token()
check_exec_auth()
print("fleet-cluster-ok")
