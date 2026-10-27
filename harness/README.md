# Test harness

Runs the forked AI Player mod on a Factorio 2.1 headless server, without an LLM.

Layout expected on the machine (see the project plan, M0):

    ~/fai/factorio/          headless server 2.1.x, mods/ai-player-v3 -> ../../ai-player/mod
    ~/fai/ai-player/         this repo
    ~/fai/map-gen.json       -> harness/config/map-gen.json (enemies off, seed 12345)
    ~/fai/server-settings.json -> harness/config/server-settings.json (auto_pause off, not public)

Files:

- `smoke_m0.py`  fresh map, start server, spawn AI, run one skill, check results, shut down. Exit 0 = pass.
- `rc.py`        one-off RCON commands: `python3 rc.py --lua 'rcon.print(game.tick)'`
- `start-server.sh`  start the server on a given save with RCON on port 27015.

Note: the first Lua command on a save only triggers Factorio's "achievements will be disabled"
warning; it must be sent twice. The smoke test does this.
