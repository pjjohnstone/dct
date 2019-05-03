--[[
-- SPDX-License-Identifier: LGPL-3.0
--
-- Provides functions for defining a world state.
--]]

require("io")
local class  = require("libs.class")

local GameState = class()
function GameState:__init(theater, statepath)
	self.path     = statepath
	self.theater  = theater
	self.dirty    = false
	self.generate = true
	self.objectives = {}

	local statefile = io.open(self.path)
	if statefile then
		statefile:close()
		self.generate = false
		-- TODO: read in saved state
	end
end

--[[
function GameState:__dirtySet()
    self.dirty = true
end

function GameState:dirtyClear()
    self.dirty = false
end

function GameState:_statsAliveInc(atype, subtype)
end

function GameState:_statsAliveDec(atype, subtype)
end

function GameState:statsGet()
    -- return a read-only copy of the current stats
end

function GameState:statsSetNominal(atype, subtype, val)
end

function GameState:statsSetOriginal(atype, subtype, val)
end

function GameState:export()
	-- TODO: export a copy of the game state in a
	-- flat table representation
	self:dirtyClear()
end
--]]

function GameState:shouldGenerate()
	return self.generate
end

function GameState:addObjectives(regionname, objectivelist)
	local json = require("libs.json")
	-- print("state.addObjectives() start")
	-- print("objectivelist: "..#objectivelist)
	-- print(json:encode_pretty(objectivelist))
	-- print("state.addObjectives() end")

	-- TODO: for now do a simple storage of the objectives, it is assumed
	-- all objective names are unique
	for k, v in pairs(objectivelist) do
		self.objectives[v.name] = v
	end
end

function GameState:spawnActive()
	local numobjs = 0
    -- TODO: for now we are just going to spawn everything
	for name, obj in pairs(self.objectives) do
		obj:spawn()
		numobjs = numobjs + 1
	end
	env.warning("==> GameState: attempted to spawn "..numobjs.." objectives")
end

return {
	["GameState"] = GameState,
}