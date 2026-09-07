--!strict
-- The action boundary has no yielding operations. Callers provide character facts,
-- never balances, prices or rewards, and persist the resulting complete record.
type ConfigData = {
	MaxPlayers: number,
	InteractionDistance: number,
	EventDuration: number,
	EventCooldown: number,
	RepairCooldown: number,
	EventReward: { [string]: number },
	ProjectOrder: { string },
	Resources: { [string]: { label: string, yield: number, cooldown: number } },
	Projects: { [string]: { label: string, cost: { [string]: number }, prerequisite: string? } },
	Nodes: { [string]: { kind: string, prerequisite: string? } },
	RepairStations: { [string]: any },
}

-- Resolve Roblox's environment only at module startup; the domain also runs in
-- the standalone Luau CLI without injecting fake game services into its tests.
local runtimeGame = (getfenv() :: any).game
local runtimeRequire: any = require
local Config: ConfigData = if runtimeGame ~= nil
	then runtimeRequire(runtimeGame:GetService("ReplicatedStorage").Shared.Config)
	else require("../shared/Config") :: any

export type Record = {
	schemaVersion: number,
	ownerId: number,
	stockpile: { [string]: number },
	projects: { [string]: boolean },
	tutorialStage: number,
	nextEventAt: number,
	eventSerial: number,
	lastRewardEvent: number,
}

export type Event = {
	phase: string,
	endsAt: number,
	progress: number,
	required: number,
	serial: number,
}

export type Result = { ok: boolean, message: string, changed: boolean? }

type State = {
	ownerId: number,
	record: Record,
	helpers: { [number]: boolean },
	accepting: boolean,
	event: Event?,
	_nodes: { [string]: number },
	_repairs: { [number]: number },
}

local Island = {}
Island.__index = Island
export type Island = typeof(setmetatable({} :: State, Island))

local MAX_INTEGER = 9007199254740991

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer(value: any): boolean
	return finite(value) and math.abs(value) <= MAX_INTEGER and value % 1 == 0
end

local function userId(value: any): boolean
	-- Studio's multiplayer test users have negative IDs.
	return integer(value) and value ~= 0
end

local function validTime(value: any): boolean
	return finite(value) and value >= 0 and value <= MAX_INTEGER
end

local function denied(message: string): Result
	return { ok = false, message = message, changed = false }
end

local function accepted(message: string): Result
	return { ok = true, message = message, changed = true }
end

local function copyRecord(record: Record): Record
	return {
		schemaVersion = record.schemaVersion,
		ownerId = record.ownerId,
		stockpile = { wood = record.stockpile.wood, stone = record.stockpile.stone },
		projects = {
			campfire = record.projects.campfire,
			bridge = record.projects.bridge,
			beacon = record.projects.beacon,
		},
		tutorialStage = record.tutorialStage,
		nextEventAt = record.nextEventAt,
		eventSerial = record.eventSerial,
		lastRewardEvent = record.lastRewardEvent,
	}
end

function Island.defaultRecord(ownerId: number): Record
	assert(userId(ownerId), "Island owner must be a nonzero integer user ID")
	return {
		schemaVersion = 1,
		ownerId = ownerId,
		stockpile = { wood = 0, stone = 0 },
		projects = { campfire = false, bridge = false, beacon = false },
		tutorialStage = 0,
		nextEventAt = 0,
		eventSerial = 0,
		lastRewardEvent = 0,
	}
end

function Island.validateRecord(record: any, ownerId: number): (Record?, string?)
	if not userId(ownerId) or type(record) ~= "table" or record.ownerId ~= ownerId then
		return nil, "Island record has an invalid owner."
	end
	if record.schemaVersion ~= 1 then
		return nil, "Island save version is unsupported."
	end
	if type(record.stockpile) ~= "table" or type(record.projects) ~= "table" then
		return nil, "Island record is missing its stockpile or projects."
	end
	for kind in Config.Resources do
		if not integer(record.stockpile[kind]) or record.stockpile[kind] < 0 then
			return nil, "Island stockpile is invalid."
		end
	end
	for projectId, project in Config.Projects do
		if type(record.projects[projectId]) ~= "boolean" then
			return nil, "Island project progress is invalid."
		end
		if record.projects[projectId] and project.prerequisite and not record.projects[project.prerequisite] then
			return nil, "Island project prerequisites are inconsistent."
		end
	end
	if not integer(record.tutorialStage) or record.tutorialStage < 0 or record.tutorialStage > 5 then
		return nil, "Island tutorial progress is invalid."
	end
	if not validTime(record.nextEventAt) then
		return nil, "Island event cooldown is invalid."
	end
	if
		not integer(record.eventSerial)
		or record.eventSerial < 0
		or not integer(record.lastRewardEvent)
		or record.lastRewardEvent < 0
		or record.lastRewardEvent > record.eventSerial
	then
		return nil, "Island event receipt is invalid."
	end
	return copyRecord(record), nil
end

function Island.new(ownerId: number, record: any?): Island
	local checked, reason =
		Island.validateRecord(if record == nil then Island.defaultRecord(ownerId) else record, ownerId)
	assert(checked, reason or "Invalid island record")
	local state: State = {
		ownerId = ownerId,
		record = checked,
		helpers = {},
		accepting = true,
		event = nil,
		_nodes = {},
		_repairs = {},
	}
	return setmetatable(state, Island)
end

function Island.canEdit(self: Island, actorId: any): boolean
	return self.accepting and userId(actorId) and (actorId == self.ownerId or self.helpers[actorId] == true)
end

function Island.setHelper(self: Island, actorId: any, allowed: any): boolean
	if not userId(actorId) or actorId == self.ownerId or type(allowed) ~= "boolean" then
		return false
	end
	if not allowed then
		self.helpers[actorId] = nil
		return true
	end
	if not self.accepting then
		return false
	end
	local count = 0
	for _ in self.helpers do
		count += 1
	end
	if count >= Config.MaxPlayers - 1 and not self.helpers[actorId] then
		return false
	end
	self.helpers[actorId] = true
	return true
end

function Island.close(self: Island)
	self.accepting = false
	table.clear(self.helpers)
	if self.event and self.event.phase == "active" then
		self.event = nil
	end
	table.clear(self._repairs)
end

function Island.snapshot(self: Island, _now: number): any
	local result: any = copyRecord(self.record)
	result.accepting = self.accepting
	result.helpers = {}
	for helper in self.helpers do
		table.insert(result.helpers, helper)
	end
	table.sort(result.helpers)
	result.nodes = {}
	for nodeId in Config.Nodes do
		result.nodes[nodeId] = self._nodes[nodeId] or 0
	end
	result.event = if self.event then table.clone(self.event) else nil
	return result
end

local function finishEvent(self: Island, success: boolean, now: number)
	local event = self.event
	if not event or event.phase ~= "active" then
		return
	end
	if success and self.record.lastRewardEvent < event.serial then
		-- Receipt and supplies are part of the same no-yield record mutation.
		for kind, amount in Config.EventReward do
			self.record.stockpile[kind] += amount
		end
		self.record.lastRewardEvent = event.serial
		self.record.tutorialStage = math.max(self.record.tutorialStage, 5)
	end
	event.phase = if success then "success" else "failed"
	self.record.nextEventAt = now + Config.EventCooldown
	table.clear(self._repairs)
end

function Island.act(self: Island, actorId: any, action: any, now: any, context: any): Result
	if not self:canEdit(actorId) then
		return denied("This island is closed or you do not have permission to help.")
	end
	if
		type(action) ~= "table"
		or type(action.kind) ~= "string"
		or not validTime(now)
		or now > MAX_INTEGER - Config.EventDuration - Config.EventCooldown
	then
		return denied("Invalid action.")
	end
	if
		type(context) ~= "table"
		or context.alive ~= true
		or not finite(context.distance)
		or context.distance < 0
		or context.distance > Config.InteractionDistance
	then
		return denied("Move closer to the target with your character to interact.")
	end
	if action.kind == "harvest" then
		local node = if type(action.target) == "string" then Config.Nodes[action.target] else nil
		if not node then
			return denied("Unknown resource node.")
		end
		if node.prerequisite and not self.record.projects[node.prerequisite] then
			return denied("Build the bridge before gathering stone.")
		end
		if now < (self._nodes[action.target] or 0) then
			return denied("This resource is replenishing. Try another node.")
		end
		local resource = Config.Resources[node.kind]
		if self.record.stockpile[node.kind] > MAX_INTEGER - resource.yield then
			return denied("The island stockpile is full.")
		end
		self.record.stockpile[node.kind] += resource.yield
		self._nodes[action.target] = now + resource.cooldown
		self.record.tutorialStage = math.max(self.record.tutorialStage, 1)
		return accepted("Gathered " .. tostring(resource.yield) .. " " .. resource.label .. " for this island.")
	elseif action.kind == "build" then
		local project = if type(action.target) == "string" then Config.Projects[action.target] else nil
		if not project then
			return denied("Unknown building site.")
		end
		if self.record.projects[action.target] then
			return denied("This project is already complete.")
		end
		if project.prerequisite and not self.record.projects[project.prerequisite] then
			return denied("Complete " .. Config.Projects[project.prerequisite].label .. " first.")
		end
		for kind, cost in project.cost do
			if self.record.stockpile[kind] < cost then
				return denied("Gather more " .. Config.Resources[kind].label .. " for " .. project.label .. ".")
			end
		end
		for kind, cost in project.cost do
			self.record.stockpile[kind] -= cost
		end
		self.record.projects[action.target] = true
		for index, projectId in Config.ProjectOrder do
			if projectId == action.target then
				self.record.tutorialStage = math.max(self.record.tutorialStage, index + 1)
			end
		end
		return accepted(project.label .. " completed!")
	elseif action.kind == "startEvent" then
		if actorId ~= self.ownerId then
			return denied("Only the island owner can start the storm.")
		end
		if action.target ~= nil and action.target ~= "beacon" then
			return denied("Unknown storm beacon.")
		end
		if not self.record.projects.beacon then
			return denied("Complete the Storm Beacon to unlock the storm challenge.")
		end
		if self.event and self.event.phase == "active" then
			return denied("A storm is already in progress.")
		end
		if now < self.record.nextEventAt then
			return denied("The storm challenge is cooling down.")
		end
		local participants = if context.participants == nil then 1 else context.participants
		if not finite(participants) then
			return denied("Invalid storm participants.")
		end
		if self.record.eventSerial >= MAX_INTEGER then
			return denied("The storm event counter is full.")
		end
		participants = math.clamp(math.floor(participants), 1, Config.MaxPlayers)
		self.record.eventSerial += 1
		self.record.nextEventAt = now + Config.EventDuration + Config.EventCooldown
		self.event = {
			phase = "active",
			endsAt = now + Config.EventDuration,
			progress = 0,
			required = 8 + 4 * participants,
			serial = self.record.eventSerial,
		}
		table.clear(self._repairs)
		return accepted("Storm incoming! Repair the marked stations together.")
	elseif action.kind == "repair" then
		if type(action.target) ~= "string" or not Config.RepairStations[action.target] then
			return denied("Unknown repair station.")
		end
		local event = self.event
		if not event or event.phase ~= "active" or now >= event.endsAt then
			return denied("There is no active storm to repair.")
		end
		if now < (self._repairs[actorId] or 0) then
			return denied("Catch your breath before repairing again.")
		end
		if event.progress + 1 >= event.required then
			if self.record.lastRewardEvent >= event.serial then
				return denied("This storm has already been rewarded.")
			end
			for kind, amount in Config.EventReward do
				if self.record.stockpile[kind] > MAX_INTEGER - amount then
					return denied("Make room in the island stockpile before completing repairs.")
				end
			end
		end
		self._repairs[actorId] = now + Config.RepairCooldown
		event.progress += 1
		if event.progress >= event.required then
			finishEvent(self, true, now)
			return accepted("Storm weathered! Your island earned bonus supplies.")
		end
		return accepted("Station repaired! Keep going.")
	end
	return denied("Unknown action.")
end

function Island.tick(self: Island, now: number): boolean
	if not validTime(now) then
		return false
	end
	local changed = false
	for nodeId, availableAt in self._nodes do
		if now >= availableAt then
			self._nodes[nodeId] = nil
			changed = true
		end
	end
	local event = self.event
	if event and event.phase == "active" and now >= event.endsAt then
		finishEvent(self, false, event.endsAt)
		changed = true
	end
	if self.event and self.event.phase ~= "active" and now >= self.record.nextEventAt then
		self.event = nil
		changed = true
	end
	return changed
end

return Island
