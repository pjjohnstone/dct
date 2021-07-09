--[[
-- SPDX-License-Identifier: LGPL-3.0
--
-- UI Commands
--]]

require("os")
local class    = require("libs.class")
local utils    = require("libs.utils")
local enum     = require("dct.enum")
local dctutils = require("dct.utils")
local human    = require("dct.ui.human")
local Command  = require("dct.Command")
local Logger   = dct.Logger.getByName("UI")
local loadout  = require("dct.systems.loadouts")

local UICmd = class(Command)
function UICmd:__init(theater, data)
	assert(theater ~= nil, "value error: theater required")
	assert(data ~= nil, "value error: data required")
	local asset = theater:getAssetMgr():getAsset(data.name)
	assert(asset, "runtime error: asset was nil, "..data.name)

	Command.__init(self, "UICmd", self.uicmd, self)

	self.prio         = Command.PRIORITY.UI
	self.theater      = theater
	self.asset        = asset
	self.type         = data.type
	self.displaytime  = 30
	self.displayclear = true
end

function UICmd:isAlive()
	return dctutils.isalive(self.asset.name)
end

function UICmd:uicmd(time)
	-- only process commands from live players unless they are abort
	-- commands
	if not self:isAlive() and
	   self.type ~= enum.uiRequestType.MISSIONABORT then
		Logger:debug("UICmd thinks player is dead, ignore cmd; %s", debug.traceback())
		self.asset.cmdpending = false
		return nil
	end

	local cmdr = self.theater:getCommander(self.asset.owner)
	local msg  = self:_execute(time, cmdr)
	assert(msg ~= nil and type(msg) == "string", "msg must be a string")
	trigger.action.outTextForGroup(self.asset.groupId, msg,
		self.displaytime, self.displayclear)
	self.asset.cmdpending = false
	return nil
end

local ScratchPadDisplay = class(UICmd)
function ScratchPadDisplay:__init(theater, data)
	UICmd.__init(self, theater, data)
	self.name = "ScratchPadDisplay:"..data.name
end

function ScratchPadDisplay:_execute(_, _)
	local msg = string.format("Scratch Pad: '%s'",
		tostring(self.asset.scratchpad))
	return msg
end

local ScratchPadSet = class(UICmd)
function ScratchPadSet:__init(theater, data)
	UICmd.__init(self, theater, data)
	self.name = "ScratchPadSet:"..data.name
end

function ScratchPadSet:_execute(_, _)
	local mrkid = human.getMarkID()
	local pos   = Group.getByName(self.asset.name):getUnit(1):getPoint()

	self.theater:getSystem("dct.ui.scratchpad"):set(mrkid, self.asset.name)
	trigger.action.markToGroup(mrkid, "edit me", pos,
		self.asset.groupId, false)
	local msg = "Look on F10 MAP for user mark with contents \"edit me\"\n "..
		"Edit body with your scratchpad information. "..
		"Click off the mark when finished. "..
		"The mark will automatically be deleted."
	return msg
end

local TheaterUpdateCmd = class(UICmd)
function TheaterUpdateCmd:__init(theater, data)
	UICmd.__init(self, theater, data)
	self.name = "TheaterUpdateCmd:"..data.name
end

function TheaterUpdateCmd:_execute(_, cmdr)
	local update = cmdr:getTheaterUpdate()
	local msg =
		string.format("== Theater Threat Status ==\n") ..
		string.format("  Force Str: %s\n",
			human.strength(update.enemy.str))..
		string.format("  Sea:    %s\n", human.threat(update.enemy.sea)) ..
		string.format("  Air:    %s\n", human.airthreat(update.enemy.air)) ..
		string.format("  ELINT:  %s\n", human.threat(update.enemy.elint))..
		string.format("  SAM:    %s\n", human.threat(update.enemy.sam)) ..
		string.format("\n== Friendly Force Info ==\n")..
		string.format("  Force Str: %s\n",
			human.strength(update.friendly.str))..
		string.format("\n== Current Active Air Missions ==\n")
	if next(update.missions) ~= nil then
		for k,v in utils.sortedpairs(update.missions) do
			msg = msg .. string.format("  %s:  %d\n", k, v)
		end
	else
		msg = msg .. "  No Active Missions\n"
	end
	msg = msg .. string.format("\nRecommended Mission Type: %s\n",
		utils.getkey(enum.missionType,
			cmdr:recommendMissionType(self.asset.ato)) or "None")
	return msg
end

local CheckPayloadCmd = class(UICmd)
function CheckPayloadCmd:__init(theater, data)
	UICmd.__init(self, theater, data)
	self.name = "CheckPayloadCmd:"..data.name
end

function CheckPayloadCmd.buildSummary(costs)
	-- print cost summary
	local msg = "== Loadout Summary:"
	for cat, id in pairs(enum.weaponCategory) do
		if id ~= enum.weaponCategory.UNRESTRICTED then
			if costs[id].current < enum.WPNINFCOST then
				msg = msg..string.format("\n  %s cost: %d / %d",
					cat, costs[id].current, costs[id].max)
			else
				msg = msg..string.format("\n  %s cost: ∞ / %d", cat, costs[id].max)
			end
		end
	end

	-- group weapons by type
	for cat, val in pairs(enum.weaponCategory) do
		if #costs[val].payload > 0 then
			msg = msg..string.format("\n\n== %s Weapons:", cat)
			for _, wpn in pairs(costs[val].payload) do
				if wpn.cost < enum.WPNINFCOST then
					-- tally the costs of each weapon
					msg = msg..string.format(
						"\n  %s        %d * %d pts = %d pts",
						wpn.name,
						wpn.count,
						wpn.cost,
						wpn.count * wpn.cost
					)
				else
					-- show special lines for forbidden weapons
					msg = msg..string.format(
						"\n  %s        %d * ∞ pts = ∞ pts (FORBIDDEN)",
						wpn.name,
						wpn.count
					)
				end
			end
		end
	end

	return msg
end

function CheckPayloadCmd:_execute(_ --[[time]], _ --[[cmdr]])
	local ok, totals = loadout.check(self.asset)
	if ok then
		return "Valid loadout, you may depart. Good luck!\n\n"
			..self.buildSummary(totals)
	else
		return "You are over budget! Re-arm before departing, or "..
			"you will be punished!\n\n"
			..self.buildSummary(totals)
	end
end


local MissionCmd = class(UICmd)
function MissionCmd:__init(theater, data)
	UICmd.__init(self, theater, data)
	self.erequest = true
end

function MissionCmd:_execute(time, cmdr)
	local msg
	local msn = cmdr:getAssigned(self.asset)
	if msn == nil then
		msg = "You do not have a mission assigned"
		if self.erequest == true then
			msg = msg .. ", use the F10 menu to request one first."
		end
		return msg
	end
	msg = self:_mission(time, cmdr, msn)
	return msg
end


local function briefingmsg(msn, asset)
	local tgtinfo = msn:getTargetInfo()
	local msg = string.format("Package: #%s\n", msn:getID())..
		string.format("IFF Codes: M1(%02o), M3(%04o)\n",
			msn.iffcodes.m1, msn.iffcodes.m3)..
		string.format("%s: %s (%s)\n",
			human.locationhdr(msn.type),
			dctutils.fmtposition(
				tgtinfo.location,
				tgtinfo.intellvl,
				asset.gridfmt),
			tgtinfo.callsign)..
		"Briefing:\n"..msn:getDescription(asset.gridfmt)
	return msg
end

local function assignedPilots(msn, assetmgr)
	local pilots = {}
	for _, name in pairs(msn:getAssigned()) do
		local asset = assetmgr:getAsset(name)
		if asset:isa(require("dct.assets.Player")) then
			local playerName = asset:getPlayerName()
			if playerName then
				local aircraft = asset:getAircraftName()
				table.insert(pilots, string.format("%s (%s)", playerName, aircraft))
			end
		end
	end
	return table.concat(pilots, "\n")
end

local MissionJoinCmd = class(MissionCmd)
function MissionJoinCmd:__init(theater, data)
	MissionCmd.__init(self, theater, data)
	self.name = "MissionJoinCmd:"..data.name
	self.missioncode = data.missioncode
	self.assetmgr = theater:getAssetMgr()
end

function MissionJoinCmd:_execute(_, cmdr)
	local missioncode = self.missioncode or self.asset.scratchpad or 0
	local msn = cmdr:getAssigned(self.asset)
	local msg

	if msn then
		msg = string.format("You have mission %s already assigned, "..
			"use the F10 Menu to abort first.", msn:getID())
		return msg
	end

	msn = cmdr:getMission(missioncode)
	if msn == nil then
		msg = string.format("No mission of ID(%s) available, use"..
			" scratch pad to set id.", tostring(missioncode))
	else
		msn:addAssigned(self.asset)
		msg = string.format("Mission %s assigned, use F10 menu "..
			"to see this briefing again\n", msn:getID())
		msg = msg..briefingmsg(msn, self.asset)
		msg = msg.."\n\nAssigned Pilots:\n"..assignedPilots(msn, self.assetmgr)
		human.drawTargetIntel(msn, self.asset.groupId, false)
	end
	return msg
end

local MissionRqstCmd = class(MissionCmd)
function MissionRqstCmd:__init(theater, data)
	MissionCmd.__init(self, theater, data)
	self.name = "MissionRqstCmd:"..data.name
	self.missiontype = data.value
	self.displaytime = 120
	self.assetmgr = theater:getAssetMgr()
end

function MissionRqstCmd:_execute(_, cmdr)
	local msn = cmdr:getAssigned(self.asset)
	local msg

	if msn then
		msg = string.format("You have mission %s already assigned, "..
			"use the F10 Menu to abort first.", msn:getID())
		return msg
	end

	msn = cmdr:requestMission(self.asset.name, self.missiontype)
	if msn == nil then
		msg = string.format("No %s missions available.",
			human.missiontype(self.missiontype))
	else
		msg = string.format("Mission %s assigned, use F10 menu "..
			"to see this briefing again\n", msn:getID())
		msg = msg..briefingmsg(msn, self.asset)
		msg = msg.."\n\nAssigned Pilots:\n"..assignedPilots(msn, self.assetmgr)
		human.drawTargetIntel(msn, self.asset.groupId, false)
	end
	return msg
end


local MissionBriefCmd = class(MissionCmd)
function MissionBriefCmd:__init(theater, data)
	MissionCmd.__init(self, theater, data)
	self.name = "MissionBriefCmd:"..data.name
	self.displaytime = 120
end

function MissionBriefCmd:_mission(_, _, msn)
	return briefingmsg(msn, self.asset)
end


local MissionStatusCmd = class(MissionCmd)
function MissionStatusCmd:__init(theater, data)
	MissionCmd.__init(self, theater, data)
	self.name = "MissionStatusCmd:"..data.name
	self.assetmgr = theater:getAssetMgr()
end

function MissionStatusCmd:_mission(_, _, msn)
	local msg
	local missiontime = timer.getAbsTime()
	local tgtinfo     = msn:getTargetInfo()
	local timeout     = msn:getTimeout()
	local minsleft    = (timeout - missiontime)
	if minsleft < 0 then
		minsleft = 0
	end
	minsleft = minsleft / 60

	msg = string.format("Mission State: %s\n", msn:getStateName())..
		string.format("Package: %s\n", msn:getID())..
		string.format("Timeout: %s (in %d mins)\n",
			os.date("%F %Rz", dctutils.zulutime(timeout)),
			minsleft)..
		string.format("BDA: %d%% complete\n\n", tgtinfo.status)..
		string.format("Assigned Pilots:\n")..assignedPilots(msn, self.assetmgr)

	return msg
end


local MissionAbortCmd = class(MissionCmd)
function MissionAbortCmd:__init(theater, data)
	MissionCmd.__init(self, theater, data)
	self.name = "MissionAbortCmd:"..data.name
	self.erequest = false
	self.reason   = data.value
end

function MissionAbortCmd:_mission(_ --[[time]], _, msn)
	local msgs = {
		[enum.missionAbortType.ABORT] =
			"aborted",
		[enum.missionAbortType.COMPLETE] =
			"completed",
		[enum.missionAbortType.TIMEOUT] =
			"timed out",
	}
	local msg = msgs[self.reason]
	if msg == nil then
		msg = "aborted - unknown reason"
	end
	human.removeIntel(msn, self.asset.groupId)
	return string.format("Mission %s %s",
		msn:abort(self.asset),
		msg)
end


local MissionRolexCmd = class(MissionCmd)
function MissionRolexCmd:__init(theater, data)
	MissionCmd.__init(self, theater, data)
	self.name = "MissionRolexCmd:"..data.name
	self.rolextime = data.value
end

function MissionRolexCmd:_mission(_, _, msn)
	return string.format("+%d mins added to mission timeout",
		msn:addTime(self.rolextime)/60)
end


local MissionCheckinCmd = class(MissionCmd)
function MissionCheckinCmd:__init(theater, data)
	self.name = "MissionCheckinCmd:"..data.name
	MissionCmd.__init(self, theater, data)
end

function MissionCheckinCmd:_mission(time, _, msn)
	msn:checkin(time)
	return string.format("on-station received")
end


local MissionCheckoutCmd = class(MissionCmd)
function MissionCheckoutCmd:__init(theater, data)
	MissionCmd.__init(self, theater, data)
	self.name = "MissionCheckoutCmd:"..data.name
end

function MissionCheckoutCmd:_mission(time, _, msn)
	return string.format("off-station received, vul time: %d",
		msn:checkout(time))
end

local cmds = {
	[enum.uiRequestType.THEATERSTATUS]   = TheaterUpdateCmd,
	[enum.uiRequestType.MISSIONREQUEST]  = MissionRqstCmd,
	[enum.uiRequestType.MISSIONBRIEF]    = MissionBriefCmd,
	[enum.uiRequestType.MISSIONSTATUS]   = MissionStatusCmd,
	[enum.uiRequestType.MISSIONABORT]    = MissionAbortCmd,
	[enum.uiRequestType.MISSIONROLEX]    = MissionRolexCmd,
	[enum.uiRequestType.MISSIONCHECKIN]  = MissionCheckinCmd,
	[enum.uiRequestType.MISSIONCHECKOUT] = MissionCheckoutCmd,
	[enum.uiRequestType.SCRATCHPADGET]   = ScratchPadDisplay,
	[enum.uiRequestType.SCRATCHPADSET]   = ScratchPadSet,
	[enum.uiRequestType.CHECKPAYLOAD]    = CheckPayloadCmd,
	[enum.uiRequestType.MISSIONJOIN]     = MissionJoinCmd,
}

return cmds
