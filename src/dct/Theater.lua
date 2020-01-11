--[[
-- SPDX-License-Identifier: LGPL-3.0
--
-- Defines the Theater class.
--]]

require("os")
require("io")
require("lfs")
local class       = require("libs.class")
local utils       = require("libs.utils")
local containers  = require("libs.containers")
local json        = require("libs.json")
local enum        = require("dct.enum")
local dctutils    = require("dct.utils")
local uicmds      = require("dct.ui.cmds")
local uimenu      = require("dct.ui.groupmenu")
local Observable  = require("dct.Observable")
local Region      = require("dct.Region")
local AssetManager= require("dct.AssetManager")
local Commander   = require("dct.ai.Commander")
local Command     = require("dct.Command")
local Logger      = require("dct.Logger").getByName("Theater")
local Profiler    = require("dct.Profiler").getProfiler()
local settings    = _G.dct.settings

--[[
--  Theater class
--    base class that reads in all region and template information
--    and provides a base interface for manipulating data at a theater
--    level.
--
--  Storage of theater:
--		goals = {
--			<goalname> = State(),
--		},
--		regions = {
--			<regionname> = Region(),
--		},
--]]
local Theater = class(Observable)
function Theater:__init()
	Observable.__init(self)
	Profiler:profileStart("Theater:init()")
	self.savestatefreq = 7*60 -- seconds
	self.cmdmindelay   = 8/settings.schedfreq
	self.uicmddelay    = self.cmdmindelay
	self:setCmdFreq(settings.schedfreq)
	self.complete  = false
	self.statef    = false
	self.regions   = {}
	self.cmdq      = containers.PriorityQueue()
	self.ctime     = timer.getTime()
	self.ltime     = 0
	self.assetmgr  = AssetManager(self)
	self.cmdrs     = {}
	self.playergps = {}

	for _, val in pairs(coalition.side) do
		self.cmdrs[val] = Commander(self, val)
	end

	self:_loadGoals()
	self:_loadRegions()
	self:_loadOrGenerate()
	uimenu(self)
	self:queueCommand(100, Command(self.export, self))
	Profiler:profileStop("Theater:init()")
end

-- a description of the world state that signifies a particular side wins
-- TODO: create a common function that will read in a lua file like below
-- verify it was read correctly, contains the token expected, returns the
-- token on the stack and clears the global token space
function Theater:_loadGoals()
	local goalpath = settings.theaterpath..utils.sep.."theater.goals"
	local rc = pcall(dofile, goalpath)
	assert(rc, "failed to parse: theater goal file, '" ..
			goalpath .. "' path likely doesn't exist")
	assert(theatergoals ~= nil, "no theatergoals structure defined")

	self.goals = {}
	-- TODO: translate goal definitions written in the lua files to any
	-- needed internal state.
	-- Theater goals are goals written in a success format, meaning the
	-- first side to complete all their goals wins
	theatergoals = nil
end

function Theater:_loadRegions()
	for filename in lfs.dir(settings.theaterpath) do
		if filename ~= "." and filename ~= ".." and
			filename ~= ".git" then
			local fpath = settings.theaterpath..utils.sep..filename
			local fattr = lfs.attributes(fpath)
			if fattr.mode == "directory" then
				local r = Region(fpath)
				assert(self.regions[r.name] == nil, "duplicate regions " ..
					"defined for theater: " .. settings.theaterpath)
				self.regions[r.name] = r
			end
		end
	end
end

function Theater:setCmdFreq(freq)
	self.cmdqfreq    = 1/freq
end

local function isStateValid(state)
	if state == nil then
		Logger:warn("isStateValid() - state object nil")
		return false
	end

	if state.complete == true then
		Logger:warn("isStateValid() - theater goals were completed")
		return false
	end

	if state.theater ~= env.mission.theatre then
		Logger:warn(string.format("isStateValid() - wrong theater; "..
			"state: '%s'; mission: '%s'", state.theater, env.mission.theatre))
		return false
	end

	if state.sortie ~= env.getValueDictByKey(env.mission.sortie) then
		Logger:warn(string.format("isStateValid() - wrong sortie; "..
			"state: '%s'; mission: '%s'", state.sortie,
			env.getCalueDictByKey(env.mission.sortie)))
		return false
	end

	return true
end

function Theater:_initFromState()
	self.statef = true
	self:getAssetMgr():unmarshal(self.statetbl.assetmgr)
end

function Theater:_loadOrGenerate()
	local statefile = io.open(settings.statepath)

	if statefile ~= nil then
		self.statetbl = json:decode(statefile:read("*all"))
		statefile:close()
	end

	if isStateValid(self.statetbl) then
		Logger:info("restoring saved state")
		self:_initFromState()
	else
		Logger:info("saved state was invalid, generating new theater")
		self:generate()
	end
	self.statetbl = nil
end

function Theater:export(_)
	local statefile
	local msg

	statefile, msg = io.open(settings.statepath, "w+")

	if statefile == nil then
		Logger:error("export() - unable to open '"..
			settings.statepath.."'; msg: "..tostring(msg))
		return self.savestatefreq
	end

	local exporttbl = {
		["complete"] = self.complete,
		["date"]     = os.date("*t", dctutils.time(timer.getAbsTime())),
		["theater"]  = env.mission.theatre,
		["sortie"]   = env.getValueDictByKey(env.mission.sortie),
		["assetmgr"] = self:getAssetMgr():marshal(),
	}

	statefile:write(json:encode_pretty(exporttbl))
	statefile:flush()
	statefile:close()
	return self.savestatefreq
end

function Theater:generate()
	for _, r in pairs(self.regions) do
		r:generate(self.assetmgr)
	end
end

function Theater:getAssetMgr()
	return self.assetmgr
end

function Theater:getCommander(side)
	return self.cmdrs[side]
end

function Theater:playerRequest(data)
	Logger:debug("playerRequest(); Received player request: "..
		json:encode_pretty(data))

	if self.playergps[data.name].cmdpending == true then
		Logger:debug("playerRequest(); request pending, ignoring")
		trigger.action.outTextForGroup(data.id,
			"F10 request already pending, please wait.", 20, true)
		return
	end

	local cmd = uicmds[data.type](self, data)
	self:queueCommand(self.uicmddelay, cmd)
	self.playergps[data.name].cmdpending = true
end

function Theater:getATORestrictions(side, unittype)
	local unitATO = settings.atorestrictions[side][unittype]

	if unitATO == nil then
		unitATO = enum.missionType
	end
	return unitATO
end

--[[
-- do not worry about command priority right now
-- command queue discussion,
--  * central Q
--  * priority ordered in both priority and time
--     priority = time * 128 + P
--     time = (priority - P) / 128
--
--    This allows things of higher priority to be executed first
--    but things that need to be executed at around the same time
--    to also occur.
--
-- delay - amount of delay in seconds before the command is run
-- cmd   - the command to be run
--]]
function Theater:queueCommand(delay, cmd)
	if delay < self.cmdmindelay then
		Logger:warn(string.format("queueCommand(); delay(%2.2f) less than "..
			"schedular minimum(%2.2f), setting to schedular minumum",
			delay, self.cmdmindelay))
		delay = self.cmdmindelay
	end
	self.cmdq:push(self.ctime + delay, cmd)
	Logger:debug("queueCommand(); cmdq size: "..self.cmdq:size())
end

function Theater:_exec(time)
	-- TODO: insert profiling hooks to count the moving average of
	-- 10 samples for how long it takes to execute a command
	self.ltime = self.ctime
	self.ctime = time

	if self.cmdq:empty() then
		return
	end

	local _, prio = self.cmdq:peek()
	if time < prio then
		return
	end

	Logger:debug("exec() - execute command")
	local cmd = self.cmdq:pop()
	local requeue = cmd:execute(time)
	if requeue ~= nil and type(requeue) == "number" then
		self:queueCommand(requeue, cmd)
	end
end

function Theater:exec(time)
	local errhandler = function(err)
		Logger:error("protected call - "..tostring(err).."\n"..
			debug.traceback())
	end
	local pcallfunc = function()
		self:_exec(time)
	end

	xpcall(pcallfunc, errhandler)
	return time + self.cmdqfreq
end

return Theater