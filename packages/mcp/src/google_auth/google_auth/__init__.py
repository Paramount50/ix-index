"""Google OAuth credentials for the bundled Gmail/Calendar Python clients.

The ix-mcp interpreter bundles the official Google API client
(`google-api-python-client`), but a session has no credential to hand it. This
module mints one from the shared Google grant the `gcal` binary holds: it shells
to `gcal print-access-token --json` (via `IX_GCAL_BIN`, set on the mcp wrapper)
for a current access token and returns a `google.oauth2.credentials.Credentials`
that transparently re-mints when the token expires. The refresh token and client
secret stay inside the binary; only short-lived access tokens cross into Python.

    import google_auth

    gmail = google_auth.gmail()          # googleapiclient Resource for Gmail
    cal = google_auth.calendar()         # ... and Calendar
    print(gmail.users().getProfile(userId="me").execute()["emailAddress"])

    # or build any Google API yourself from the credentials:
    from googleapiclient.discovery import build
    drive = build("drive", "v3", credentials=google_auth.credentials())

The grant covers Gmail (read/modify/send) and Calendar events. It needs a
one-time `gcal auth` on the host running the MCP server; until then (or if the
stored grant predates the Gmail scopes) calls raise `GoogleAuthError` with that
instruction.

Gmail and Calendar reach the user's personal mailbox and schedule, so they are
confined to an **incognito session** -- one whose transcript is never replicated
to a shared room. Incognito is the default: a plain ix-mcp (a single-user chat,
a Claude Code session, the room's per-thread private MCP) is incognito and may
mint a token. The exception is a **shared (multiplayer) room**: the room marks
the one MCP it shares across participants with ``IX_MCP_SHARED=1``, and minting
from there raises `GoogleAuthError`. This keeps a personal credential, and any
mail it reads, out of state that syncs to other people.
"""

from __future__ import annotations

import datetime
import json
import os
import subprocess

from google.oauth2.credentials import Credentials

__all__ = ["GoogleAuthError", "calendar", "credentials", "gmail", "service"]

# Refresh a little early so a call near the boundary does not race expiry.
_EXPIRY_SKEW = datetime.timedelta(seconds=30)

# Default access-token lifetime when the binary does not report `expires_in`
# (Google access tokens last ~1h); keeps `expiry` concrete so google-auth knows
# to call the refresh handler again rather than treating the token as eternal.
_DEFAULT_LIFETIME = 3600

# Minting is a single token-endpoint refresh; cap it so a network stall surfaces
# rather than hanging the kernel.
_MINT_TIMEOUT = 30.0


class GoogleAuthError(RuntimeError):
    """Raised when an access token cannot be minted from the stored grant."""


# The env var a shared (multiplayer) room sets on the one MCP it shares across
# participants. Incognito is the default, so an unset (or empty) value means a
# token may be minted; only a truthy value marks the session shared and refuses
# minting, keeping the personal Google grant out of synced room state.
SHARED_ENV = "IX_MCP_SHARED"


def _require_incognito() -> None:
    """Allow token minting unless the session is a shared (multiplayer) room.

    Gmail/Calendar read personal data, so they are confined to incognito
    sessions -- the default for a plain ix-mcp. A shared room marks the MCP it
    replicates across participants with ``IX_MCP_SHARED``; only then is minting
    refused, so a personal credential never reaches state other people can see.
    """
    if os.environ.get(SHARED_ENV):
        raise GoogleAuthError(
            "Gmail and Calendar are not available in a shared (multiplayer) room "
            "(IX_MCP_SHARED is set), because they would expose a personal mailbox "
            "to everyone in the room. Use them from an incognito chat instead; its "
            "transcript and credential stay private to you."
        )


def _mint() -> dict:
    _require_incognito()
    binary = os.environ.get("IX_GCAL_BIN")
    if not binary:
        raise GoogleAuthError("IX_GCAL_BIN is not set; the gcal binary is bundled into ix-mcp")
    proc = subprocess.run(
        [binary, "print-access-token", "--json"],
        capture_output=True,
        text=True,
        timeout=_MINT_TIMEOUT,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise GoogleAuthError(
            detail or f"gcal print-access-token exited with status {proc.returncode}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        # Deliberately omit the body: with `--json` it should be JSON, and on a
        # bug it could contain the access token, which must not land in an error.
        raise GoogleAuthError(
            f"gcal print-access-token returned non-JSON output ({len(proc.stdout)} bytes)"
        ) from exc


def _expiry(expires_in: object) -> datetime.datetime:
    seconds = expires_in if isinstance(expires_in, int) and expires_in > 0 else _DEFAULT_LIFETIME
    # google-auth compares `expiry` against a naive UTC clock, so keep it naive.
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    return now + datetime.timedelta(seconds=seconds) - _EXPIRY_SKEW


def _refresh_handler(request: object, scopes: object) -> tuple[str, datetime.datetime]:
    """google-auth refresh hook: mint a fresh token from the bundled binary.

    This is google-auth's documented extension point for tokens fetched from an
    external broker on demand (`Credentials(refresh_handler=...)`). The library
    calls it with the transport and requested scopes (both ignored: the binary
    always mints the full shared grant) and expects `(token, expiry)`. Routing
    through it keeps the refresh token and client secret inside the binary.
    """
    data = _mint()
    return data["access_token"], _expiry(data.get("expires_in"))


def credentials() -> Credentials:
    """Mint Google credentials from the shared grant (Gmail + Calendar).

    Returns a stock `google.oauth2.credentials.Credentials` wired to re-mint via
    the bundled binary (`refresh_handler`) when the access token expires. Raises
    `GoogleAuthError` if the grant is missing (run `gcal auth` on the MCP host)
    or the binary is unavailable.
    """
    data = _mint()
    return Credentials(
        token=data["access_token"],
        expiry=_expiry(data.get("expires_in")),
        scopes=data.get("scopes"),
        refresh_handler=_refresh_handler,
    )


def service(api: str, version: str):
    """Build a googleapiclient Resource for `api`/`version` with the grant."""
    from googleapiclient.discovery import build

    return build(api, version, credentials=credentials(), cache_discovery=False)


def gmail(version: str = "v1"):
    """A Gmail API client: `gmail().users().messages()`, `.send()`, ..."""
    return service("gmail", version)


def calendar(version: str = "v3"):
    """A Google Calendar API client: `calendar().events()`, ..."""
    return service("calendar", version)
