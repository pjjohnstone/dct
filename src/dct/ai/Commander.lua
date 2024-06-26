--[[
-- SPDX-License-Identifier: LGPL-3.0
--
-- Defines a side's strategic theater commander.
--]]

local utils      = require("libs.utils")
local containers = require("libs.containers")
local enum       = require("dct.enum")
local dctutils   = require("dct.utils")
local Mission    = require("dct.ai.Mission")
local Stats      = require("dct.libs.Stats")
local Command    = require("dct.Command")
local Observable = require("dct.libs.Observable")
local Logger     = dct.Logger.getByName("Commander")

local function heapsort_tgtlist(assetmgr, cmdr, filterlist)
	local tgtlist = assetmgr:getTargets(cmdr.owner, filterlist)
	local pq = containers.PriorityQueue()

	-- priority sort target list
	for tgtname, _ in pairs(tgtlist) do
		local tgt = assetmgr:getAsset(tgtname)
		if tgt ~= nil and cmdr:canTarget(tgt) then
			pq:push(tgt:getPriority(cmdr.owner), tgt)
		end
	end

	return pq
end

local function genstatids()
	local tbl = {}

	for k,v in pairs(enum.missionType) do
		table.insert(tbl, {v, 0, k})
	end
	return tbl
end

--[[
-- For now the commander is only concerned with flight missions
--]]
local Commander = require("libs.namedclass")("Commander", Observable)

function Commander:__init(theater, side)
	Observable.__init(self, Logger)
	self.theater      = theater
	self.owner        = side
	self.missionstats = Stats(genstatids())
	self.missions     = {}
	self.aifreq       = 2*60 -- 2 minutes in seconds

	-- In addition to mapping missions by id in `missions`, they are
	-- also mapped by asset name
	self.missionsByTarget = {}

	theater:queueCommand(120, Command(
		"Commander.startIADS:"..tostring(self.owner),
		self.startIADS, self))
	theater:queueCommand(self.aifreq, Command(
		"Commander.update:"..tostring(self.owner),
		self.update, self))
end

function Commander:startIADS()
	self.IADS = require("dct.systems.IADS")(self)
end

function Commander:update(time)
	for _, mission in pairs(self.missions) do
		mission:update(time)
	end
	return self.aifreq
end

--[[
-- TODO: complete this, the enemy information is missing
-- What does a commander need to track for theater status?
--   * the UI currently defines these items that need to be "tracked":
--     - Sea - representation of the opponent's sea control
--     - Air - representation of the opponent's air control
--     - ELINT - representation of the opponent's ability to detect
--     - SAM - representation of the opponent's ability to defend
--     - current active air mission types
--]]
function Commander:getTheaterUpdate()
	local theater = dct.Theater.singleton()
	local theaterUpdate = {}
	local tks, start

	theaterUpdate.friendly = {}
	tks, start = theater:getTickets():get(self.owner)
	theaterUpdate.friendly.str = math.floor((tks / start)*100)
	theaterUpdate.enemy = {}
	theaterUpdate.enemy.sea = 50
	theaterUpdate.enemy.air = 50
	theaterUpdate.enemy.elint = 50
	theaterUpdate.enemy.sam = 50
	tks, start = theater:getTickets():get(dctutils.getenemy(self.owner))
	theaterUpdate.enemy.str = math.floor((tks / start)*100)
	theaterUpdate.missions = self.missionstats:getStats()
	for k,v in pairs(theaterUpdate.missions) do
		if v == 0 then
			theaterUpdate.missions[k] = nil
		end
	end
	return theaterUpdate
end

local invalidXpdrTbl = {
	["0000"] = true,
	["7700"] = true,
	["7600"] = true,
	["7500"] = true,
	["7400"] = true,
}

--[[
-- Generates a mission id as well as generating IFF codes for the
-- mission (in octal).
--
-- Returns: a table with the following:
--   * id (string): is the mission ID
--   * m1 (number): is the mode 1 IFF code
--   * m3 (number): is the mode 3 IFF code
--  If 'nil' is returned no valid mission id could be generated.
--]]
function Commander:genMissionCodes(msntype)
	local id
	local missionId
	local digit1 = enum.squawkMissionType[msntype]
	while true do
		missionId = math.random(1, 63)
		id = string.format("%01o%02o0", digit1, missionId)
		if invalidXpdrTbl[id] == nil and self:getMission(id) == nil then
			break
		end
	end
	local m1 = (8*digit1)+(enum.squawkMissionSubType[msntype] or 0)
	local m3 = (512*digit1)+(missionId*8)
	return { ["id"] = id, ["m1"] = m1, ["m3"] = m3, }
end

--[[
-- getTopTargets - list available targets for a given ATO, ordered from highest
-- to lowest priority
--
-- allowedmissions - (table) ATO of asset requesting the mission
-- num - (number) maximum number of returned results
--
-- return: ordered list of target assets
--]]
function Commander:getTopTargets(allowedmissions, num)
	local assetfilter = {}

	for _, v in pairs(allowedmissions) do
		utils.mergetables(assetfilter, enum.missionTypeMap[v])
	end

	local pq = heapsort_tgtlist(self.theater:getAssetMgr(), self, assetfilter)
	local tgts = {}

	for _ = 1, num do
		local tgt = pq:pop()
		if tgt ~= nil then
			table.insert(tgts, tgt)
		end
	end

	return tgts
end

--[[
-- recommendMission - recommend a mission type for a given asset
--
-- allowedmissions - (table) ATO of asset requesting the mission
--
-- return: mission type value
--]]
function Commander:recommendMissionType(allowedmissions)
	local tgts = self:getTopTargets(allowedmissions, 1)
	if next(tgts) == nil then
		return nil
	end
	return dctutils.assettype2mission(tgts[1].type)
end

--[[
-- createMission - create and register a mission targeting a given asset
--
-- grpname - the name of the asset that is assigned to the mission.
-- missiontype - the type of the mission that will be created.
-- tgt - asset object that will be used as the mission target.
--
-- return: a Mission object or nil if the target is invalid
--]]
function Commander:createMission(grpname, missiontype, tgt)
	Logger:debug("createMission() - tgt name: '%s'; isTargeted: %s; priority: %d",
		tgt.name, tostring(tgt:isTargeted(self.owner)), tgt:getPriority(self.owner))

	-- mission target is not valid, cannot assign
	if not self:canTarget(tgt) then
		return nil
	end

	-- chosen target already has a mission assigned
	local assetmgr = self.theater:getAssetMgr()
	local mission = self.missionsByTarget[tgt.name]
	if mission ~= nil then
		mission:addAssigned(assetmgr:getAsset(grpname))
		return mission
	end

	-- no mission for target, create a new one
	local plan = { require("dct.ai.actions.KillTarget")(tgt) }
	mission = Mission(self, missiontype, tgt, plan)
	mission:addAssigned(assetmgr:getAsset(grpname))
	self:addMission(mission)

	Logger:debug(
		"createMission() - assigned target '%s' to mission %d (codename: %s)",
		tgt.name, mission.id, tgt.codename)

	self:notify(dctutils.buildevent.addMission(self, mission, tgt))
	return mission
end

--[[
-- requestMission - get a new mission
--
-- Creates or joins a mission where the target conforms to the mission type
-- specified and is of the highest priority. The Commander will track
-- the mission and handling tracking which asset is assigned to the
-- mission.
--
-- grpname - the name of the asset that is assigned to the mission.
-- missiontype - the type of mission, which defines the type of target
--   that will be looked for.
--
-- return: a Mission object or nil if no target can be found which
--   meets the mission criteria
--]]
function Commander:requestMission(grpname, missiontype)
	local assetmgr = self.theater:getAssetMgr()
	local pq = heapsort_tgtlist(assetmgr, self, enum.missionTypeMap[missiontype])

	-- if no target, there is no mission to assign so return back
	-- a nil object
	if pq:peek() == nil then
		return nil
	end

	-- take all max-priority missions from the queue and choose a random one
	local tgt, prio = pq:pop()
	local targets = { tgt }
	local nextprio
	while true do
		tgt, nextprio = pq:pop()
		if tgt == nil or nextprio ~= prio then
			break
		else
			table.insert(targets, tgt)
		end
	end
	tgt = targets[math.random(#targets)]

	Logger:debug("requestMission() - tgt name: '%s'; isTargeted: %s; priority: %d",
		tgt.name, tostring(tgt:isTargeted()), prio)

	-- chosen target already has a mission assigned
	local mission = self.missionsByTarget[tgt.name]
	if mission ~= nil then
		mission:addAssigned(assetmgr:getAsset(grpname))
		return mission
	end

	-- no mission for target, create a new one
	local plan = { require("dct.ai.actions.KillTarget")(tgt) }
	mission = Mission(self, missiontype, tgt, plan)
	self:addMission(mission)

	self:notify(dctutils.buildevent.addMission(self, mission, tgt))
	mission:addAssigned(assetmgr:getAsset(grpname))

	Logger:debug(
		"requestMission() - assigned target '%s' to mission %d (codename: %s)",
		tgt.name, mission.id, tgt.codename)

	return mission
end

--[[
-- return the Mission object identified by the id supplied.
--]]
function Commander:getMission(id)
	return self.missions[id]
end

--[[
-- return the number of missions that can be assigned per given type
--]]
function Commander:getAvailableMissions(missionTypes)
	local assetmgr = self.theater:getAssetMgr()

	-- map asset types to the given mission type names
	local assetTypeMap = {}
	for missionTypeName, missionTypeId in pairs(missionTypes) do
		for assetType, _ in pairs(enum.missionTypeMap[missionTypeId]) do
			assetTypeMap[assetType] = missionTypeName
		end
	end

	local tgts = assetmgr:getTargets(self.owner, assetTypeMap)
	local counts = {}

	-- build a user-friendly mapping using the mission type names as keys
	for name, assetTypeId in pairs(tgts) do
		local asset = assetmgr:getAsset(name)
		local type = assetTypeMap[assetTypeId]
		if asset ~= nil and self:canTarget(asset) then
			if counts[type] ~= nil then
				counts[type] = counts[type] + 1
			else
				counts[type] = 1
			end
		end
	end

	return counts
end

--[[
-- start tracking a given mission internally
--]]
function Commander:addMission(mission)
	self.missions[mission:getID()] = mission
	self.missionsByTarget[mission.target] = mission
	self.missionstats:inc(mission.type)
end

--[[
-- remove the mission identified by id from the commander's tracking
--]]
function Commander:removeMission(id)
	local mission = self.missions[id]
	self.missions[id] = nil
	self.missionsByTarget[mission.target] = nil
	self.missionstats:dec(mission.type)
	Logger:debug("removeMission(%d)", id)
end

--[[
-- Checks if an asset can be targeted by a mission
-- Returns: boolean
--]]
function Commander:canTarget(asset)
	-- only attack enemy assets
	if asset.owner ~= dctutils.getenemy(self.owner) then
		return false
	end
	-- ignore assets that are scheduled for cleanup
	if asset:isDead() then
		return false
	end
	-- airbases are indestructible at the moment
	if asset.type == enum.assetType.AIRBASE then
		return false
	end
	-- ignore assets that are assigned to missions that have
	-- reached the agent quota
	local mission = self.missionsByTarget[asset.name]
	if mission ~= nil and mission.isfull then
		return false
	end
	-- finally, accept asset as mission target
	return true
end

--[[
-- Get the mission assigned to an agent asset
--]]
function Commander:getAssigned(asset)
	local msn = self.missions[asset.missionid]

	if msn == nil then
		asset.missionid = enum.missionInvalidID
		return nil
	end

	local member = msn:isMember(asset.name)
	if not member then
		asset.missionid = enum.missionInvalidID
		return nil
	end
	return msn
end

function Commander:getAsset(name)
	return self.theater:getAssetMgr():getAsset(name)
end

return Commander
