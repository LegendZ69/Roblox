--!strict
-- Milestone acceptance through the production session, island and persistence
-- interfaces. Controlled ports supply time, character facts and durable storage;
-- they do not simulate Roblox physics, networking or client rendering.
local Session = require("../src/server/Session")
local Island = require("../src/server/Island")
local Persistence = require("../src/server/Persistence")
local Config = require("../src/shared/Config")

local function equal(actual: any, expected: any, message: string)
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local nextSession = 0
local function rig(records: any?, now: number?): any
	nextSession += 1
	local h: any = {
		now = now or 100,
		clock = 0,
		records = records or {},
		models = {},
		alive = {},
		distance = {},
		lastMove = {},
		failAfterCommit = false,
		frozen = {},
	}
	local adapter = {}
	function adapter:update(key: string, transform: any): (boolean, any)
		local committed = transform(h.records[key])
		if committed ~= nil then
			h.records[key] = committed
		end
		if h.failAfterCommit then
			return false, "response lost after storage committed"
		end
		return true, committed
	end
	h.persistence = Persistence.new(adapter, {
		sessionId = "storm-acceptance-" .. tostring(nextSession),
		now = function()
			return h.now
		end,
		leaseSeconds = Config.LeaseSeconds,
	})
	h.session = Session.new({
		now = function()
			return h.now
		end,
		clock = function()
			return h.clock
		end,
		maxPlayers = Config.MaxPlayers,
		island = function(ownerId: number): any
			return h.models[ownerId]
		end,
		isOwned = function(ownerId: number): boolean
			return h.persistence:isOwned(ownerId)
		end,
		alive = function(userId: number): boolean
			return h.alive[userId] == true
		end,
		facts = function(userId: number, _ownerId: number, _action: any): any
			return { alive = h.alive[userId] == true, distance = h.distance[userId] or 2 }
		end,
		move = function(userId: number, ownerId: number?)
			h.lastMove[userId] = ownerId
		end,
		notice = function(_userId: number, _message: string, _ok: boolean) end,
		changed = function(_ownerId: number) end,
		freeze = function(ownerId: number)
			h.frozen[ownerId] = true
			h.models[ownerId]:close()
			h.session:closeIsland(ownerId, "Island paused")
		end,
		sync = function(_userId: number) end,
		broadcast = function() end,
	})
	function h.add(self: any, userId: number)
		assert(self.session:add(userId, "Player " .. tostring(userId)))
		self.alive[userId] = true
		local initial = Island.defaultRecord(userId)
		initial.projects = { campfire = true, bridge = true, beacon = true }
		initial.tutorialStage = 4
		initial.stockpile = { wood = 7, stone = 3 }
		local record, reason = self.persistence:load(userId, initial)
		assert(record, tostring(reason))
		self.models[userId] = Island.new(userId, record)
	end
	function h.request(self: any, userId: number, action: any, promptOwnerId: number?): boolean
		self.clock += 1
		return self.session:request(userId, action, promptOwnerId)
	end
	function h.invite(self: any, userId: number)
		assert(self:request(101, { kind = "invite", userId = userId }))
		assert(self:request(userId, { kind = "acceptInvite", userId = 101 }))
	end
	function h.advanceTo(self: any, target: number)
		assert(target >= self.now)
		-- Drive the public tick/save boundaries at the configured autosave cadence
		-- so long timeout/retry scenarios retain their real 120-second leases.
		while self.now < target do
			self.now = math.min(target, self.now + Config.AutosaveSeconds)
			for ownerId, model in self.models do
				model:tick(self.now)
				if self.persistence:isOwned(ownerId) then
					assert(self.persistence:save(ownerId, model.record))
				end
			end
		end
	end
	function h.complete(self: any, crew: { number })
		local start = self.now
		local round = 0
		while self.models[101]:snapshot(self.now).event.phase == "active" do
			self:advanceTo(start + round * Config.RepairCooldown)
			for index, actorId in crew do
				if self.models[101]:snapshot(self.now).event.phase == "active" then
					assert(self:request(actorId, { kind = "repair", target = "repair" .. tostring(index % 3 + 1) }))
				end
			end
			round += 1
			assert(round <= 12, "configured workload must finish before the deadline")
		end
	end
	return h
end

local function crewRig(size: number): (any, { number })
	local h = rig()
	local crew = {}
	for index = 1, size do
		local id = 100 + index
		h:add(id)
		table.insert(crew, id)
		if id ~= 101 then
			h:invite(id)
		end
	end
	return h, crew
end

local function releaseAndReload(h: any): any
	assert(h.persistence:release(101, h.models[101].record))
	local fresh = rig(h.records, h.now)
	fresh:add(101)
	return fresh.models[101]:snapshot(fresh.now)
end

return function()
	local workloads = { 12, 16, 20, 24 }
	for size = 1, 4 do
		local h, crew = crewRig(size)
		assert(h:request(101, { kind = "startEvent", participants = 99 }))
		local started = h.models[101]:snapshot(h.now).event
		equal(started.required, workloads[size], "server-present crew selects workload")
		equal(started.endsAt, 190, "every crew gets the same ninety-second deadline")
		h:complete(crew)
		local finished = h.models[101]:snapshot(h.now)
		equal(finished.event.phase, "success", "crew completes the storm")
		equal(finished.event.progress, started.required, "repairs stop at the exact workload")
		equal(finished.stockpile.wood, 31, "one reward adds wood without consuming starting supplies")
		equal(finished.stockpile.stone, 15, "one reward adds stone")
		equal(finished.lastRewardEvent, 1, "success receives one durable identity")
		for _, actorId in crew do
			equal(h:request(actorId, { kind = "repair", target = "repair1" }), false, "late repairs cannot repay")
			if actorId ~= 101 then
				equal(h.models[actorId].record.stockpile.wood, 7, "helper wood remains personal")
				equal(h.models[actorId].record.stockpile.stone, 3, "helper stone remains personal")
			end
		end
		assert(h.persistence:save(101, h.models[101].record))
		assert(h.persistence:save(101, h.models[101].record))
		local reloaded = releaseAndReload(h)
		equal(reloaded.stockpile.wood, 31, "repeated saves do not reissue reward after fresh load")
		equal(reloaded.lastRewardEvent, 1, "one reward receipt survives fresh load")
		print("PASS Storm: " .. tostring(size) .. "-player workload completes with one host-only persisted reward")
	end

	for size = 1, 4 do
		local h, crew = crewRig(size)
		assert(h:request(101, { kind = "startEvent" }))
		assert(h:request(crew[#crew], { kind = "repair", target = "repair1" }))
		h:advanceTo(189)
		-- Delivery at the exact deadline precedes the next periodic tick.
		h.now = 190
		equal(h:request(101, { kind = "repair", target = "repair1" }), false, "deadline repairs cannot win")
		equal(h.models[101]:tick(h.now), true, "deadline resolves incomplete progress")
		equal(h.models[101]:tick(h.now), false, "failure is resolved only once")
		local failed = h.models[101]:snapshot(h.now)
		equal(failed.event.phase, "failed", "incomplete storm fails")
		equal(failed.stockpile.wood, 7, "failure does not destroy wood")
		equal(failed.stockpile.stone, 3, "failure does not destroy stone")
		equal(failed.lastRewardEvent, 0, "failure cannot mint a reward receipt")
		h:advanceTo(369)
		equal(h:request(101, { kind = "startEvent" }), false, "retry before cooldown is denied")
		h:advanceTo(370)
		assert(h:request(101, { kind = "startEvent" }))
		equal(h.models[101]:snapshot(h.now).event.serial, 2, "retry receives a new event identity")
		h:complete(crew)
		assert(h.persistence:save(101, h.models[101].record))
		local reloaded = releaseAndReload(h)
		equal(reloaded.lastRewardEvent, 2, "only successful retry is receipted after fresh load")
		equal(reloaded.stockpile.wood, 31, "failed run plus successful retry pays once after fresh load")
	end
	print("PASS Storm: all four crew sizes fail without loss, enforce the deadline and retry after cooldown")

	local changing = crewRig(4)
	assert(changing:request(102, { kind = "home" }))
	assert(changing:request(101, { kind = "revoke", userId = 103 }))
	assert(changing:request(103, { kind = "visit", userId = 101 }))
	changing.alive[104] = false
	changing.distance[101] = 100
	changing.clock += 1
	equal(
		changing.session:request(101, { kind = "startEvent", distance = 1, participants = 4 }),
		false,
		"client cannot forge beacon proximity"
	)
	changing.distance[101] = 2
	assert(changing:request(101, { kind = "startEvent", participants = 4 }))
	equal(changing.models[101]:snapshot(100).event.required, 12, "away, read-only and dead players do not count")
	equal(changing:request(103, { kind = "repair", target = "repair1" }), false, "visitor cannot repair")
	equal(changing:request(104, { kind = "repair", target = "repair1" }), false, "dead helper cannot repair")
	equal(
		changing:request(102, { kind = "repair", target = "repair1" }, 101),
		false,
		"away helper cannot use stale prompt"
	)
	changing:invite(103)
	changing.alive[104] = true
	assert(changing:request(103, { kind = "repair", target = "repair1" }))
	assert(changing:request(104, { kind = "repair", target = "repair2" }))
	equal(changing.models[101]:snapshot(100).event.required, 12, "late arrival and revival do not change workload")
	equal(
		changing:request(103, { kind = "repair", target = "repair3" }),
		false,
		"switching stations cannot evade actor cooldown"
	)
	assert(changing:request(101, { kind = "revoke", userId = 104 }))
	equal(changing.session:current(104), 104, "revoked helper returns home during storm")
	equal(
		changing:request(104, { kind = "repair", target = "repair2" }, 101),
		false,
		"revocation denies queued host repair"
	)
	changing:advanceTo(105)
	assert(changing:request(103, { kind = "repair", target = "repair3" }))
	equal(changing.models[101]:snapshot(105).event.progress, 3, "only authorized, live and timely repairs count")
	print(
		"PASS Storm: in-run arrival, revival, travel and revocation preserve fixed workload and authoritative repairs"
	)

	local departing = crewRig(2)
	assert(departing:request(101, { kind = "startEvent" }))
	assert(departing:request(102, { kind = "repair", target = "repair1" }))
	departing.session:remove(101)
	departing.models[101]:close()
	assert(departing.persistence:release(101, departing.models[101].record))
	equal(departing.session:current(102), 102, "owner departure returns helper home")
	equal(
		departing:request(102, { kind = "repair", target = "repair1" }, 101),
		false,
		"late repair cannot reach closed island"
	)
	local resumed = rig(departing.records, 101)
	resumed:add(101)
	equal(resumed.models[101]:snapshot(101).event, nil, "fresh server never resumes interrupted progress")
	equal(resumed.models[101].record.stockpile.wood, 7, "interruption does not reward or destroy supplies")
	equal(resumed.models[101].record.nextEventAt, 370, "interruption cooldown survives fresh server load")
	equal(resumed:request(101, { kind = "startEvent" }), false, "rejoining cannot bypass interrupted cooldown")
	resumed:advanceTo(370)
	assert(resumed:request(101, { kind = "startEvent" }))
	equal(resumed.models[101]:snapshot(370).event.required, 12, "temporary helpers do not survive restart")
	resumed:complete({ 101 })
	equal(resumed.models[101].record.lastRewardEvent, 2, "successful restart retry has a distinct receipt")
	print("PASS Storm: owner departure persists cancellation and cooldown before a clean solo retry")

	local ambiguous, crew = crewRig(2)
	assert(ambiguous:request(101, { kind = "startEvent" }))
	ambiguous:complete(crew)
	equal(ambiguous.models[101]:snapshot(ambiguous.now).lastRewardEvent, 1, "completed event has a receipt to save")
	ambiguous.failAfterCommit = true
	equal(
		ambiguous.persistence:save(101, ambiguous.models[101].record),
		false,
		"lost acknowledgement is not claimed saved"
	)
	equal(
		ambiguous:request(102, { kind = "repair", target = "repair1" }),
		false,
		"uncertain lease denies late completion"
	)
	equal(ambiguous.frozen[101], true, "uncertain ownership closes gameplay")
	equal(ambiguous.session:current(102), 102, "recovery returns helper home")
	local recovered = rig(ambiguous.records, ambiguous.now + Config.LeaseSeconds + 1)
	recovered:add(101)
	local restored = recovered.models[101]:snapshot(recovered.now)
	equal(restored.stockpile.wood, 31, "new lease reloads the committed reward after response loss")
	equal(restored.lastRewardEvent, 1, "new lease reloads the matching reward receipt")
	equal(restored.event, nil, "completed event cannot be replayed after storage recovery")
	equal(recovered:request(101, { kind = "repair", target = "repair1" }), false, "replayed final repair remains inert")
	equal(recovered:request(101, { kind = "startEvent" }), false, "saved successful cooldown still applies")
	recovered:advanceTo(restored.nextEventAt)
	assert(recovered:request(101, { kind = "startEvent" }))
	recovered:complete({ 101 })
	assert(recovered.persistence:save(101, recovered.models[101].record))
	local reloaded = releaseAndReload(recovered)
	equal(reloaded.stockpile.wood, 55, "two distinct completed events earn exactly two rewards after fresh load")
	equal(reloaded.lastRewardEvent, 2, "new successful event advances receipt once after fresh load")
	print("PASS Storm: ambiguous reward-save recovery preserves one receipt and permits only a later distinct reward")
end
