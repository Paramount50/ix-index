"""Offline regression tests for the --stream input path.

Run by the ``streaming`` passthru test with the built venv interpreter. Network
is never touched: the WebSocket client is only constructed, not connected.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Literal, TextIO, cast  # noqa: TID251 -- casting test doubles to their interface is intentional
from unittest.mock import patch

import elevenlabs.realtime_tts as realtime_module
from elevenlabs import ElevenLabs
from elevenlabs.core import ApiError

import elevenlabs_say as say


@contextmanager
def fake_stdin(stdin: object) -> Iterator[None]:
    """Swap ``sys.stdin`` for a stand-in that implements only what the code uses.

    The tests' fakes implement just ``fileno``/``isatty``, not the full
    ``TextIO`` protocol, so a direct ``sys.stdin = fake`` is a type error.
    ``patch.object`` takes the attribute by name (``str``) and restores it on
    exit, which both types cleanly and removes the manual try/finally.
    """
    with patch.object(sys, "stdin", cast(TextIO, stdin)):
        yield


def test_stdin_yields_before_eof_and_rejoins_split_utf8() -> None:
    """stdin is forwarded as bytes arrive, and a byte-split char is preserved.

    Guards the core streaming contract: a producer that has not closed its end
    still gets its text spoken, and a multi-byte character split across two reads
    is not corrupted. A regression to ``sys.stdin.read()`` or line iteration
    would block until EOF and fail the "before close" assertion.
    """
    read_fd, write_fd = os.pipe()

    class FakeStdin:
        def fileno(self) -> int:
            return read_fd

        def isatty(self) -> bool:
            return False

    chunks: list[str] = []

    def drain() -> None:
        for chunk in say.stdin_text_chunks():
            chunks.append(chunk)

    with fake_stdin(FakeStdin()):
        worker = threading.Thread(target=drain)
        worker.start()
        time.sleep(0.15)
        os.write(write_fd, b"hello ")
        time.sleep(0.15)
        before_close = len(chunks)
        # "ä" is 0xC3 0xA4; split it across two reads.
        os.write(write_fd, b"\xc3")
        time.sleep(0.05)
        os.write(write_fd, b"\xa4 world")
        time.sleep(0.1)
        os.close(write_fd)
        worker.join(timeout=2)

    assert before_close >= 1, f"stdin did not stream before EOF: {chunks}"
    assert "".join(chunks) == "hello ä world", chunks


def test_write_stream_writes_chunks_and_rejects_empty() -> None:
    out = Path(tempfile.mktemp(suffix=".mp3"))
    say.write_stream(iter([b"abc", b"def"]), out)
    assert out.read_bytes() == b"abcdef"
    out.unlink()

    empty = Path(tempfile.mktemp(suffix=".mp3"))
    try:
        say.write_stream(iter([]), empty)
    except say.SayError as exc:
        assert "no audio" in str(exc), exc
    else:
        raise AssertionError("expected SayError on empty stream")
    assert not empty.exists(), "an empty mp3 must not be left behind"


def test_play_stream_rejects_empty_without_spawning_ffplay() -> None:
    try:
        say.play_stream(iter([]))
    except say.SayError as exc:
        assert "no audio" in str(exc), exc
    else:
        raise AssertionError("expected SayError on empty stream")


def test_stream_client_narrows_to_realtime() -> None:
    """The wired client exposes convert_realtime, so --stream has a transport."""
    os.environ["ELEVENLABS_API_KEY"] = "test-key-not-used"
    client = say.make_client()
    realtime = say.stream_client(client)
    assert hasattr(realtime, "convert_realtime"), realtime


def test_should_stream_auto_and_overrides() -> None:
    """Pipe auto-streams, TEXT/--file batch, explicit --stream/--no-stream win."""

    class FakeStdin:
        def __init__(self, tty: bool) -> None:
            self._tty = tty

        def isatty(self) -> bool:
            return self._tty

    with fake_stdin(FakeStdin(tty=False)):
        assert say.should_stream(say.parse_args([])) is True
        assert say.should_stream(say.parse_args(["--no-stream"])) is False
        assert say.should_stream(say.parse_args(["hello"])) is False
        assert say.should_stream(say.parse_args(["hello", "--stream"])) is True
        assert say.should_stream(say.parse_args(["--file", "notes.txt"])) is False

    with fake_stdin(FakeStdin(tty=True)):
        assert say.should_stream(say.parse_args([])) is False
        assert say.should_stream(say.parse_args(["--stream"])) is True


def test_stream_init_does_not_crash_on_omit_voice_settings() -> None:
    """Regression: building convert_realtime's init frame must not trip the SDK's
    OMIT-sentinel bug, where voice_settings defaults to Ellipsis (truthy, no
    .dict()) and crashes. stream_synthesize passes voice_settings=None; assert the
    init frame is sent and carries a null voice_settings.
    """
    os.environ["ELEVENLABS_API_KEY"] = "test-key-not-used"
    client = say.make_client()

    class _StopAfterInit(Exception):
        pass

    class FakeSocket:
        def __init__(self) -> None:
            self.sent: list[str] = []

        def send(self, message: str) -> None:
            self.sent.append(message)
            raise _StopAfterInit

        def recv(self, *args: object) -> str:
            raise _StopAfterInit

    socket = FakeSocket()

    class FakeConnection:
        def __enter__(self) -> FakeSocket:
            return socket

        # Literal[False] (not bool): a context manager whose __exit__ can return
        # True is treated as possibly swallowing exceptions; this one never does.
        def __exit__(self, *args: object) -> Literal[False]:
            return False

    def fake_connect(*args: object, **kwargs: object) -> FakeConnection:
        return FakeConnection()

    # patch.object swaps the module attribute by name, so the re-imported
    # websockets `connect` (not part of the module's public surface) can be
    # replaced without an attr-defined/assignment type error, and it restores on
    # exit.
    with patch.object(realtime_module, "connect", fake_connect):
        chunks = say.stream_synthesize(
            client, say.parse_args(["hi", "--stream"]), "voice-id"
        )
        try:
            next(iter(chunks))
        except _StopAfterInit:
            pass

    assert socket.sent, "init frame was never sent"
    init = json.loads(socket.sent[0])
    assert init["voice_settings"] is None, init


def test_atempo_filter_maps_wpm_to_in_range_stages() -> None:
    """--rate maps WPM to an atempo chain whose stages stay in ffmpeg's range and
    multiply back to rate/175. Guards the say -r emulation and the stage decomposition.
    """
    assert say.atempo_filter(None) is None
    for rate in (350, 525, 175, 88, 43, 700, 20):
        chain = say.atempo_filter(rate)
        assert chain is not None
        stages = [float(part.removeprefix("atempo=")) for part in chain.split(",")]
        assert all(0.5 <= s <= 100.0 for s in stages), (rate, stages)
        product = 1.0
        for s in stages:
            product *= s
        assert abs(product - rate / say.DEFAULT_WPM) < 1e-3, (rate, product)
    for bad in (0, -5):
        try:
            say.atempo_filter(bad)
        except say.SayError:
            pass
        else:
            raise AssertionError(f"expected SayError for rate={bad}")


def test_say_compat_flags_parse() -> None:
    """macOS-style `-v` (voice) and `-r` (rate) aliases parse into CliArgs."""
    args = say.parse_args(["hello", "-v", "Adam", "-r", "300"])
    assert args.voice == "Adam"
    assert args.rate == 300
    assert say.parse_args(["hello"]).rate is None


def test_resolve_voice_id_id_shape_skips_api() -> None:
    """A voice-id-shaped value is returned verbatim without touching the API.

    Guards the synthesis-only-key path: resolving the default voice (an id) must
    not call ``voices.search``, which needs the ``voices_read`` permission a
    TTS-only key lacks. Accessing ``.voices`` on the sentinel would raise.
    """

    class Boom:
        def __getattr__(self, name: str) -> object:
            raise AssertionError(f"client.{name} must not be used for an id")

    # resolve_voice_id is typed for an ElevenLabs client; Boom stands in for one
    # and asserts the id path never touches it, so cast it to the expected type.
    boom = cast(ElevenLabs, Boom())
    assert say.resolve_voice_id(boom, "JBFqnCBsd6RMkjVDRZzb") == "JBFqnCBsd6RMkjVDRZzb"


def test_resolve_voice_id_name_searches_and_maps() -> None:
    """A friendly name is matched case-insensitively to its id via the search."""

    class FakeVoices:
        def search(self, search: str) -> object:
            assert search == "George"
            voice = type("V", (), {"name": "George", "voice_id": "ID0000000000000000aa"})()
            return type("R", (), {"voices": [voice]})()

    client = type("C", (), {"voices": FakeVoices()})()
    assert say.resolve_voice_id(client, "George") == "ID0000000000000000aa"


def test_resolve_voice_id_missing_permission_is_actionable() -> None:
    """401 and 403 while resolving a name both raise a SayError naming voices_read."""

    for status in (401, 403):

        class FakeVoices:
            def search(self, search: str) -> object:
                raise ApiError(status_code=status, body={"detail": "nope"})

        client = type("C", (), {"voices": FakeVoices()})()
        try:
            say.resolve_voice_id(client, "George")
        except say.SayError as exc:
            assert "voices_read" in str(exc), (status, exc)
        else:
            raise AssertionError(f"expected SayError for {status} during resolution")


def test_resolve_voice_id_other_api_error_falls_through() -> None:
    """A non-permission ApiError (e.g. 500) keeps the generic status message.

    Pins the ``in (401, 403)`` branch: an unrelated failure must not be relabeled
    as a permissions problem.
    """

    class FakeVoices:
        def search(self, search: str) -> object:
            raise ApiError(status_code=500, body={"detail": "boom"})

    client = type("C", (), {"voices": FakeVoices()})()
    try:
        say.resolve_voice_id(client, "George")
    except say.SayError as exc:
        assert "status 500" in str(exc), exc
        assert "voices_read" not in str(exc), exc
    else:
        raise AssertionError("expected SayError for a 500 during name resolution")


if __name__ == "__main__":
    test_stdin_yields_before_eof_and_rejoins_split_utf8()
    test_write_stream_writes_chunks_and_rejects_empty()
    test_play_stream_rejects_empty_without_spawning_ffplay()
    test_stream_client_narrows_to_realtime()
    test_should_stream_auto_and_overrides()
    test_stream_init_does_not_crash_on_omit_voice_settings()
    test_atempo_filter_maps_wpm_to_in_range_stages()
    test_say_compat_flags_parse()
    test_resolve_voice_id_id_shape_skips_api()
    test_resolve_voice_id_name_searches_and_maps()
    test_resolve_voice_id_missing_permission_is_actionable()
    test_resolve_voice_id_other_api_error_falls_through()
    print("elevenlabs-say streaming tests passed")
