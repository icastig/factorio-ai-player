-- play.lua — M2 play loop: from an empty inventory to assembler-made red science.
--
-- Started with /ai-play (or remote.call('ai_player', 'play_start', {...})).
-- Runs on a timer inside the mod, so a headless test and a watched game on a
-- player's PC run exactly the same code.
--
-- Fairness: every action waits about as long as a player would take.
--   walking   distance / 0.15 tiles per tick (character running speed, measured)
--   mining    mining_time / 0.5 per unit (character mining speed, measured)
--   crafting  the real crafting queue (begin_crafting)
-- Shortcuts that remain (reported in the status file): the character teleports
-- instead of walking (but waits the walking time), and mines a batch of units
-- in one call (but waits the full mining time).
--
-- Geometry below was measured in Factorio 2.1.21 with harness/geometry.py.

local AIPlay = {}

local NTH = 7                       -- loop resolution in ticks
local RUN_TPT = 0.15                -- character running speed, tiles per tick
local MINING_SPEED = 0.5            -- character mining speed
local REACH = 8                     -- act from within this distance (reach is 10)
local PLACE_TICKS = 20
local MOVE_ITEMS_TICKS = 15
local DIRS = {0, 4, 8, 12}          -- north, east, south, west
local DIR_VEC = {[0] = {0, -1}, [4] = {1, 0}, [8] = {0, 1}, [12] = {-1, 0}}

-- Burner drill (2x2 at integer position P): where its output goes per direction.
local DROP_FURNACE = {[0] = {0, -2}, [4] = {2, 0}, [8] = {0, 2}, [12] = {-2, 0}}
local DROP_CHEST = {[0] = {-0.5, -1.5}, [4] = {1.5, -0.5}, [8] = {0.5, 1.5}, [12] = {-1.5, 0.5}}

-- Offshore pump on the land tile next to water, facing the water.
-- Offsets of boiler and engine from the pump, with their directions.
local POWER_LAYOUT = {
  [12] = {boiler = {2.0, -0.5, 0},   engine = {2.0, -4.0, 0}},    -- water to the west
  [4]  = {boiler = {-2.0, -0.5, 0},  engine = {-2.0, -4.0, 0}},   -- water to the east
  [0]  = {boiler = {-0.5, 2.0, 12},  engine = {-4.0, 2.0, 4}},    -- water to the north
  [8]  = {boiler = {-0.5, -2.0, 12}, engine = {-4.0, -2.0, 4}},   -- water to the south
}

-- Starter science block, relative to an integer origin O. Inserters face the
-- side they pick up from (measured). Bounds: x 0..13, y -3..2.
local BLOCK = {
  {name = "lab", x = 11.5, y = 0.5, role = "lab"},
  {name = "small-electric-pole", x = 9.5, y = -1.5, role = "pole3"},
  {name = "small-electric-pole", x = 5.5, y = -1.5, role = "pole2"},
  {name = "small-electric-pole", x = 1.5, y = -0.5, role = "pole1"},
  {name = "wooden-chest", x = 0.5, y = 0.5, role = "iron_chest"},
  {name = "inserter", x = 1.5, y = 0.5, dir = 12},
  {name = "assembling-machine-1", x = 3.5, y = 0.5, recipe = "iron-gear-wheel", role = "gear_asm"},
  {name = "inserter", x = 5.5, y = 0.5, dir = 12},
  {name = "assembling-machine-1", x = 7.5, y = 0.5, recipe = "automation-science-pack", role = "red_asm"},
  {name = "inserter", x = 9.5, y = 0.5, dir = 12},
  {name = "wooden-chest", x = 7.5, y = -2.5, role = "copper_chest"},
  {name = "inserter", x = 7.5, y = -1.5, dir = 0},
}
local BLOCK_BOX = {x1 = -1, y1 = -4, x2 = 14, y2 = 3}   -- footprint with a 1-tile margin

-- Build order. Each entry is a target; the first unmet one is worked on.
local DRILL_PLAN = {
  {ore = "iron-ore", out = "stone-furnace", count = 1},
  {ore = "coal", out = "wooden-chest", count = 1},
  {ore = "iron-ore", out = "stone-furnace", count = 2},
  {ore = "copper-ore", out = "stone-furnace", count = 1},
  {ore = "coal", out = "wooden-chest", count = 2},
  {ore = "stone", out = "wooden-chest", count = 1},
  {ore = "iron-ore", out = "stone-furnace", count = 4},
  {ore = "copper-ore", out = "stone-furnace", count = 2},
  {ore = "coal", out = "wooden-chest", count = 3},
  {ore = "iron-ore", out = "stone-furnace", count = 6},
  {ore = "copper-ore", out = "stone-furnace", count = 3},
  {ore = "coal", out = "wooden-chest", count = 4},
}

local RAW = {["iron-ore"] = true, ["copper-ore"] = true, coal = true, stone = true, wood = true}
local SMELT = {["iron-plate"] = "iron-ore", ["copper-plate"] = "copper-ore"}

-- -------------------------------------------------------------------------
-- State, logging, reporting
-- -------------------------------------------------------------------------

local function P() return storage.ai_player.play end

local function log(msg, chat)
  local p = P()
  local line = string.format("[%7.1f min] %s", (game.tick - (p.started or 0)) / 3600, msg)
  p.log[#p.log + 1] = line
  while #p.log > 300 do table.remove(p.log, 1) end
  pcall(helpers.write_file, "ai-player/play-log.txt", line .. "\n", true)
  if chat then game.print("[AI] " .. msg, {r = 0.6, g = 0.9, b = 1}) end
end

local function trace(msg)
  local p = P()
  p.trace[#p.trace + 1] = string.format("%d %s", game.tick - (p.started or 0), msg)
  while #p.trace > 60 do table.remove(p.trace, 1) end
end

local function set_phase(name)
  local p = P()
  if p.phase ~= name then
    p.phase = name
    p.phase_log[#p.phase_log + 1] = {phase = name, tick = game.tick}
    log("phase: " .. name, true)
  end
end

local function valid_list(list)
  local out = {}
  for _, e in ipairs(list or {}) do if e and e.valid then out[#out + 1] = e end end
  return out
end

local function inv(c) return c.get_main_inventory() end
local function have(c, item) return inv(c).get_item_count(item) end

local function dist(a, b)
  local dx, dy = (a.x or a[1]) - (b.x or b[1]), (a.y or a[2]) - (b.y or b[2])
  return math.sqrt(dx * dx + dy * dy)
end

local function pos(x, y) return {x = x, y = y} end

local FUEL = {  -- refuel below `low`, fill up to `fill`
  ["boiler"] = {low = 10, fill = 50},
  ["burner-mining-drill"] = {low = 4, fill = 25},
  ["stone-furnace"] = {low = 3, fill = 15},
}

local function fuel_of(e)
  local f = e.get_fuel_inventory()
  return f and f.get_item_count("coal") or 99
end

-- -------------------------------------------------------------------------
-- Basic actions. Each returns the number of ticks it takes.
-- -------------------------------------------------------------------------

-- Go within reach of `target` but at least `clear` tiles from it, so the
-- character never stands where something is about to be built. Waits the
-- walking time for the distance covered.
local function travel(c, target, clear)
  clear = clear or 1
  local from = {x = c.position.x, y = c.position.y}
  local d = dist(from, target)
  if d <= REACH and d >= clear then return 0 end
  local dx, dy = from.x - target.x, from.y - target.y
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.01 then dx, dy, len = 1, 0, 1 end
  local want = math.min(clear + 1.5, REACH - 1)
  local sides = {{dx / len, dy / len}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}}
  local spot
  for _, v in ipairs(sides) do
    local goal = {x = target.x + v[1] * want, y = target.y + v[2] * want}
    local q = c.surface.find_non_colliding_position("character", goal, 3, 0.5)
    if q and dist(q, target) >= clear and dist(q, target) <= REACH then spot = q; break end
  end
  if not spot then return 0 end
  c.teleport(spot)
  local moved = dist(from, spot)
  P().stats.walked = P().stats.walked + moved
  return math.ceil(moved / RUN_TPT)
end

local function clearance(name)
  local proto = prototypes.entity[name]
  local w, h = proto and proto.tile_width or 1, proto and proto.tile_height or 1
  return math.max(w, h) / 2 + 1.2
end

local function place(c, name, position, dir)
  local s = c.surface
  if have(c, name) < 1 then return nil, "no " .. name end
  local t = travel(c, position, clearance(name))
  if not s.can_place_entity{name = name, position = position, direction = dir or 0, force = c.force,
                            build_check_type = defines.build_check_type.manual} then
    return nil, string.format("cannot place %s at %.1f,%.1f", name, position.x, position.y)
  end
  local e = s.create_entity{name = name, position = position, direction = dir or 0, force = c.force}
  if not e then return nil, "create failed for " .. name end
  trace(string.format("place %s at %.1f,%.1f", name, position.x, position.y))
  inv(c).remove{name = name, count = 1}
  if AIRegistry and AIRegistry.add then pcall(AIRegistry.add, e) end
  P().stats.placed = P().stats.placed + 1
  return e, t + PLACE_TICKS
end

local function put(c, entity, inventory_id, item, count)
  local target = entity.get_inventory(inventory_id)
  if not target then return 0 end
  local n = math.min(count, have(c, item))
  if n <= 0 then return 0 end
  local t = travel(c, entity.position)
  local inserted = target.insert{name = item, count = n}
  if inserted > 0 then inv(c).remove{name = item, count = inserted} end
  trace(string.format("put %d/%d %s into %s", inserted, n, item, entity.name))
  return t + MOVE_ITEMS_TICKS, inserted
end

local function take(c, entity, inventory_id, item, count)
  local source = entity.get_inventory(inventory_id)
  if not source then return 0, 0 end
  local n = math.min(count or 1e9, source.get_item_count(item))
  if n <= 0 then return 0, 0 end
  local t = travel(c, entity.position)
  local got = inv(c).insert{name = item, count = n}
  if got > 0 then source.remove{name = item, count = got} end
  trace(string.format("take %d %s from %s", got, item, entity.name))
  return t + MOVE_ITEMS_TICKS, got
end

-- -------------------------------------------------------------------------
-- Finding things
-- -------------------------------------------------------------------------

-- Nearest position on the entity's grid where a player could place it.
-- Even-sized entities sit on integer coordinates, odd-sized ones on tile centres.
local function find_spot(c, name, near, radius, dir, avoid_ore)
  local proto = prototypes.entity[name]
  local w, h = proto.tile_width or 1, proto.tile_height or 1
  if dir == 4 or dir == 12 then w, h = h, w end
  local ox = (w % 2 == 0) and 0 or 0.5
  local oy = (h % 2 == 0) and 0 or 0.5
  local cx, cy = math.floor(near.x), math.floor(near.y)
  local s = c.surface
  for r = 0, radius do
    for dx = -r, r do
      for dy = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r then
          local q = {x = cx + dx + ox, y = cy + dy + oy}
          if s.can_place_entity{name = name, position = q, direction = dir or 0, force = c.force,
                                build_check_type = defines.build_check_type.manual} then
            local ok = true
            if avoid_ore then
              ok = s.count_entities_filtered{type = "resource", position = q, radius = math.max(w, h)} == 0
            end
            if ok then return q end
          end
        end
      end
    end
  end
  return nil
end

local ROCKS = nil
local function rock_names()
  if ROCKS then return ROCKS end
  ROCKS = {}
  for name, proto in pairs(prototypes.get_entity_filtered{{filter = "type", type = "simple-entity"}}) do
    local mp = proto.mineable_properties
    if mp and mp.minable then
      for _, pr in pairs(mp.products or {}) do
        if pr.name == "stone" then ROCKS[#ROCKS + 1] = name; break end
      end
    end
  end
  return ROCKS
end

local function nearest(list, from)
  local best, bd = nil, math.huge
  for _, e in ipairs(list) do
    if e.valid then
      local d = dist(e.position, from)
      if d < bd then best, bd = e, d end
    end
  end
  return best, bd
end

-- Nearest source to mine for a raw item: rocks for stone, trees for wood, ore otherwise.
local function find_mine_source(c, item)
  local s = c.surface
  for _, r in ipairs({24, 48, 96, 160}) do
    local found = {}
    if item == "wood" then
      found = s.find_entities_filtered{type = "tree", position = c.position, radius = r, limit = 50}
    else
      if item == "stone" then
        found = s.find_entities_filtered{name = rock_names(), position = c.position, radius = r, limit = 50}
      end
      if #found == 0 then
        found = s.find_entities_filtered{name = item, type = "resource", position = c.position, radius = r, limit = 400}
      end
    end
    if #found > 0 then return (nearest(found, c.position)) end
  end
  return nil
end

-- Remember where each ore patch is (nearest to home).
local function patch_anchor(c, ore)
  local p = P()
  if p.patches[ore] then return p.patches[ore] end
  for _, r in ipairs({48, 96, 160, 256}) do
    local found = c.surface.find_entities_filtered{name = ore, type = "resource", position = p.home, radius = r, limit = 2000}
    if #found > 0 then
      local e = nearest(found, p.home)
      p.patches[ore] = {x = e.position.x, y = e.position.y}
      log(string.format("found %s at %.0f,%.0f (%.0f tiles from home)", ore, e.position.x, e.position.y, dist(e.position, p.home)))
      return p.patches[ore]
    end
  end
  return nil
end

-- -------------------------------------------------------------------------
-- Mining by hand
-- -------------------------------------------------------------------------

local function mining_ticks(entity)
  local mp = entity.prototype.mineable_properties
  return math.ceil((mp and mp.mining_time or 1) / MINING_SPEED * 60)
end

local function act_mine(c, item, want)
  local src = find_mine_source(c, item)
  if not src then return nil, "nothing to mine for " .. item end
  local src_name = src.name
  local t = travel(c, src.position)
  local before = have(c, item)
  local per = mining_ticks(src)
  local units = (src.type == "resource") and math.min(math.max(want, 1), 10) or 1
  local spent = 0
  for _ = 1, units do
    if not src.valid then break end
    c.mine_entity(src, true)
    spent = spent + per
  end
  local got = have(c, item) - before
  P().stats.mined = P().stats.mined + math.max(got, 0)
  trace(string.format("mine %s from %s: +%d (now %d)", item, src_name, got, have(c, item)))
  return t + math.max(spent, 30)
end

-- -------------------------------------------------------------------------
-- Hand-crafting statistics
-- -------------------------------------------------------------------------
-- Factorio records a player's hand-crafting in the force's production
-- statistics, and "craft an item" research triggers read those statistics.
-- Crafting by a character with no player attached is not recorded (tested on
-- 2.1.21: the AI's lab never counted). This records finished crafts the same
-- way, so triggers such as "craft a lab" work for the AI.

local function queued_by_recipe(c)
  local out = {}
  for _, q in pairs(c.crafting_queue or {}) do out[q.recipe] = (out[q.recipe] or 0) + q.count end
  return out
end

local function sync_crafting(c)
  local p = P()
  local now = queued_by_recipe(c)
  local stats = c.force.get_item_production_statistics(c.surface)
  for recipe, before in pairs(p.craft_seen) do
    local done = before - (now[recipe] or 0)
    if done > 0 then
      local r = prototypes.recipe[recipe]
      if r then
        for _, pr in pairs(r.products) do
          if pr.type == "item" then stats.on_flow(pr.name, (pr.amount or 1) * done) end
        end
        for _, ing in pairs(r.ingredients) do
          if ing.type == "item" then stats.on_flow(ing.name, -(ing.amount * done)) end
        end
      end
    end
  end
  p.craft_seen = now
end

-- -------------------------------------------------------------------------
-- Getting items: take from our buildings, mine, smelt by hand, or craft
-- -------------------------------------------------------------------------

local function our_stock(item)
  -- Containers and furnace outputs that hold `item`, richest first.
  local p, out = P(), {}
  for _, e in ipairs(valid_list(p.chests)) do
    local n = e.get_inventory(defines.inventory.chest).get_item_count(item)
    if n > 0 then out[#out + 1] = {e = e, inv = defines.inventory.chest, n = n} end
  end
  for _, e in ipairs(valid_list(p.furnaces)) do
    local n = e.get_inventory(defines.inventory.crafter_output).get_item_count(item)
    if n > 0 then out[#out + 1] = {e = e, inv = defines.inventory.crafter_output, n = n} end
  end
  table.sort(out, function(a, b) return a.n > b.n end)
  return out
end

local function crafting(c, recipe)
  for _, q in pairs(c.crafting_queue or {}) do
    if q.recipe == recipe then return true end
  end
  return false
end

local function automated_supply(item)
  local p = P()
  if item == "iron-plate" then return #valid_list(p.drills["iron-ore"]) > 0 end
  if item == "copper-plate" then return #valid_list(p.drills["copper-ore"]) > 0 end
  if item == "coal" or item == "stone" then return #valid_list(p.drills[item]) > 0 end
  return false
end

local obtain  -- forward declaration

local function hand_furnace(c, plate)
  local p = P()
  local hf = p.hand_furnaces[plate]
  if hf and hf.valid then return hf end
  return nil
end

local function plan_hand_smelt(c, plate, want, depth)
  local p = P()
  local ore = SMELT[plate]
  local hf = hand_furnace(c, plate)
  if not hf then
    local a, why = obtain(c, "stone-furnace", 1, depth + 1)
    if a then return a end
    if have(c, "stone-furnace") < 1 then return nil, why end
    local anchor = patch_anchor(c, ore) or c.position
    local spot = find_spot(c, "stone-furnace", anchor, 16, 0, true) or find_spot(c, "stone-furnace", anchor, 16, 0, false)
    if not spot then return nil, "no spot for a hand furnace" end
    return function()
      local e, t = place(c, "stone-furnace", spot)
      if not e then log("hand furnace: " .. tostring(t)); return 60 end
      p.hand_furnaces[plate] = e
      p.furnaces[#p.furnaces + 1] = e
      log("placed a furnace for hand smelting " .. plate)
      return t
    end
  end
  -- fuel
  local fuel = hf.get_fuel_inventory()
  if fuel.get_item_count("coal") < 2 then
    if have(c, "coal") < 2 then return obtain(c, "coal", 5, depth + 1) end
    return function() return (put(c, hf, defines.inventory.fuel, "coal", 5)) end
  end
  -- ore
  local src = hf.get_inventory(defines.inventory.crafter_input)
  local loaded = src.get_item_count(ore)
  if loaded < math.min(want, 10) then
    if have(c, ore) >= math.min(want, 10) - loaded then
      return function() return (put(c, hf, defines.inventory.crafter_input, ore, math.min(want, 50))) end
    end
    return obtain(c, ore, math.min(want, 50) - loaded, depth + 1)
  end
  return nil, "smelting " .. plate .. " by hand"
end

-- Returns an action (function returning ticks), or nil plus a reason when the
-- item is on its way (being crafted or smelted) or cannot be had right now.
obtain = function(c, item, want, depth)
  depth = depth or 0
  if depth > 8 then return nil, "too deep resolving " .. item end
  local short = want - have(c, item)
  if short <= 0 then return nil end

  -- 1. take it from our own buildings
  local stock = our_stock(item)
  if #stock > 0 then
    local s = stock[1]
    return function() return (take(c, s.e, s.inv, item, short)) end
  end

  -- 2. raw: mine it (unless drills are producing it and we are not starving)
  if RAW[item] then
    return function() return act_mine(c, item, short) end
  end

  -- 3. plates: wait for drills, else smelt by hand
  if SMELT[item] then
    if automated_supply(item) then return nil, "waiting for " .. item .. " from drills" end
    return plan_hand_smelt(c, item, short, depth)
  end

  -- 4. craft by hand
  local recipe = c.force.recipes[item]
  if not recipe or not recipe.enabled then return nil, item .. " is not unlocked" end
  if crafting(c, item) then return nil, "crafting " .. item end
  local per = 1
  for _, pr in pairs(recipe.products) do if pr.name == item then per = pr.amount or 1 end end
  local crafts = math.ceil(short / per)
  if c.get_craftable_count(item) >= crafts then
    return function()
      local n = c.begin_crafting{recipe = item, count = crafts}
      P().craft_seen = queued_by_recipe(c)
      P().stats.crafted = P().stats.crafted + n
      trace(string.format("craft %d %s (queued %d)", crafts, item, n))
      return 10
    end
  end
  for _, ing in pairs(recipe.ingredients) do
    local a, why = obtain(c, ing.name, ing.amount * crafts, depth + 1)
    if a then return a end
    if have(c, ing.name) < ing.amount * crafts then return nil, why or ("need " .. ing.name) end
  end
  return nil, "waiting to craft " .. item
end

-- -------------------------------------------------------------------------
-- Burner drills
-- -------------------------------------------------------------------------

local function find_drill_spot(c, ore, out)
  local p = P()
  local s = c.surface
  local anchor = patch_anchor(c, ore)
  if not anchor then return nil, "no " .. ore .. " found" end
  -- cluster new drills next to the existing ones on this ore
  local existing = valid_list(p.drills[ore])
  local center = existing[#existing] and existing[#existing].position or anchor
  local tiles = s.find_entities_filtered{name = ore, type = "resource", position = center, radius = 14, limit = 600}
  table.sort(tiles, function(a, b) return dist(a.position, center) < dist(b.position, center) end)
  local checked = 0
  for _, t in ipairs(tiles) do
    local P0 = {x = math.floor(t.position.x) + 1, y = math.floor(t.position.y) + 1}
    local under = s.count_entities_filtered{name = ore, type = "resource",
      area = {{P0.x - 1, P0.y - 1}, {P0.x + 1, P0.y + 1}}}
    if under >= 3 then
      for _, d in ipairs(DIRS) do
        checked = checked + 1
        local off = (out == "stone-furnace") and DROP_FURNACE[d] or DROP_CHEST[d]
        local O = {x = P0.x + off[1], y = P0.y + off[2]}
        if s.can_place_entity{name = "burner-mining-drill", position = P0, direction = d, force = c.force,
                              build_check_type = defines.build_check_type.manual}
          and s.can_place_entity{name = out, position = O, force = c.force,
                                 build_check_type = defines.build_check_type.manual} then
          -- keep the output off the ore where possible, so it does not block later drills
          local on_ore = s.count_entities_filtered{type = "resource", area = {{O.x - 1, O.y - 1}, {O.x + 1, O.y + 1}}}
          if on_ore == 0 or checked > 120 then
            return {drill = P0, dir = d, out = O}
          end
        end
      end
    end
    if checked > 400 then break end
  end
  return nil, "no free drill spot on " .. ore
end

local function work_on_drill(c, target)
  local p = P()
  local have_drills = #valid_list(p.drills[target.ore])
  if have_drills >= target.count then return nil, "done" end
  -- items first
  local out_item = target.out
  if out_item == "wooden-chest" and not c.force.recipes["wooden-chest"].enabled then out_item = "iron-chest" end
  local a, why = obtain(c, "burner-mining-drill", 1)
  if a then return a end
  if have(c, "burner-mining-drill") < 1 then return nil, why end
  a, why = obtain(c, out_item, 1)
  if a then return a end
  if have(c, out_item) < 1 then return nil, why end
  if have(c, "coal") < 6 then
    a, why = obtain(c, "coal", 10)
    if a then return a end
    if have(c, "coal") < 6 then return nil, why end
  end
  local spot, why2 = find_drill_spot(c, target.ore, out_item)
  if not spot then return nil, why2 end
  return function()
    local d, t1 = place(c, "burner-mining-drill", spot.drill, spot.dir)
    if not d then log("drill placement failed: " .. tostring(t1)); return 60 end
    local o, t2 = place(c, out_item, spot.out)
    if not o then
      log("output placement failed: " .. tostring(t2) .. "; picking the drill back up")
      c.mine_entity(d, true)
      return t1 + 60
    end
    p.drills[target.ore] = p.drills[target.ore] or {}
    table.insert(p.drills[target.ore], d)
    if out_item == "stone-furnace" then table.insert(p.furnaces, o) else table.insert(p.chests, o) end
    table.insert(p.burners, d)
    if out_item == "stone-furnace" then table.insert(p.burners, o) end
    local t3 = put(c, d, defines.inventory.fuel, "coal", 5) or 0
    if out_item == "stone-furnace" then t3 = t3 + (put(c, o, defines.inventory.fuel, "coal", 3) or 0) end
    log(string.format("burner drill on %s (%d/%d) at %.0f,%.0f", target.ore, #valid_list(p.drills[target.ore]),
      target.count, spot.drill.x, spot.drill.y), true)
    return t1 + t2 + t3
  end
end

-- -------------------------------------------------------------------------
-- Steam power
-- -------------------------------------------------------------------------

local function rel(base, off) return {x = base.x + off[1], y = base.y + off[2]} end

local function find_power_site(c)
  local p = P()
  local s = c.surface
  for _, r in ipairs({40, 80, 140, 220}) do
    local water = s.find_tiles_filtered{position = p.home, radius = r, collision_mask = "water_tile", limit = 4000}
    table.sort(water, function(a, b) return dist(a.position, p.home) < dist(b.position, p.home) end)
    local tried = 0
    for _, w in ipairs(water) do
      for _, d in ipairs(DIRS) do
        -- pump stands on the land tile opposite the facing direction
        local v = DIR_VEC[d]
        local L = {x = w.position.x - v[1] + 0.5, y = w.position.y - v[2] + 0.5}
        local lay = POWER_LAYOUT[d]
        local B = rel(L, lay.boiler)
        local E = rel(L, lay.engine)
        tried = tried + 1
        if s.can_place_entity{name = "offshore-pump", position = L, direction = d, force = c.force,
                              build_check_type = defines.build_check_type.manual}
          and s.can_place_entity{name = "boiler", position = B, direction = lay.boiler[3], force = c.force,
                                 build_check_type = defines.build_check_type.manual}
          and s.can_place_entity{name = "steam-engine", position = E, direction = lay.engine[3], force = c.force,
                                 build_check_type = defines.build_check_type.manual} then
          return {pump = L, pump_dir = d, boiler = B, boiler_dir = lay.boiler[3], engine = E, engine_dir = lay.engine[3]}
        end
        if tried > 3000 then break end
      end
      if tried > 3000 then break end
    end
  end
  return nil
end

local function work_on_power(c)
  local p = P()
  if p.power and p.power.engine and p.power.engine.valid then return nil, "done" end
  if not c.force.technologies["steam-power"].researched then return nil, "waiting for steam power research" end
  for _, item in ipairs({"offshore-pump", "boiler", "steam-engine"}) do
    local a, why = obtain(c, item, 1)
    if a then return a end
    if have(c, item) < 1 then return nil, why end
  end
  if have(c, "coal") < 20 then
    local a, why = obtain(c, "coal", 25)
    if a then return a end
    if have(c, "coal") < 20 then return nil, why end
  end
  p.power_site = p.power_site or find_power_site(c)
  local site = p.power_site
  if not site then return nil, "no shoreline for steam power near home" end
  return function()
    local pump, t1 = place(c, "offshore-pump", site.pump, site.pump_dir)
    if not pump then log("pump: " .. tostring(t1)); p.power_site = nil; return 60 end
    local boiler, t2 = place(c, "boiler", site.boiler, site.boiler_dir)
    if not boiler then log("boiler: " .. tostring(t2)); c.mine_entity(pump, true); p.power_site = nil; return 60 end
    local engine, t3 = place(c, "steam-engine", site.engine, site.engine_dir)
    if not engine then log("engine: " .. tostring(t3)); c.mine_entity(pump, true); c.mine_entity(boiler, true); p.power_site = nil; return 60 end
    local t4 = put(c, boiler, defines.inventory.fuel, "coal", 20) or 0
    p.power = {pump = pump, boiler = boiler, engine = engine}
    table.insert(p.burners, boiler)
    log(string.format("steam power built at %.0f,%.0f", engine.position.x, engine.position.y), true)
    return t1 + t2 + t3 + t4
  end
end

-- -------------------------------------------------------------------------
-- Science block: site, clearing, lab, poles to the engine, assemblers
-- -------------------------------------------------------------------------

local function block_pos(O, part) return {x = O.x + part.x, y = O.y + part.y} end

local function find_block_site(c)
  local p = P()
  local s = c.surface
  local near = p.power.engine.position
  for r = 6, 60, 2 do
    for _, a in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
      local O = {x = math.floor(near.x + r * math.cos(math.rad(a))), y = math.floor(near.y + r * math.sin(math.rad(a)))}
      local bad = false
      for _, b in ipairs(p.bad_sites) do if math.abs(b.x - O.x) < 6 and math.abs(b.y - O.y) < 6 then bad = true end end
      local area = {{O.x + BLOCK_BOX.x1, O.y + BLOCK_BOX.y1}, {O.x + BLOCK_BOX.x2, O.y + BLOCK_BOX.y2}}
      if not bad and s.count_tiles_filtered{area = area, collision_mask = "water_tile", limit = 1} == 0
        and s.count_entities_filtered{area = area, type = "resource", limit = 1} == 0
        and s.count_entities_filtered{area = area, type = {"tree", "simple-entity", "corpse", "character", "item-entity", "fish"}, invert = true, limit = 1} == 0 then
        return O
      end
    end
  end
  return nil
end

local function block_entity(role)
  local e = P().block[role]
  if e and e.valid then return e end
  return nil
end

local function work_on_site(c)
  local p = P()
  if p.block_origin then
    -- clear trees and rocks in the footprint
    local O = p.block_origin
    local area = {{O.x + BLOCK_BOX.x1, O.y + BLOCK_BOX.y1}, {O.x + BLOCK_BOX.x2, O.y + BLOCK_BOX.y2}}
    local blockers = c.surface.find_entities_filtered{area = area, type = {"tree", "simple-entity"}, limit = 1}
    if #blockers == 0 then return nil, "done" end
    local b = blockers[1]
    return function()
      local t = travel(c, b.position)
      local ticks = mining_ticks(b)
      if b.valid then c.mine_entity(b, true) end
      return t + ticks
    end
  end
  local O = find_block_site(c)
  if not O then return nil, "no site for the science block near power" end
  p.block_origin = O
  log(string.format("science block site at %d,%d", O.x, O.y), true)
  return function() return 10 end
end

-- Pole chain from the engine to the block's first pole.
local function work_on_power_link(c)
  local p = P()
  local O = p.block_origin
  local engine = p.power.engine
  if p.power_linked then return nil, "done" end
  -- connect to whichever of the block's poles is nearest the engine
  if not p.link_role then
    local best, bd = nil, math.huge
    for _, part in ipairs(BLOCK) do
      if part.name == "small-electric-pole" then
        local d = dist(block_pos(O, part), engine.position)
        if d < bd then best, bd = part.role, d end
      end
    end
    p.link_role = best
  end
  local link_part
  for _, part in ipairs(BLOCK) do if part.role == p.link_role then link_part = part end end
  local target = block_pos(O, link_part)
  local last = p.chain[#p.chain]
  if last and not last.valid then table.remove(p.chain); last = p.chain[#p.chain] end
  local a, why = obtain(c, "small-electric-pole", 2)
  if a then return a end
  if have(c, "small-electric-pole") < 1 then return nil, why end
  local s = c.surface
  local function legal(q)
    return s.can_place_entity{name = "small-electric-pole", position = q, force = c.force,
                              build_check_type = defines.build_check_type.manual}
  end
  local function in_block(q)
    return q.x > O.x + BLOCK_BOX.x1 - 0.5 and q.x < O.x + BLOCK_BOX.x2 + 0.5
       and q.y > O.y + BLOCK_BOX.y1 - 0.5 and q.y < O.y + BLOCK_BOX.y2 + 0.5
  end
  local function give_up_site(reason)
    p.link_fail = (p.link_fail or 0) + 1
    if p.link_fail >= 10 then
      p.bad_sites[#p.bad_sites + 1] = O
      log(string.format("power line cannot reach the block site at %d,%d (%s); choosing another site", O.x, O.y, reason), true)
      p.block_origin, p.link_role, p.chain, p.link_fail = nil, nil, {}, 0
    end
    return nil, reason
  end

  if not last then
    -- first pole on a free tile touching the engine, the one closest to the target
    local bb = engine.bounding_box
    local x1, y1 = math.floor(bb.left_top.x) - 1, math.floor(bb.left_top.y) - 1
    local x2, y2 = math.ceil(bb.right_bottom.x), math.ceil(bb.right_bottom.y)
    local best, bd = nil, math.huge
    for x = x1, x2 do for y = y1, y2 do
      if x == x1 or x == x2 or y == y1 or y == y2 then
        local cand = {x = x + 0.5, y = y + 0.5}
        local d = dist(cand, target)
        if d < bd and not in_block(cand) and legal(cand) then best, bd = cand, d end
      end
    end end
    if not best then return give_up_site("no room for a pole next to the engine") end
    return function()
      local e, t = place(c, "small-electric-pole", best)
      if e then p.chain[#p.chain + 1] = e; return t end
      return 60
    end
  end

  local from = last.position
  if dist(from, target) <= 7.4 then
    -- the block's own pole closes the link
    return function()
      local e, t = place(c, "small-electric-pole", target)
      if not e then log("link pole: " .. tostring(t)); return 120 end
      p.block[p.link_role] = e
      p.power_linked = true
      log("power line reached the science block", true)
      return t
    end
  end
  local here = dist(from, target)
  local dx, dy = target.x - from.x, target.y - from.y
  local goal = {x = from.x + dx / here * 6.5, y = from.y + dy / here * 6.5}
  for r = 0, 5 do
    for ox = -r, r do for oy = -r, r do
      if math.max(math.abs(ox), math.abs(oy)) == r then
        local cand = {x = math.floor(goal.x + ox) + 0.5, y = math.floor(goal.y + oy) + 0.5}
        if dist(cand, from) <= 7.4 and dist(cand, target) < here - 1 and not in_block(cand) and legal(cand) then
          return function()
            local e, t = place(c, "small-electric-pole", cand)
            if e then p.chain[#p.chain + 1] = e; return t end
            return 60
          end
        end
      end
    end end
  end
  -- blocked: clear one tree or rock near the goal
  local tree = s.find_entities_filtered{position = goal, radius = 3, type = {"tree", "simple-entity"}, limit = 1}[1]
  if tree then
    return function()
      local t = travel(c, tree.position)
      local ticks = mining_ticks(tree)
      if tree.valid then c.mine_entity(tree, true) end
      return t + ticks
    end
  end
  return give_up_site("power line blocked")
end

local function place_block_part(c, role_or_index)
  local p = P()
  local part
  for i, bp in ipairs(BLOCK) do
    if bp.role == role_or_index or i == role_or_index then part = bp end
  end
  local at = block_pos(p.block_origin, part)
  local a, why = obtain(c, part.name, 1)
  if a then return a end
  if have(c, part.name) < 1 then return nil, why end
  return function()
    local e, t = place(c, part.name, at, part.dir or 0)
    if not e then log("block part: " .. tostring(t)); return 120 end
    if part.recipe then e.set_recipe(part.recipe) end
    if part.role then p.block[part.role] = e end
    p.block_parts[#p.block_parts + 1] = e
    return t
  end
end

-- The lab and all of the block's poles go in before research starts, so the
-- lab has power whichever block pole the power line connected to.
local function work_on_lab(c)
  if not block_entity("lab") then return place_block_part(c, "lab") end
  local p = P()
  for i, part in ipairs(BLOCK) do
    if part.name == "small-electric-pole" and part.role ~= p.link_role and not block_entity(part.role) then
      return place_block_part(c, i)
    end
  end
  return nil, "done"
end

local function lab_power_problem(lab)
  if lab.status == defines.entity_status.no_power then return "the lab has no power" end
  if lab.status == defines.entity_status.low_power then return "the lab has low power" end
  return nil
end

local function block_complete()
  local p = P()
  local n = 0
  for _, e in ipairs(valid_list(p.block_parts)) do n = n + 1 end
  -- the link pole is placed by the power line, not as a block part
  return n >= #BLOCK - 1
end

local function work_on_block(c)
  local p = P()
  if block_complete() then return nil, "done" end
  -- place the first part that is not there yet
  local s = c.surface
  for i, part in ipairs(BLOCK) do
    if part.role ~= p.link_role then
      local at = block_pos(p.block_origin, part)
      local there = s.find_entities_filtered{name = part.name, position = at, radius = 0.4, limit = 1}[1]
      if not there then return place_block_part(c, i) end
    end
  end
  return nil, "done"
end

-- -------------------------------------------------------------------------
-- Research
-- -------------------------------------------------------------------------

local function red_only(tech)
  if tech.prototype.research_trigger then return false end
  local ing = tech.research_unit_ingredients
  if not ing or #ing == 0 then return false end
  for _, i in pairs(ing) do if i.name ~= "automation-science-pack" then return false end end
  return true
end

local function work_on_automation(c)
  local force = c.force
  if force.technologies["automation"].researched then return nil, "done" end
  local lab = block_entity("lab")
  if not lab then return nil, "no lab" end
  local problem = lab_power_problem(lab)
  if problem and (force.current_research and force.current_research.name == "automation") then
    return nil, problem .. " (boiler fuel " .. fuel_of(P().power.boiler) .. ")"
  end
  local labinv = lab.get_inventory(defines.inventory.lab_input)
  local inside = labinv.get_item_count("automation-science-pack")
  local current = force.current_research
  if not current or current.name ~= "automation" then
    if inside > 0 or have(c, "automation-science-pack") > 0 then
      return function() force.add_research("automation"); log("researching automation", true); return 10 end
    end
  end
  local needed = 10 - inside - math.floor((force.research_progress or 0) * 10)
  if needed <= 0 then return nil, "researching automation" end
  if have(c, "automation-science-pack") > 0 then
    return function() return (put(c, lab, defines.inventory.lab_input, "automation-science-pack", 10)) end
  end
  local a, why = obtain(c, "automation-science-pack", needed)
  if a then return a end
  return nil, why
end

local function queue_red_research(c)
  local force = c.force
  if force.current_research then return end
  local best, cost = nil, math.huge
  for name, tech in pairs(force.technologies) do
    if tech.enabled and not tech.researched and red_only(tech) then
      local ready = true
      for _, pre in pairs(tech.prerequisites) do if not pre.researched then ready = false end end
      if ready then
        local units = tech.research_unit_count or 1e9
        if units < cost then best, cost = name, units end
      end
    end
  end
  if best then
    force.add_research(best)
    log("researching " .. best .. " with assembler-made red science", true)
  end
end

-- -------------------------------------------------------------------------
-- Upkeep: fuel, collecting plates, feeding the block
-- -------------------------------------------------------------------------

local function upkeep_fuel(c)
  local p = P()
  local low, best = nil, math.huge
  for _, e in ipairs(valid_list(p.burners)) do
    local rule = FUEL[e.name] or {low = 3, fill = 15}
    if fuel_of(e) < rule.low then
      local d = dist(e.position, c.position)
      if d < best then low, best = e, d end
    end
  end
  if not low then return nil end
  if have(c, "coal") < 10 then
    local a = obtain(c, "coal", 80)
    return a
  end
  return function()
    local t = travel(c, low.position)
    local filled = 0
    for _, e in ipairs(valid_list(p.burners)) do
      if dist(e.position, c.position) <= REACH and have(c, "coal") > 0 then
        local rule = FUEL[e.name] or {low = 3, fill = 15}
        local want = rule.fill - fuel_of(e)
        if want >= rule.fill / 2 then
          local inserted = e.get_fuel_inventory().insert{name = "coal", count = math.min(want, have(c, "coal"))}
          if inserted > 0 then inv(c).remove{name = "coal", count = inserted}; filled = filled + 1 end
        end
      end
    end
    trace(string.format("refuelled %d burners", filled))
    return t + MOVE_ITEMS_TICKS * math.max(filled, 1)
  end
end

local function upkeep_collect(c)
  -- Empty furnace outputs before they fill up, and coal/stone chests when we are low.
  local p = P()
  for _, e in ipairs(valid_list(p.furnaces)) do
    local r = e.get_inventory(defines.inventory.crafter_output)
    for _, plate in ipairs({"iron-plate", "copper-plate"}) do
      if r.get_item_count(plate) >= 40 and have(c, plate) < 600 then
        return function() return (take(c, e, defines.inventory.crafter_output, plate)) end
      end
    end
  end
  if have(c, "coal") < 20 then
    for _, e in ipairs(valid_list(p.chests)) do
      if e.get_inventory(defines.inventory.chest).get_item_count("coal") >= 10 then
        return function() return (take(c, e, defines.inventory.chest, "coal", 100)) end
      end
    end
  end
  return nil
end

local function upkeep_block(c)
  local p = P()
  local feeds = {{"iron_chest", "iron-plate", 40}, {"copper_chest", "copper-plate", 20}}
  for _, f in ipairs(feeds) do
    local chest = block_entity(f[1])
    if chest then
      local n = chest.get_inventory(defines.inventory.chest).get_item_count(f[2])
      if n < f[3] then
        if have(c, f[2]) >= 10 then
          return function() return (put(c, chest, defines.inventory.chest, f[2], 100)) end
        end
        local a = obtain(c, f[2], 50)
        if a then return a end
      end
    end
  end
  return nil
end

-- -------------------------------------------------------------------------
-- The decision step
-- -------------------------------------------------------------------------

local function progression(c)
  local p = P()
  -- burner mining
  for i, target in ipairs(DRILL_PLAN) do
    if #valid_list(p.drills[target.ore]) < target.count then
      set_phase(string.format("burner mining %d/%d", i, #DRILL_PLAN))
      return work_on_drill(c, target)
    end
  end
  local function craft_lab(cc)
    if block_entity("lab") or have(cc, "lab") >= 1 then return nil, "done" end
    local a, why = obtain(cc, "lab", 1)
    return a, why or "crafting a lab"
  end
  local stages = {
    {"steam power", work_on_power},
    {"lab", craft_lab},
    {"science site", work_on_site},
    {"power line", work_on_power_link},
    {"lab", work_on_lab},
    {"automation research", work_on_automation},
    {"science block", work_on_block},
  }
  for _, st in ipairs(stages) do
    local a, why = st[2](c)
    if why ~= "done" then
      set_phase(st[1])
      return a, why
    end
  end
  set_phase("running red science")
  if not p.block_done_tick then
    p.block_done_tick = game.tick
    log("science block complete; red science now comes from assemblers", true)
  end
  queue_red_research(c)
  return nil, "steady"
end

local function idle_gather(c)
  -- While waiting, top up buffers that are always useful.
  for _, want in ipairs({{"coal", 40}, {"stone", 30}, {"wood", 20}}) do
    if have(c, want[1]) < want[2] and not automated_supply(want[1]) then
      return function() return act_mine(c, want[1], want[2] - have(c, want[1])) end
    end
  end
  return nil
end

local function step(c)
  local p = P()
  local rules = {
    {"fuel", upkeep_fuel},
    {"collect", upkeep_collect},
    {"feed", upkeep_block},
    {"progress", progression},
    {"idle", idle_gather},
  }
  local reasons = {}
  for _, r in ipairs(rules) do
    local action, why = r[2](c)
    if action then
      p.last_rule = r[1]
      return action() or 30
    end
    if why then reasons[#reasons + 1] = r[1] .. ": " .. why end
  end
  p.waiting = table.concat(reasons, "; ")
  return 60
end

-- -------------------------------------------------------------------------
-- Status report
-- -------------------------------------------------------------------------

local function status()
  local p = P()
  local force = game.forces[p.force or "player"]
  local drills = {}
  for ore, list in pairs(p.drills) do drills[ore] = #valid_list(list) end
  local red_made, red_hand = 0, 0
  local asm = block_entity("red_asm")
  if asm then red_made = asm.products_finished end
  local researched = {}
  for _, n in ipairs({"electronics", "steam-power", "automation-science-pack", "automation"}) do
    researched[n] = force.technologies[n].researched
  end
  local after = {}
  if p.block_done_tick then
    for name, t in pairs(force.technologies) do
      if t.researched and p.research_done[name] and p.research_done[name] > p.block_done_tick then after[#after + 1] = name end
    end
  end
  return {
    active = p.active, phase = p.phase, waiting = p.waiting, last_rule = p.last_rule,
    game_minutes = (game.tick - (p.started or game.tick)) / 3600,
    drills = drills, furnaces = #valid_list(p.furnaces), chests = #valid_list(p.chests),
    power = (p.power and p.power.engine and p.power.engine.valid) and true or false,
    block_parts = #valid_list(p.block_parts), block_done = p.block_done_tick ~= nil,
    red_science_from_assembler = red_made,
    researched = researched, researched_after_block = after,
    current_research = force.current_research and force.current_research.name or nil,
    stats = p.stats, phases = p.phase_log,
    shortcuts = {"teleport (waits walking time)", "batch mining (waits mining time)"},
    start_items = p.start_items,
  }
end

function AIPlay.status() return status() end

function AIPlay.debug()
  local p = P()
  local c = storage.ai_player.character
  local items = {}
  if c and c.valid then
    for _, it in pairs(c.get_main_inventory().get_contents()) do items[it.name] = (items[it.name] or 0) + it.count end
  end
  local queue = {}
  if c and c.valid then for _, q in pairs(c.crafting_queue or {}) do queue[#queue + 1] = q.recipe .. " x" .. q.count end end
  return {trace = p.trace, log = p.log, inventory = items, crafting = queue, waiting = p.waiting, last_rule = p.last_rule}
end

local function write_status()
  pcall(helpers.write_file, "ai-player/play-status.json", helpers.table_to_json(status()), false)
end

-- -------------------------------------------------------------------------
-- Lifecycle
-- -------------------------------------------------------------------------

function AIPlay.init()
  storage.ai_player.play = storage.ai_player.play or {active = false}
end

function AIPlay.start(character, opts)
  storage.ai_player.autonomy_enabled = false
  local o = opts or {}
  if o.fresh then
    character.clear_items_inside()
  end
  storage.ai_player.play = {
    active = true, started = game.tick, home = {x = character.position.x, y = character.position.y},
    force = character.force.name, busy_until = game.tick,
    log = {}, phase_log = {}, patches = {}, drills = {}, furnaces = {}, chests = {}, burners = {},
    hand_furnaces = {}, chain = {}, block = {}, block_parts = {}, research_done = {}, trace = {}, craft_seen = {}, bad_sites = {},
    stats = {actions = 0, placed = 0, mined = 0, crafted = 0, walked = 0, errors = 0},
  }
  storage.ai_player.play.start_items = character.get_item_count()
  pcall(helpers.remove_path, "ai-player/play-log.txt")
  log(string.format("play loop started at %.0f,%.0f%s", character.position.x, character.position.y,
    o.fresh and " with an empty inventory" or ""), true)
  write_status()
end

function AIPlay.stop()
  local p = P()
  if p then p.active = false; log("play loop stopped", true); write_status() end
end

function AIPlay.on_research_finished(event)
  local p = storage.ai_player and storage.ai_player.play
  if p and p.research_done then p.research_done[event.research.name] = event.tick end
end

local function tick_inner()
  local p = storage.ai_player and storage.ai_player.play
  if not (p and p.active) then return end
  if game.tick - (p.status_tick or 0) >= 600 then
    p.status_tick = game.tick
    write_status()
    -- a map marker that follows the AI, and the area around it revealed
    local ch = storage.ai_player.character
    if ch and ch.valid then
      if p.map_tag and p.map_tag.valid then p.map_tag.destroy() end
      local f = ch.force
      pcall(f.chart, ch.surface, {{ch.position.x - 48, ch.position.y - 48}, {ch.position.x + 48, ch.position.y + 48}})
      local ok, tag = pcall(f.add_chart_tag, ch.surface, {position = ch.position, text = "AI: " .. tostring(p.phase),
        icon = {type = "virtual", name = "signal-A"}})
      if ok then p.map_tag = tag end
    end
  end
  if game.tick < p.busy_until then return end
  local c = storage.ai_player.character
  if not (c and c.valid) then p.busy_until = game.tick + 120; return end
  sync_crafting(c)
  local ok, ticks = pcall(step, c)
  if not ok then
    p.stats.errors = p.stats.errors + 1
    log("error: " .. tostring(ticks), p.stats.errors <= 20)
    ticks = 300
  elseif type(ticks) ~= "number" then
    p.stats.errors = p.stats.errors + 1
    log("error: an action returned " .. tostring(ticks) .. " instead of a duration", p.stats.errors <= 20)
    ticks = 120
  end
  p.stats.actions = p.stats.actions + 1
  p.busy_until = game.tick + math.max(ticks, NTH)
end

-- Never let a bug in the play loop crash the game: stop the loop instead.
function AIPlay.tick()
  local ok, err = pcall(tick_inner)
  if not ok then
    local p = storage.ai_player and storage.ai_player.play
    if p then p.active = false end
    game.print("[AI] play loop stopped after an internal error: " .. tostring(err), {r = 1, g = 0.4, b = 0.4})
    pcall(helpers.write_file, "ai-player/play-log.txt", "FATAL " .. tostring(err) .. "\n", true)
  end
end

AIPlay.NTH = NTH
return AIPlay
