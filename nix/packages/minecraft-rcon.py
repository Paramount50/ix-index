#!/usr/bin/env python3
import argparse
import socket
import struct
import sys


AUTH = 3
COMMAND = 2


def packet(request_id: int, kind: int, payload: str) -> bytes:
    body = struct.pack("<ii", request_id, kind) + payload.encode("utf-8") + b"\0\0"
    return struct.pack("<i", len(body)) + body


def read_packet(sock: socket.socket) -> tuple[int, int, str]:
    header = sock.recv(4)
    if len(header) != 4:
        raise RuntimeError("short RCON length header")
    (length,) = struct.unpack("<i", header)
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            raise RuntimeError("RCON connection closed")
        body += chunk
    request_id, kind = struct.unpack("<ii", body[:8])
    payload = body[8:-2].decode("utf-8", errors="replace")
    return request_id, kind, payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Minimal Minecraft RCON client")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    password = parser.add_mutually_exclusive_group(required=True)
    password.add_argument("--password")
    password.add_argument("--password-file")
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()

    if args.password_file:
        with open(args.password_file, encoding="utf-8") as password_file:
            args.password = password_file.readline().rstrip("\n")

    command = " ".join(args.command)
    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        sock.sendall(packet(1, AUTH, args.password))
        auth_id, _, auth_payload = read_packet(sock)
        if auth_id == -1:
            print("RCON authentication failed", file=sys.stderr)
            return 1
        if auth_payload:
            print(auth_payload)

        sock.sendall(packet(2, COMMAND, command))
        _, _, output = read_packet(sock)
        if output:
            print(output)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
