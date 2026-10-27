#!/usr/bin/env python3
"""M1 scenario: the AI places and builds an optimizer-designed block, and it produces.

Steps: fresh map -> spawn AI -> research the block's tech -> find a site -> place the
blueprint as ghosts (shift-click rules) -> hand the AI exactly the items the blueprint
needs (harness shortcut for M1) -> AI clears trees and builds the ghosts -> harness adds a
power source -> run game time -> compare science output with the plan -> save checkpoint.

Usage: scenario_m1.py <design dir>   (folder with best_output_string.txt and plan.json)
Exit code 0 = PASS.
"""
import json
import shutil
import sys
import time
from pathlib import Path

from fai import FAI, Server, create_map, log, lua_str

TECHS = ["automation-science-pack", "automation", "automation-2", "logistics", "logistics-2", "logistic-science-pack",
         "fast-inserter", "electronics", "steel-processing", "electric-energy-distribution-1"]
WARMUP_S = 300          # game seconds before measuring (deep chains like green science fill slowly)
MEASURE_S = 600         # game seconds measured
GAME_SPEED = 6
MIN_RATIO = 0.9         # output must reach 90% of the planned rate


def main() -> int:
    design = Path(sys.argv[1] if len(sys.argv) > 1 else FAI / "designs" / "m1_red_green")
    bp = (design / "best_output_string.txt").read_text().strip()
    targets = {t["name"]: t["amount"] for t in
               json.loads((FAI / "ai-player" / "jobs" / "m1_red_green.json").read_text())["targets"]}
    save = FAI / "saves" / "m1.zip"
    results = []

    def check(name, ok, detail=""):
        results.append((name, ok, detail))
        log(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
        return ok

    if not check("create fresh map", create_map(save)):
        return 1

    with Server(save, FAI / "m1_server.log") as srv:
        srv.remote("set_autonomy", "false")
        srv.cmd("/spawn-ai-player")
        me = srv.lua_json("remote.call('ai_player','query','get_character_state',{})")
        pos = me.get("position", {"x": 0, "y": 0})
        check("AI spawned", "position" in me, str(pos))

        # Research what the block uses (harness shortcut: M1 tests building, not research).
        techs = "{" + ",".join(f"'{t}'" for t in TECHS) + "}"
        missing = srv.lua("local f = game.forces.player; local miss = {}; for _, t in pairs(" + techs + ") do "
                          "local tech = f.technologies[t]; if tech then tech.researched = true else miss[#miss+1] = t end end; "
                          "rcon.print(table.concat(miss, ','))")
        check("block technologies researched", missing == "", f"unknown: {missing}" if missing else "")

        cost = srv.remote("blueprint_cost", "{blueprint=" + lua_str(bp) + "}")
        items = cost.get("items", {})
        check("blueprint cost computed", bool(items), ", ".join(f"{v} {k}" for k, v in sorted(items.items())))

        site = srv.remote("find_site", "{blueprint=" + lua_str(bp) + f", near={{x={pos['x']},y={pos['y']}}}, margin=3}}")
        if not check("site found", bool(site.get("ok")),
                     f"at {site.get('position')} size {site.get('size')}, {site.get('trees_and_rocks')} trees/rocks, "
                     f"{site.get('checked')} candidates" if site.get("ok") else site.get("detail", "")):
            return 1
        sx, sy = site["position"]["x"], site["position"]["y"]

        placed = srv.remote("import_blueprint", "{blueprint=" + lua_str(bp) + f", x={sx}, y={sy}}}")
        check("ghosts placed with shift-click rules", placed.get("ghosts") == placed.get("expected"),
              f"{placed.get('detail')}, {placed.get('marked_for_deconstruction')} marked for deconstruction")
        pa, sa = placed.get("area") or {}, site["area"]
        inside = bool(pa) and (pa["left_top"]["x"] >= sa["left_top"]["x"] and pa["left_top"]["y"] >= sa["left_top"]["y"]
                               and pa["right_bottom"]["x"] <= sa["right_bottom"]["x"]
                               and pa["right_bottom"]["y"] <= sa["right_bottom"]["y"])
        check("ghosts landed inside the checked site", inside, f"ghosts {pa} site {sa}")

        # Harness shortcut: give the AI exactly what the blueprint needs.
        give = ";".join(f"inv.insert{{name='{k}', count={v}}}" for k, v in items.items())
        srv.lua("local c; for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{name='character'}) do "
                "if not e.player then c = e end end; local inv = c.get_main_inventory(); " + give)

        if placed.get("marked_for_deconstruction", 0) > 0:
            d = srv.skill("deconstruct", "{radius=400}")
            check("AI clears trees and rocks", bool(d.get("ok")), d.get("detail", ""))

        built_total = 0
        for attempt in range(5):
            b = srv.skill("build_ghosts")
            left = int(srv.lua("rcon.print(game.surfaces.nauvis.count_entities_filtered{type='entity-ghost'})"))
            log(f"build_ghosts #{attempt + 1}: {b.get('detail')} ({left} ghosts left)")
            if left == 0:
                break
        check("AI built every ghost", left == 0, f"{left} ghosts left")

        a = placed.get("area") or site["area"]
        area = (f"{{{{{a['left_top']['x']},{a['left_top']['y']}}},"
                f"{{{a['right_bottom']['x']},{a['right_bottom']['y']}}}}}")
        n_built = int(srv.lua(f"local s = game.surfaces.nauvis; "
                              f"rcon.print(s.count_entities_filtered{{area={area}, force='player'}} - "
                              f"s.count_entities_filtered{{area={area}, force='player', type={{'character','entity-ghost'}}}})"))
        expected = sum(items.values())
        check("entity count matches blueprint", n_built == expected, f"{n_built} of {expected}")

        # Harness shortcut: a power source inside the reach of one of the block's poles.
        power = srv.lua(
            f"local s = game.surfaces.nauvis; "
            f"for _, pole in pairs(s.find_entities_filtered{{area={area}, type='electric-pole'}}) do "
            f"  for dx = -3, 3 do for dy = -3, 3 do "
            f"    local p = {{pole.position.x + dx, pole.position.y + dy}}; "
            f"    if s.can_place_entity{{name='electric-energy-interface', position=p, force='player'}} then "
            f"      local e = s.create_entity{{name='electric-energy-interface', position=p, force='player'}}; "
            f"      e.power_production = 1e9; e.electric_buffer_size = 1e9; "
            f"      rcon.print('eei at ' .. p[1] .. ',' .. p[2]); return end end end end "
            f"rcon.print('none')")
        check("harness power source placed", power.startswith("eei"), power)

        # Run the block.
        srv.lua(f"game.speed = {GAME_SPEED}")
        stat = ("local st = game.forces.player.get_item_production_statistics('nauvis'); "
                "rcon.print(helpers.table_to_json({" +
                ",".join(f"['{t}']=st.get_input_count('{t}')" for t in targets) + "}))")

        def wait_game(seconds):
            t_end = srv.tick() + seconds * 60
            while srv.tick() < t_end:
                time.sleep(1)

        wait_game(WARMUP_S)
        c0, t0 = json.loads(srv.lua(stat)), srv.tick()
        wall0 = time.time()
        wait_game(MEASURE_S)
        c1, t1 = json.loads(srv.lua(stat)), srv.tick()
        secs = (t1 - t0) / 60
        log(f"measured {secs:.0f} game s in {time.time() - wall0:.0f} real s")
        for name, rate in targets.items():
            got = (c1.get(name, 0) - c0.get(name, 0)) / secs
            check(f"{name} rate", got >= rate * MIN_RATIO, f"{got:.3f}/s of planned {rate}/s ({got / rate:.0%})")

        idle = srv.lua("local n = 0; for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{"
                       f"area={area}, type='assembling-machine'}}) do "
                       "if e.status ~= defines.entity_status.working then n = n + 1 end end; rcon.print(n)")
        log(f"assemblers not working at the end: {idle}")

        srv.lua("game.speed = 1")
        srv.cmd("/server-save")
        time.sleep(3)
        check("no errors in server log", not srv.errors_in_log(), (srv.errors_in_log() or [""])[0])

    ck = FAI / "ai-player" / "checkpoints"
    ck.mkdir(exist_ok=True)
    shutil.copy(save, ck / "m1_red_green.zip")
    log(f"checkpoint saved: {ck / 'm1_red_green.zip'}")

    failed = [r for r in results if not r[1]]
    log(f"RESULT: {'PASS' if not failed else 'FAIL'} ({len(results) - len(failed)}/{len(results)} checks)")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
