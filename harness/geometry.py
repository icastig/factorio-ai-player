#!/usr/bin/env python3
"""Measure placement geometry in the real game (dev tool, not a test).

Builds things on a scratch surface and prints what Factorio reports, so the play
loop uses measured offsets instead of remembered ones.
"""
import json

from fai import FAI, Server, create_map

LAB = """
local s = game.surfaces['geo'] or game.create_surface('geo', {width = 200, height = 200, default_enable_all_autoplace_controls = false,
  autoplace_settings = {entity = {treat_missing_as_default = false, settings = {}}, decorative = {treat_missing_as_default = false, settings = {}}}})
s.request_to_generate_chunks({0, 0}, 3); s.force_generate_chunk_requests()
local t = {}
for x = -60, 60 do for y = -60, 60 do t[#t+1] = {name = (x < 0) and 'water' or 'grass-1', position = {x, y}} end end
s.set_tiles(t)
for _, e in pairs(s.find_entities()) do e.destroy() end
return s
"""

DIRS = {"north": 0, "east": 4, "south": 8, "west": 12}


def main():
    save = FAI / "saves" / "geo.zip"
    assert create_map(save)
    with Server(save, FAI / "geo.log") as srv:
        srv.lua("local function mk() " + LAB + " end; mk(); rcon.print('ok')")

        # 1. Offshore pump on the shoreline (x = -1 is water, x = 0 land), facing each way.
        out = srv.lua("""
local s = game.surfaces['geo']; local res = {}
for dname, d in pairs({north=0, east=4, south=8, west=12}) do
  for x = -3, 2 do
    local p = {x + 0.5, 0.5}
    if s.can_place_entity{name='offshore-pump', position=p, direction=d, force='player', build_check_type=defines.build_check_type.manual} then
      local e = s.create_entity{name='offshore-pump', position=p, direction=d, force='player'}
      local okc, c = pcall(function() return e.get_fluid_box_pipe_connections(1) end)
      local cs = {}
      if okc then for _, cc in pairs(c) do cs[#cs+1] = string.format('target=%.1f,%.1f type=%s', cc.target_position.x, cc.target_position.y, tostring(cc.connection_type)) end else cs[1] = 'err ' .. tostring(c) end
      res[#res+1] = string.format('pump dir=%s at %.1f,%.1f -> %s', dname, e.position.x, e.position.y, table.concat(cs, ';'))
      e.destroy()
    end
  end
end
rcon.print(table.concat(res, '\\n'))""")
        print("== offshore pump placements ==\n" + out)

        # 2. Pump facing east at its first legal spot; search boiler then engine positions that connect.
        out = srv.lua("""
local function connected(a, b)
  local ok, nb = pcall(function() return a.fluidbox_neighbours end)
  if not ok or not nb then return false end
  for _, v in pairs(nb) do
    if v == b then return true end
    if type(v) == 'table' then for _, w in pairs(v) do if w == b then return true end end end
  end
  return false
end
local s = game.surfaces['geo']
local function legal(name, p, d) return s.can_place_entity{name=name, position=p, direction=d, force='player', build_check_type=defines.build_check_type.manual} end
local res = {}
for dname, d in pairs({north=0, east=4, south=8, west=12}) do
  for _, e in pairs(s.find_entities()) do e.destroy() end
  local pump
  for x = -3, 2 do for y = -2, 2 do
    local p = {x + 0.5, y + 0.5}
    if not pump and legal('offshore-pump', p, d) then pump = s.create_entity{name='offshore-pump', position=p, direction=d, force='player'} end
  end end
  if pump then
    local boiler
    for bx = -6, 6 do for by = -6, 6 do for bdn, bd in pairs({north=0, east=4, south=8, west=12}) do
      if not boiler then
        local p = {pump.position.x + bx, pump.position.y + by}
        if legal('boiler', p, bd) then
          local b = s.create_entity{name='boiler', position=p, direction=bd, force='player'}
          local ok = connected(b, pump) or connected(pump, b)
          if ok then boiler = b; res[#res+1] = string.format('pump %s at %.1f,%.1f | boiler dir=%s offset=%.1f,%.1f', dname, pump.position.x, pump.position.y, bdn, b.position.x - pump.position.x, b.position.y - pump.position.y)
          else b.destroy() end
        end
      end
    end end end
    if boiler then
      local engine
      for ex = -8, 8 do for ey = -8, 8 do for edn, ed in pairs({north=0, east=4, south=8, west=12}) do
        if not engine then
          local p = {boiler.position.x + ex, boiler.position.y + ey}
          if legal('steam-engine', p, ed) then
            local g = s.create_entity{name='steam-engine', position=p, direction=ed, force='player'}
            local ok = connected(g, boiler) or connected(boiler, g)
            if ok then engine = g; res[#res+1] = string.format('   engine dir=%s offset_from_pump=%.1f,%.1f', edn, g.position.x - pump.position.x, g.position.y - pump.position.y)
            else g.destroy() end
          end
        end
      end end end
    end
  end
end
rcon.print(table.concat(res, '\\n'))""")
        print("== pump -> boiler -> engine ==\n" + out)

        # 3. Burner drill drop position per direction, and inserter pickup/drop per direction.
        out = srv.lua("""
local s = game.surfaces['geo']; for _, e in pairs(s.find_entities()) do e.destroy() end
local res = {}
local function get(obj, key, ...)
  local args = {...}
  local ok, v = pcall(function() local x = obj[key]; if type(x) == 'function' then return x(table.unpack(args)) end; return x end)
  return ok and v or nil
end
for dname, d in pairs({north=0, east=4, south=8, west=12}) do
  local e = s.create_entity{name='burner-mining-drill', position={20, 20}, direction=d, force='player'}
  res[#res+1] = string.format('burner drill %s at %.1f,%.1f drop=%.2f,%.2f', dname, e.position.x, e.position.y, e.drop_position.x, e.drop_position.y)
  e.destroy()
  local i = s.create_entity{name='inserter', position={20.5, 20.5}, direction=d, force='player'}
  res[#res+1] = string.format('inserter %s pickup=%.2f,%.2f drop=%.2f,%.2f (at %.1f,%.1f)', dname, i.pickup_position.x, i.pickup_position.y, i.drop_position.x, i.drop_position.y, i.position.x, i.position.y)
  i.destroy()
end
for _, n in pairs({'stone-furnace', 'assembling-machine-1', 'lab', 'wooden-chest', 'small-electric-pole', 'offshore-pump', 'boiler', 'steam-engine', 'burner-mining-drill'}) do
  local p = prototypes.entity[n]; local b = p.collision_box
  res[#res+1] = string.format('%s box=%.1f,%.1f..%.1f,%.1f supply=%s wire=%s', n, b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y,
    tostring(get(p, 'get_supply_area_distance')), tostring(get(p, 'get_max_wire_distance')))
end
local proto = prototypes.entity['character']
res[#res+1] = string.format('character: mining_speed=%s reach=%s build=%s running_speed=%s', tostring(get(proto, 'mining_speed')), tostring(get(proto, 'reach_distance')), tostring(get(proto, 'build_distance')), tostring(get(proto, 'running_speed')))
for _, n in pairs({'iron-ore', 'copper-ore', 'coal', 'stone', 'huge-rock', 'big-rock', 'tree-01'}) do
  local p = prototypes.entity[n]
  if p and p.mineable_properties then
    local prods = {}; for _, pr in pairs(p.mineable_properties.products or {}) do prods[#prods+1] = (pr.name or '?') .. 'x' .. tostring(pr.amount or pr.amount_min or '?') .. (pr.amount_max and ('-' .. pr.amount_max) or '') end
    res[#res+1] = string.format('mine %s time=%s -> %s', n, tostring(p.mineable_properties.mining_time), table.concat(prods, ','))
  end
end
rcon.print(table.concat(res, '\\n'))""")
        print("== drills, inserters, sizes, character, mining ==\n" + out)

        # 4. Does begin_crafting make intermediates (gears) for a burner drill?
        out = srv.lua("""
local s = game.surfaces.nauvis
local c = s.create_entity{name='character', position={0, 0}, force='player'}
local inv = c.get_main_inventory(); inv.insert{name='iron-plate', count=9}; inv.insert{name='stone-furnace', count=1}
local n = c.begin_crafting{recipe='burner-mining-drill', count=1}
local q = {}; for _, it in pairs(c.crafting_queue or {}) do q[#q+1] = it.recipe .. 'x' .. it.count end
rcon.print('queued=' .. n .. ' queue=' .. table.concat(q, ',') .. ' plates_left=' .. inv.get_item_count('iron-plate'))
c.destroy()""")
        print("== crafting intermediates ==\n" + out)


if __name__ == "__main__":
    main()
