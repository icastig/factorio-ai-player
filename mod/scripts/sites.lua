-- sites.lua — blueprint handling for the planner (M1).
--
-- find_site       nearest free spot for a blueprint: no buildings, no cliffs,
--                 no ore, no water; trees and rocks are allowed (they get
--                 marked for deconstruction when the blueprint is placed).
-- place_blueprint place a blueprint as ghosts with build_mode "forced", the
--                 same rules as a player's shift-click: nothing is placed
--                 over buildings, water or cliffs; trees and rocks in the way
--                 are marked for deconstruction. No create_entity shortcut.
-- blueprint_cost  items needed to build a blueprint (entities and tiles).

local AISites = {}

local SURFACE_NAME = "nauvis"

-- Entity types that may sit where a blueprint goes. Everything else
-- (buildings, cliffs, resources) makes a candidate site unusable.
local CLEARABLE_TYPES = {"tree", "simple-entity", "fish", "corpse", "character", "item-entity"}

-- Open a blueprint string in a temporary script inventory.
-- Returns (inventory, stack) or (nil, error). Caller must destroy the inventory.
local function open_blueprint(bp_string)
  if type(bp_string) ~= "string" or bp_string == "" then
    return nil, "blueprint string required"
  end
  local inv = game.create_inventory(1)
  local stack = inv[1]
  local err = stack.import_stack(bp_string)
  if err == -1 or not stack.valid_for_read or not stack.is_blueprint then
    inv.destroy()
    return nil, "not a single blueprint (import result " .. tostring(err) .. ")"
  end
  if not stack.is_blueprint_setup() then
    inv.destroy()
    return nil, "blueprint is empty"
  end
  return inv, stack
end

-- Bounding box of a blueprint in its own coordinates, from entity collision
-- boxes and tiles. Rotation is ignored: blocks are placed unrotated.
local function blueprint_bounds(stack)
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, be in ipairs(stack.get_blueprint_entities() or {}) do
    local proto = prototypes.entity[be.name]
    local box = proto and proto.collision_box or {left_top = {x = -0.5, y = -0.5}, right_bottom = {x = 0.5, y = 0.5}}
    local dir = be.direction or 0
    local lx, ly, rx, ry = box.left_top.x, box.left_top.y, box.right_bottom.x, box.right_bottom.y
    -- Directions in 2.x are 16-way; 4 and 12 are east and west (90 degrees).
    if dir == 4 or dir == 12 then lx, ly, rx, ry = ly, lx, ry, rx end
    x1 = math.min(x1, be.position.x + lx); y1 = math.min(y1, be.position.y + ly)
    x2 = math.max(x2, be.position.x + rx); y2 = math.max(y2, be.position.y + ry)
  end
  for _, t in ipairs(stack.get_blueprint_tiles() or {}) do
    x1 = math.min(x1, t.position.x); y1 = math.min(y1, t.position.y)
    x2 = math.max(x2, t.position.x + 1); y2 = math.max(y2, t.position.y + 1)
  end
  if x1 == math.huge then return nil end
  x1, y1, x2, y2 = math.floor(x1), math.floor(y1), math.ceil(x2), math.ceil(y2)
  -- build_blueprint centres the blueprint on the given position: an entity at
  -- blueprint coordinate r lands at position + r - centre. Observed on 2.1.21:
  -- bounds -3..21 x -1..19 landed with centre (9, 9).
  return {x1 = x1, y1 = y1, x2 = x2, y2 = y2,
          cx = math.floor((x1 + x2) / 2 + 0.5), cy = math.floor((y1 + y2) / 2 + 0.5)}
end

local function area_generated(surface, a)
  for cx = math.floor(a.left_top.x / 32), math.floor(a.right_bottom.x / 32) do
    for cy = math.floor(a.left_top.y / 32), math.floor(a.right_bottom.y / 32) do
      if not surface.is_chunk_generated({cx, cy}) then return false end
    end
  end
  return true
end

-- Why an area can't take a blueprint, or nil when it can.
local function area_problem(surface, a)
  if not area_generated(surface, a) then return "not generated" end
  if surface.count_entities_filtered{area = a, type = "resource", limit = 1} > 0 then return "ore" end
  if surface.count_tiles_filtered{area = a, collision_mask = "water_tile", limit = 1} > 0 then return "water" end
  if surface.count_entities_filtered{area = a, type = CLEARABLE_TYPES, invert = true, limit = 1} > 0 then
    return "occupied"
  end
  return nil
end

-- Spiral of candidate offsets around (0,0), ring by ring, in steps of `step`.
local function ring(r, step)
  local out = {}
  if r == 0 then out[1] = {0, 0}; return out end
  local d = r * step
  for i = -r, r do
    out[#out + 1] = {i * step, -d}
    out[#out + 1] = {i * step, d}
  end
  for i = -r + 1, r - 1 do
    out[#out + 1] = {-d, i * step}
    out[#out + 1] = {d, i * step}
  end
  return out
end

-- params: {blueprint=<string>, near={x,y}?, margin=3, max_radius=256, step=4}
-- Returns {ok, position={x,y}, area, trees_and_rocks, checked} or {ok=false, detail}.
function AISites.find_site(params)
  local p = params or {}
  local surface = game.surfaces[SURFACE_NAME]
  local inv, stack = open_blueprint(p.blueprint)
  if not inv then return {ok = false, detail = stack} end
  local b = blueprint_bounds(stack)
  inv.destroy()
  if not b then return {ok = false, detail = "blueprint has no entities or tiles"} end

  local near = p.near or {x = 0, y = 0}
  local nx, ny = math.floor(near.x or near[1] or 0), math.floor(near.y or near[2] or 0)
  local margin = tonumber(p.margin) or 3
  local step = tonumber(p.step) or 4
  local max_r = math.floor((tonumber(p.max_radius) or 256) / step)
  local checked = 0
  local reasons = {}

  for r = 0, max_r do
    for _, off in ipairs(ring(r, step)) do
      local px, py = nx + off[1], ny + off[2]
      local a = {
        left_top     = {x = px + b.x1 - b.cx - margin, y = py + b.y1 - b.cy - margin},
        right_bottom = {x = px + b.x2 - b.cx + margin, y = py + b.y2 - b.cy + margin},
      }
      checked = checked + 1
      local why = area_problem(surface, a)
      if not why then
        local clear = surface.count_entities_filtered{area = a, type = {"tree", "simple-entity"}}
        return {ok = true, position = {x = px, y = py}, area = a,
                size = {w = b.x2 - b.x1, h = b.y2 - b.y1},
                trees_and_rocks = clear, checked = checked}
      end
      reasons[why] = (reasons[why] or 0) + 1
    end
  end
  local parts = {}
  for k, v in pairs(reasons) do parts[#parts + 1] = k .. "=" .. v end
  return {ok = false, detail = "no free site within radius (" .. table.concat(parts, ", ") .. ")", checked = checked}
end

-- params: {blueprint=<string>, x, y, force?}
-- Returns {ok, ghosts, marked_for_deconstruction} or {ok=false, detail}.
function AISites.place_blueprint(params)
  local p = params or {}
  local surface = game.surfaces[SURFACE_NAME]
  local fname = p.force or (storage.ai_player and storage.ai_player.force_name) or "player"
  local force = game.forces[fname]
  if not force then return {ok = false, detail = "force '" .. fname .. "' not found"} end
  local inv, stack = open_blueprint(p.blueprint)
  if not inv then return {ok = false, detail = stack} end
  local expected = #(stack.get_blueprint_entities() or {}) + #(stack.get_blueprint_tiles() or {})
  local ghosts = stack.build_blueprint{
    surface = surface, force = force,
    position = {x = tonumber(p.x) or 0, y = tonumber(p.y) or 0},
    build_mode = defines.build_mode.forced,
  }
  inv.destroy()
  local n = 0
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, g in pairs(ghosts or {}) do
    if g.valid then
      n = n + 1
      local bb = g.bounding_box
      x1 = math.min(x1, bb.left_top.x); y1 = math.min(y1, bb.left_top.y)
      x2 = math.max(x2, bb.right_bottom.x); y2 = math.max(y2, bb.right_bottom.y)
    end
  end
  local marked = surface.count_entities_filtered{to_be_deconstructed = true}
  local placed_area = nil
  if n > 0 then
    placed_area = {left_top = {x = math.floor(x1), y = math.floor(y1)},
                   right_bottom = {x = math.ceil(x2), y = math.ceil(y2)}}
  end
  return {ok = n > 0, ghosts = n, expected = expected, marked_for_deconstruction = marked,
          area = placed_area,
          detail = (n == expected) and "all placed" or string.format("%d of %d placed", n, expected)}
end

-- params: {blueprint=<string>}. Returns {ok, items={name=count}}.
function AISites.blueprint_cost(params)
  local p = params or {}
  local inv, stack = open_blueprint(p.blueprint)
  if not inv then return {ok = false, detail = stack} end
  local items = {}
  for _, be in ipairs(stack.get_blueprint_entities() or {}) do
    local proto = prototypes.entity[be.name]
    local place = proto and proto.items_to_place_this and proto.items_to_place_this[1]
    if place then items[place.name] = (items[place.name] or 0) + (place.count or 1) end
  end
  for _, t in ipairs(stack.get_blueprint_tiles() or {}) do
    local proto = prototypes.tile[t.name]
    local place = proto and proto.items_to_place_this and proto.items_to_place_this[1]
    if place then items[place.name] = (items[place.name] or 0) + (place.count or 1) end
  end
  inv.destroy()
  return {ok = true, items = items}
end

return AISites
