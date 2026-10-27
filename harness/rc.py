#!/usr/bin/env python3
"""Tiny RCON helper for the test server.

Usage:
  rc.py '/sc rcon.print(game.tick)'      run one command, print the reply
  rc.py --lua 'rcon.print(game.tick)'    same, wraps in /sc
"""
import sys
import time

import factorio_rcon

HOST, PORT, PASSWORD = "127.0.0.1", 27015, "fai-local"


def connect(retries: int = 30, delay: float = 1.0):
    last = None
    for _ in range(retries):
        try:
            return factorio_rcon.RCONClient(HOST, PORT, PASSWORD)
        except Exception as e:  # server still starting
            last = e
            time.sleep(delay)
    raise SystemExit(f"RCON connect failed: {last}")


def run(cmd: str) -> str:
    client = connect()
    try:
        return client.send_command(cmd) or ""
    finally:
        client.close()


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    if args[0] == "--lua":
        cmd = "/sc " + " ".join(args[1:])
    else:
        cmd = " ".join(args)
    print(run(cmd))
