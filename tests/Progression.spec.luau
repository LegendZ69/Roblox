--!strict
-- Milestone 2 acceptance: all progression requests use the production session,
-- island rules and persistence boundary. Only time, character facts and storage
-- transport are supplied by the test fixture; no Roblox engine is simulated.
local Island = require("../src/server/Island")
local Persistence = require("../src/server/Persistence")
local Session = require("../src/server/Session")

local function equal(actual: any, expected: any, message: string)
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function same(actual: any, expected: any, path: string)
	if type(expected) ~= "table" then
		equal(actual, expected, path)
		return
	end
	equal(type(actual), "table", path)
	for key, value in expected do
		same(actual[key], value, path .. "." .. tostring(key))
	end
	for key in actual do
		assert(expected[key] ~= nil, path .. " has unexpected key " .. tostring(key))
	end
end

local sessionSerial = 0

local function rig(records: any?, now: number?): any
	sessionSerial += 1
	local h: any = { records = records or {}, now = now or 100, clock = 0, models = {}, lastSave = now or 100 }
	local adapter = {}
	function adapter:update(key: string, transform: any): (boolean, any)
		local proposal = transform(h.records[key])
		if proposal ~= nil then
			h.records[key] = proposal
		end
		return true, proposal
	end
	h.persistence = Persistence.new(adapter, {
		sessionId = "progression-" .. tostring(sessionSerial),
		now = function()
			return h.now
		end,
		leaseSeconds = 120,
	})
	h.session = Session.new({
		now = function()
			return h.now
		end,
		clock = function()
			return h.clock
		end,
		maxPlayers = 4,
		island = function(ownerId: number): any
			return h.models[ownerId]
		end,
		isOwned = function(ownerId: number): boolean
			return h.persistence:isOwned(ownerId)
		end,
		alive = function(_userId: number): boolean
			return true
		end,
		facts = function(_userId: number, _ownerId: number, _action: any): any
			return { distance = 2, alive = true }
		end,
		move = function(_userId: number, _ownerId: number?) end,
		notice = function(_userId: number, _message: string, _ok: boolean) end,
		changed = function(_ownerId: number) end,
		freeze = function(_ownerId: number)
			error("Acceptance fixture unexpectedly lost its persistence lease")
		end,
		sync = function(_userId: number) end,
		broadcast = function() end,
	})
	function h.add(self: any, userId: number)
		assert(self.session:add(userId, "Player " .. tostring(userId)))
		local record, problem = self.persistence:load(userId, Island.defaultRecord(userId))
		assert(record, tostring(problem))
		self.models[userId] = Island.new(userId, record)
	end
	function h.act(self: any, actorId: number, kind: string, target: string?, otherId: number?): boolean
		self.clock += 1
		return self.session:request(actorId, { kind = kind, target = target, userId = otherId })
	end
	function h.gather(self: any, actors: { number }, nodeId: string, count: number)
		for index = 1, count do
			self.now += 8
			-- Exercise actual lease renewal throughout the entire building loop.
			if self.now - self.lastSave >= 30 then
				for ownerId, model in self.models do
					assert(self.persistence:save(ownerId, model.record))
				end
				self.lastSave = self.now
			end
			assert(
				self:act(actors[(index - 1) % #actors + 1], "harvest", nodeId),
				"Configured supplies must be obtainable"
			)
		end
	end
	function h.invite(self: any, ownerId: number, helperId: number)
		assert(self:act(ownerId, "invite", nil, helperId))
		assert(self:act(helperId, "acceptInvite", nil, ownerId))
		equal(self.session:current(helperId), ownerId, "accepted helper joins the host island")
	end
	function h.shutdown(self: any)
		for ownerId, model in self.models do
			model:close()
			self.session:remove(ownerId)
			assert(self.persistence:release(ownerId, model.record), "Complete progress must be acknowledged on release")
		end
	end
	return h
end

local function rejectsUnchanged(h: any, actorId: number, kind: string, target: string)
	local before = h.models[101]:snapshot(h.now)
	equal(h:act(actorId, kind, target), false, "unavailable progression action is rejected")
	same(h.models[101]:snapshot(h.now), before, "rejection preserves all host state")
end

local function resumeOwner(h: any): any
	local before = h.models[101].record
	h:shutdown()
	local resumed = rig(h.records, h.now + 1)
	resumed:add(101)
	same(resumed.models[101].record, before, "checkpoint survives fresh session acquisition")
	equal(#resumed.models[101]:snapshot(resumed.now).helpers, 0, "temporary permissions are never saved")
	return resumed
end

return function()
	local solo = rig()
	solo:add(101)
	rejectsUnchanged(solo, 101, "harvest", "stone1")
	solo:gather({ 101 }, "wood1", 4)
	assert(solo:act(101, "build", "campfire"))
	solo = resumeOwner(solo)
	equal(solo.models[101].record.tutorialStage, 2, "campfire checkpoint resumes the bridge objective")
	rejectsUnchanged(solo, 101, "harvest", "stone1")
	solo:gather({ 101 }, "wood1", 10)
	assert(solo:act(101, "build", "bridge"))
	solo = resumeOwner(solo)
	equal(solo.models[101].record.tutorialStage, 3, "bridge checkpoint resumes the beacon objective")
	solo:gather({ 101 }, "stone1", 10)
	solo:gather({ 101 }, "wood1", 14)
	assert(solo:act(101, "build", "beacon"))
	solo = resumeOwner(solo)
	same(solo.models[101].record.projects, { campfire = true, bridge = true, beacon = true }, "all projects resume")
	same(solo.models[101].record.stockpile, { wood = 2, stone = 0 }, "solo loop spends exactly 82 wood and 20 stone")
	equal(solo.models[101].record.tutorialStage, 4, "beacon checkpoint resumes the storm objective")
	assert(solo:act(101, "startEvent"), "reloaded beacon unlocks the next milestone")
	print("PASS Progression: solo campfire, bridge, stone and beacon resume through fresh persistence sessions")

	local team = rig()
	for _, userId in { 101, 202, 303 } do
		team:add(userId)
	end
	team:invite(101, 202)
	team:invite(101, 303)
	team:gather({ 101, 202, 303 }, "wood1", 4)
	assert(team:act(202, "build", "campfire"))
	team:gather({ 303, 202, 101 }, "wood2", 10)
	assert(team:act(303, "build", "bridge"))
	team:gather({ 202, 303, 101 }, "stone1", 10)
	team:gather({ 303, 101, 202 }, "wood3", 14)
	assert(team:act(202, "build", "beacon"))
	rejectsUnchanged(team, 303, "build", "beacon")
	for _, helperId in { 202, 303 } do
		same(
			team.models[helperId].record,
			Island.defaultRecord(helperId),
			"helper keeps an independent personal island"
		)
	end
	team = resumeOwner(team)
	same(team.models[101].record.stockpile, { wood = 2, stone = 0 }, "all helper purchases debit only the host")
	equal(team.models[101].record.projects.beacon, true, "host resumes a helper-built beacon")
	for _, helperId in { 202, 303 } do
		team:add(helperId)
		same(
			team.models[helperId].record,
			Island.defaultRecord(helperId),
			"freshly loaded helper save is not overwritten"
		)
	end
	print("PASS Progression: owner and two consented helpers complete the whole loop without transferring ownership")

	local ordered = rig()
	ordered:add(101)
	ordered:add(202)
	ordered:invite(101, 202)
	ordered:gather({ 101, 202 }, "wood1", 28)
	rejectsUnchanged(ordered, 202, "build", "beacon")
	rejectsUnchanged(ordered, 202, "build", "bridge")
	rejectsUnchanged(ordered, 202, "harvest", "stone1")
	assert(ordered:act(101, "build", "campfire"))
	rejectsUnchanged(ordered, 202, "build", "campfire")
	rejectsUnchanged(ordered, 202, "build", "beacon")
	assert(ordered:act(202, "build", "bridge"))
	rejectsUnchanged(ordered, 101, "build", "bridge")
	rejectsUnchanged(ordered, 202, "build", "beacon")
	ordered:gather({ 101, 202 }, "stone2", 9)
	rejectsUnchanged(ordered, 202, "build", "beacon")
	equal(ordered.models[101].record.stockpile.wood, 42, "one missing stone yield cannot partially spend wood")
	ordered:gather({ 202 }, "stone2", 1)
	assert(ordered:act(202, "build", "beacon"))
	rejectsUnchanged(ordered, 101, "build", "beacon")
	same(ordered.models[101].record.stockpile, { wood = 2, stone = 0 }, "repeated purchases never overspend")
	print("PASS Progression: prerequisite, exact-resource and repeated owner/helper purchase guards remain atomic")

	assert(team:act(202, "visit", nil, 101))
	rejectsUnchanged(team, 202, "harvest", "stone1")
	team:invite(101, 202)
	assert(team:act(202, "harvest", "stone1"), "reloaded bridge unlocks stone for newly consented helpers")
	rejectsUnchanged(team, 101, "harvest", "stone1")
	assert(team:act(101, "revoke", nil, 202))
	assert(team:act(202, "visit", nil, 101))
	rejectsUnchanged(team, 202, "harvest", "stone2")
	equal(team.models[101].record.stockpile.stone, 2, "one accepted stone harvest adds exactly the configured yield")
	print(
		"PASS Progression: stone unlock survives reload while permission, shared depletion and revocation still apply"
	)
end
