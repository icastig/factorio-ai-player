# Test harness

Runs the forked AI Player mod on a Factorio 2.1 headless server, without an LLM.

Layout expected on the machine (see the project plan, M0):

    ~/fai/factorio/          headless server 2.1.21 (pinned to match the Mac game, so checkpoint saves open there), mods/ai-player-v3 -> ../../ai-player/mod
    ~/fai/ai-player/         this repo
    ~/fai/map-gen.json       -> harness/config/map-gen.json (enemies off, seed 12345)
    ~/fai/server-settings.json -> harness/config/server-settings.json (auto_pause off, not public)

Files:

- `smoke_m0.py`  fresh map, start server, spawn AI, run one skill, check results, shut down. Exit 0 = pass.
- `rc.py`        one-off RCON commands: `python3 rc.py --lua 'rcon.print(game.tick)'`
- `start-server.sh`  start the server on a given save with RCON on port 27015.

Note: the first Lua command on a save only triggers Factorio's "achievements will be disabled"
warning; it must be sent twice. The smoke test does this.
- `scenario_m1.py <design dir>`  M1: the AI finds a site, places an optimizer blueprint as ghosts with
  shift-click rules, clears trees, builds it; the harness adds research, the items and a power source,
  then measures science output against the plan and saves `checkpoints/m1_red_green.zip`.
- `fai.py`  shared helpers (map creation, server context manager, Lua over RCON).
- `scenario_m2.py [--seed N]`  M2: fresh map, `play_start{fresh=true}` once, then only watching. Passes when the
  science block is complete, its assembler made red science and a technology finished after that, with no errors.
  Writes `checkpoints/m2_seed<N>.zip` and `m2_seed<N>_status.json`.
- `geometry.py`  dev tool: measures placement geometry (drill output, pump/boiler/engine, inserter sides) in the game.

The play loop itself is `mod/scripts/play.lua`. In a game: `/ai-play` starts it with a new AI that has an empty
inventory, `/ai-play status` prints the phase, `/ai-play stop` stops it. Progress goes to chat, to a map marker,
and to `script-output/ai-player/play-status.json` and `play-log.txt`.
