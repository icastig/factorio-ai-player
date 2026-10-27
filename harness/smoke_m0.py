#!/usr/bin/env python3
"""M0 smoke test: fresh map -> server -> spawn AI -> one skill -> check -> shut down.

Exit code 0 = PASS. No LLM involved (autonomy is switched off).
"""
import json
import subprocess
import sys
import time
from pathlib import Path

import factorio_rcon

FAI = Path.home() / "fai"
FACTORIO = FAI / "factorio" / "bin" / "x64" / "factorio"
SAVE = FAI / "saves" / "smoke_m0.zip"
LOG = FAI / "smoke_m0_server.log"
RCON = ("127.0.0.1", 27015, "fai-local")


def step(msg):
    print(f"[smoke] {msg}", flush=True)


def lua(client, code):
    """Run Lua via /sc and return what rcon.print wrote."""
    return (client.send_command("/sc " + code) or "").strip()


def main() -> int:
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        step(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")

    # 1. Fresh map
    SAVE.unlink(missing_ok=True)
    out = subprocess.run(
        [str(FACTORIO), "--create", str(SAVE), "--map-gen-settings", str(FAI / "map-gen.json")],
        capture_output=True, text=True, timeout=300)
    check("create fresh map", SAVE.exists(), out.stdout.strip().splitlines()[-1] if out.stdout else "")
    if not SAVE.exists():
        return 1

    # 2. Server with RCON
    log = open(LOG, "w")
    server = subprocess.Popen(
        [str(FACTORIO), "--start-server", str(SAVE),
         "--server-settings", str(FAI / "server-settings.json"),
         "--rcon-port", str(RCON[1]), "--rcon-password", RCON[2], "--port", "34197"],
        stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    try:
        client = None
        for _ in range(60):
            try:
                client = factorio_rcon.RCONClient(*RCON)
                break
            except Exception:
                time.sleep(1)
        check("RCON connects", client is not None)
        if client is None:
            return 1

        # The first Lua command on a save asks for confirmation (achievements).
        lua(client, "rcon.print('confirm')")
        check("Lua runs", lua(client, "rcon.print('ok')") == "ok")

        version = lua(client, "rcon.print(script.active_mods['ai-player-v3'] or 'missing')")
        check("mod active", version != "missing", f"version {version}")

        t0 = int(lua(client, "rcon.print(game.tick)"))
        time.sleep(2)
        t1 = int(lua(client, "rcon.print(game.tick)"))
        check("game runs (not paused)", t1 > t0, f"tick {t0} -> {t1}")

        # 3. No LLM: switch off the autonomous loop, then spawn
        lua(client, "rcon.print(helpers.table_to_json(remote.call('ai_player','set_autonomy',false)))")
        client.send_command("/spawn-ai-player")
        state = lua(client, "rcon.print(helpers.table_to_json(remote.call('ai_player','query','get_character_state',{})))")
        check("AI character spawned", state.startswith("{") and "error" not in state[:40], state[:120])

        wood_lua = ("local c = nil; for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{name='character'}) do "
                    "if not e.player then c = e end end; "
                    "rcon.print(c and c.get_main_inventory().get_item_count('wood') or -1)")
        wood_before = int(lua(client, wood_lua))

        # 4. One skill: gather 10 more wood than the AI starts with
        res = lua(client, "rcon.print(helpers.table_to_json(remote.call('ai_player','run_skill','gather',{item='wood',count=%d})))" % (wood_before + 10))
        try:
            res_j = json.loads(res)
        except json.JSONDecodeError:
            res_j = {"ok": False, "detail": res}
        check("skill gather wood runs", bool(res_j.get("ok")), res_j.get("detail", ""))

        # 5. Verify the result in the game state itself, not just the skill's reply
        wood_after = int(lua(client, wood_lua))
        check("AI inventory gained 10+ wood", wood_after >= wood_before + 10, f"wood {wood_before} -> {wood_after}")

        # 6. The bridge's own RCON gateway works against 2.1 (no LLM needed)
        sys.path.insert(0, str(FAI / "ai-player"))
        from bridge.factorio.rcon import RCONGateway
        gw = RCONGateway(*RCON)
        check("bridge gateway connects", gw.connect())
        skills = gw.list_skills()
        check("bridge gateway lists skills", len(skills) == 11, f"{len(skills)} skills")
        state = gw.get_factory_state()
        check("bridge gateway reads factory state", isinstance(state, dict) and "error" not in state,
              str(state)[:100])
        gw.disconnect()

        client.send_command("/quit")
    finally:
        try:
            server.wait(timeout=30)
        except subprocess.TimeoutExpired:
            server.kill()
        log.close()

    # 6. No script errors in the server log
    text = LOG.read_text(errors="replace")
    bad = [l for l in text.splitlines() if "Error" in l and "stdin" not in l]
    check("no errors in server log", not bad, bad[0] if bad else "")

    failed = [r for r in results if not r[1]]
    step(f"RESULT: {'PASS' if not failed else 'FAIL'} ({len(results) - len(failed)}/{len(results)} checks)")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
