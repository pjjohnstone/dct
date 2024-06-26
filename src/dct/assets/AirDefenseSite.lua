--[[
-- SPDX-License-Identifier: LGPL-3.0
--
-- Subtype of StaticAsset that includes defenses which disband
-- when the parent asset dies.
--]]

local utils        = require("libs.utils")
local class        = require("libs.namedclass")
local enum         = require("dct.enum")
local StaticAsset  = require("dct.assets.StaticAsset")
local Subordinates = require("dct.libs.Subordinates")
local Logger       = require("dct.libs.Logger")

local siteTypes = {
    ["SNR_75V"]              = "SA-2",
    ["snr s-125 tr"]         = "SA-3",
    ["RPC_5N62V"]            = "SA-5",
    ["Kub 1S91 str"]         = "SA-6",
    ["S-300PS 40B6M tr"]     = "SA-10",
    ["SA-11 Buk LN 9A310M1"] = "SA-11",
    ["Hawk tr"]              = "Hawk",
    ["Patriot str"]          = "Patriot",
	["55G6 EWR"]             = "EWR",
	["1L13 EWR"]             = "EWR",
}

local AirDefenseSite = class("AirDefenseSite", StaticAsset, Subordinates)
function AirDefenseSite:__init(template)
    Subordinates.__init(self)
    if template ~= nil then
        self._logger = Logger("AirDefenseSite - "..template.name.."")
        template = self:_modifyTemplate(template)
    end
	StaticAsset.__init(self, template)
	self:_addMarshalNames({
		"_subordinates",
		"sitetype",
	})
end

function AirDefenseSite.assettypes()
	return {
		enum.assetType.EWR,
		enum.assetType.SAM,
	}
end

function AirDefenseSite:_completeinit(template)
	StaticAsset._completeinit(self, template)

	-- try to infer the site type
	for _, grp in pairs(template.tpldata) do
		for _, unit in pairs(grp.data.units) do
			if siteTypes[unit.type] ~= nil then
				self.sitetype = siteTypes[unit.type]
				break
			end
		end
	end
end

function AirDefenseSite:_splitUnits(sam, shorad, gid)

	-- ignore non-ground unit groups
	if sam.tpldata[gid].category ~= Unit.Category.GROUND_UNIT then
		return
	end

	local originalGroup = sam.tpldata[gid].data
	local shoradGroup = shorad.tpldata[gid].data
	self._logger:debug("processing group '%s' (%d)", originalGroup.name, gid)

	-- rename SHORAD group to avoid spawn conflicts
	shoradGroup.name = originalGroup.name.."-SHORAD"

	-- iterate through units in reverse order to avoid issues when removing items
	for uid = #originalGroup.units, 1, -1  do
		local unit = originalGroup.units[uid]
		self._logger:debug("processing unit '%s' (%d)", unit.name, uid)
		local desc = Unit.getDescByName(unit.type)
		if desc.attributes["AAA"] or
		   desc.attributes["SR SAM"] or
		   desc.attributes["MANPADS"] then
			self._logger:debug("SAM unit removed")
			table.remove(originalGroup.units, uid)
		else
			self._logger:debug("SHORAD unit removed")
			table.remove(shoradGroup.units, uid)
		end
	end

	-- prune empty groups
	if next(originalGroup.units) == nil then
		self._logger:debug("SAM group '%s' removed (%s)",
			originalGroup.name, gid)
		table.remove(sam.tpldata, gid)
	end

	if next(shoradGroup.units) == nil then
		self._logger:debug("SHORAD group '%s' removed (%s)",
			shoradGroup.name, gid)
		table.remove(shorad.tpldata, gid)
	end
end

-- splits SHORAD out of the template and spawns it as a separate asset
function AirDefenseSite:_modifyTemplate(template)
    local shorad = utils.deepcopy(template)
	local sam = utils.deepcopy(template)
	shorad.hasDeathGoals = false
	shorad.regenerate = self.regenerate
	shorad.objtype = enum.assetType.SHORAD
	shorad.name = template.name.."-SHORAD"
	shorad.desc = "SHORAD Target"
	shorad.ignore = true
	shorad.cost = 0

	-- split everything between the two templates
	-- (in reverse order so that the group pruning does not cause issues)
	for gid = #template.tpldata, 1, -1 do
		self:_splitUnits(sam, shorad, gid)
	end

	-- remove any waypoints in the SHORAD template to avoid unit pathing errors
	for _, group in ipairs(shorad.tpldata) do
		group.data.route = {
			points = {},
			spans  = {},
		}
	end

	-- abort if the SAM group is empty (ie. this is a pure SHORAD SAM)
	if next(sam.tpldata) == nil then
		self._logger:debug(
			"SHORAD template not created (only shorad units present)", shorad.name)
		return template
	end

	-- spawn the new shorad asset as a subordinate if it contains any units
	if next(shorad.tpldata) ~= nil then
        local assetmgr = _G.dct.Theater.singleton():getAssetMgr()
		local shoradAsset = assetmgr:factory(shorad.objtype)(shorad)
        assetmgr:add(shoradAsset)
        self:addSubordinate(shoradAsset)
	else
		self._logger:debug(
			"SHORAD template not created (no shorad units)", shorad.name)
	end

	return sam
end

return AirDefenseSite
