#!/usr/bin/env python3
"""M2 scenario: from an empty inventory to assembler-made red science, no human input.

The harness only creates a fresh map, starts the play loop once, speeds the game up and
watches. It does not research, give items or place anything.

Pass when:
  - the science block is complete and its assembler has made red science, and
  - at least one technology finished after the block was complete (research running on
    assembler-made packs), and
  - no script errors.

Usage: scenario_m2.py [--seed N] [--max-game-hours H] [--speed S]
"""
import argparse
import json
import shutil
import sys
import time

from fai import FAI, Server, create_map, log


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=12345)
    ap.add_argument("--max-game-hours", type=float, default=4.0)
    ap.add_argument("--speed", type=float, default=16)
    ap.add_argument("--poll", type=float, default=20, help="real seconds between status checks")
    args = ap.parse_args()

    gen = json.loads((FAI / "map-gen.json").read_text())
    gen["seed"] = args.seed
    gen_path = FAI / f"map-gen-{args.seed}.json"
    gen_path.write_text(json.dumps(gen))
    save = FAI / "saves" / f"m2_{args.seed}.zip"
    if not create_map(save, gen_path):
        log("FAIL could not create map")
        return 1

    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        log(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")

    with Server(save, FAI / f"m2_{args.seed}_server.log") as srv:
        start = srv.remote("play_start", "{fresh=true}")
        check("play loop started", bool(start.get("ok")), str(start))
        first = srv.remote("play_status")
        check("AI starts with an empty inventory", first.get("start_items") == 0,
              f"{first.get('start_items')} items when the loop started")
        srv.lua(f"game.speed = {args.speed}")

        t_real0 = time.time()
        last_phase, last_log_len = None, 0
        st = {}
        max_ticks = int(args.max_game_hours * 3600 * 60)
        while True:
            time.sleep(args.poll)
            st = srv.remote("play_status")
            phase = st.get("phase")
            mins = st.get("game_minutes", 0)
            if phase != last_phase:
                log(f"{mins:6.1f} game min  phase -> {phase}")
                last_phase = phase
            else:
                log(f"{mins:6.1f} game min  {phase} | waiting: {str(st.get('waiting'))[:140]} | "
                    f"drills {st.get('drills')} | errors {st.get('stats', {}).get('errors')}")
            if st.get("block_done") and st.get("researched_after_block"):
                break
            if mins * 3600 >= max_ticks:
                log("time limit reached")
                break
        real = time.time() - t_real0

        srv.lua("game.speed = 1")
        dbg = srv.remote("play_debug")
        lines = dbg.get("log") or []
        errs = {}
        for l in lines:
            if "error:" in l:
                k = l.split("error:", 1)[1].strip()[:160]
                errs[k] = errs.get(k, 0) + 1
        if errs:
            print("---- distinct errors ----\n" + "\n".join(f"{n}x {k}" for k, n in errs.items()))
        print("---- play log (last 25) ----\n" + "\n".join(lines[-25:]))
        print("---- action trace (last 30) ----\n" + "\n".join((dbg.get("trace") or [])[-30:]))
        print(f"inventory: {dbg.get('inventory')}\ncrafting: {dbg.get('crafting')}\nlast rule: {dbg.get('last_rule')}")
        print("-----------------------------")

        check("science block complete", bool(st.get("block_done")), f"{st.get('block_parts')} parts")
        check("assembler made red science", st.get("red_science_from_assembler", 0) > 0,
              f"{st.get('red_science_from_assembler')} packs")
        check("research finished on assembler-made packs", bool(st.get("researched_after_block")),
              ", ".join(st.get("researched_after_block") or []))
        errors = st.get("stats", {}).get("errors", -1)
        check("no play loop errors", errors == 0, f"{errors} errors")
        log(f"game time {st.get('game_minutes', 0):.1f} min, real time {real / 60:.1f} min, stats {st.get('stats')}")
        log(f"phases: {[(p['phase'], round(p['tick'] / 3600, 1)) for p in st.get('phases', [])]}")

        srv.cmd("/server-save")
        time.sleep(3)
        bad = srv.errors_in_log()
        check("no errors in server log", not bad, bad[0] if bad else "")

    ck = FAI / "ai-player" / "checkpoints"
    ck.mkdir(exist_ok=True)
    shutil.copy(save, ck / f"m2_seed{args.seed}.zip")
    (ck / f"m2_seed{args.seed}_status.json").write_text(json.dumps(st, indent=1))
    log(f"checkpoint saved: {ck / f'm2_seed{args.seed}.zip'}")

    failed = [r for r in results if not r[1]]
    log(f"RESULT: {'PASS' if not failed else 'FAIL'} ({len(results) - len(failed)}/{len(results)} checks)")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
