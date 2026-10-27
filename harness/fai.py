"""Shared helpers for harness scripts: create a map, run the server, talk Lua over RCON."""
import json
import subprocess
import time
from pathlib import Path

import factorio_rcon

FAI = Path.home() / "fai"
FACTORIO = FAI / "factorio" / "bin" / "x64" / "factorio"
RCON = ("127.0.0.1", 27015, "fai-local")


def log(msg):
    print(f"[fai] {msg}", flush=True)


def create_map(save: Path, map_gen: Path = FAI / "map-gen.json") -> bool:
    save.unlink(missing_ok=True)
    subprocess.run([str(FACTORIO), "--create", str(save), "--map-gen-settings", str(map_gen)],
                   capture_output=True, text=True, timeout=300)
    return save.exists()


class Server:
    """A headless server on one save, with an RCON client. Use as a context manager."""

    def __init__(self, save: Path, log_path: Path):
        self.save, self.log_path = save, log_path
        self.proc = None
        self.client = None

    def __enter__(self):
        self._log = open(self.log_path, "w")
        self.proc = subprocess.Popen(
            [str(FACTORIO), "--start-server", str(self.save),
             "--server-settings", str(FAI / "server-settings.json"),
             "--rcon-port", str(RCON[1]), "--rcon-password", RCON[2], "--port", "34197"],
            stdout=self._log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        for _ in range(90):
            try:
                self.client = factorio_rcon.RCONClient(*RCON)
                break
            except Exception:
                time.sleep(1)
        if self.client is None:
            raise RuntimeError("RCON did not come up")
        # First Lua command on a save only triggers the achievements warning.
        self.lua("rcon.print('confirm')")
        return self

    def __exit__(self, *exc):
        try:
            if self.client:
                self.client.send_command("/quit")
        except Exception:
            pass
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self._log.close()

    def cmd(self, command: str) -> str:
        return (self.client.send_command(command) or "").strip()

    def lua(self, code: str) -> str:
        return self.cmd("/sc " + code)

    def lua_json(self, expr: str):
        """Evaluate a Lua expression that yields a table; return it as Python data."""
        out = self.lua(f"rcon.print(helpers.table_to_json({expr}))")
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return {"ok": False, "detail": out}

    def remote(self, fn: str, params_lua: str = "{}"):
        return self.lua_json(f"remote.call('ai_player','{fn}',{params_lua})")

    def skill(self, name: str, params_lua: str = "{}"):
        return self.lua_json(f"remote.call('ai_player','run_skill','{name}',{params_lua})")

    def tick(self) -> int:
        return int(self.lua("rcon.print(game.tick)"))

    def errors_in_log(self):
        text = self.log_path.read_text(errors="replace")
        return [l for l in text.splitlines() if "Error" in l and "stdin" not in l]


def lua_str(s: str) -> str:
    """Quote a Python string as a Lua long-bracket string literal."""
    eq = "="
    while f"]{eq}]" in s:
        eq += "="
    return f"[{eq}[{s}]{eq}]"
