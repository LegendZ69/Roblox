--!strict
local Persistence = require("../src/server/Persistence")

local function equal(actual: any, expected: any, message: string)
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result: any = {}
	for key, child in pairs(value) do
		result[key] = copy(child)
	end
	return result
end

local function profile(ownerId: number): any
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

local function setup(): (any, any, any, any)
	local clock = { now = 100 }
	local adapter: any = { values = {}, writes = 0, calls = 0 }
	function adapter.update(self: any, key: string, transform: (any) -> any): (boolean, any)
		self.calls += 1
		if self.before then
			local before: any = self.before
			self.before = nil
			before(self, key)
		end
		if self.failure then
			return false, self.failure
		end
		if self.throws then
			error("transport exception")
		end
		local candidate = transform(copy(self.values[key]))
		if self.retry then
			local retry: any = self.retry
			self.retry = nil
			retry(self, key, candidate)
			candidate = transform(copy(self.values[key]))
		end
		if candidate ~= nil then
			self.values[key] = copy(candidate)
			self.writes += 1
			if self.loseAcknowledgement then
				return false, "acknowledgement lost"
			end
		end
		if self.after then
			local after: any = self.after
			self.after = nil
			after(self, key)
		end
		if self.badConfirmation then
			return true, self.badConfirmation
		end
		return true, if candidate ~= nil or self.returnCurrent then copy(self.values[key]) else nil
	end
	local function manager(sessionId: string): any
		return Persistence.new(adapter, {
			sessionId = sessionId,
			now = function()
				return clock.now
			end,
			leaseSeconds = 120,
		})
	end
	return adapter, clock, manager("server-A"), manager("server-B")
end

local function run(name: string, test: () -> ())
	test()
	print("PASS Persistence: " .. name)
end

return function()
	run("new profile loads once and all snapshots are detached", function()
		local adapter, _, manager = setup()
		local initial = profile(101)
		local loaded, reason = manager:load(101, initial)
		equal(reason, nil, "new load has no error")
		equal(loaded.stockpile.wood, 0, "new default is loaded")
		local owned, untilAt = manager:isOwned(101)
		equal(owned, true, "new profile is owned")
		equal(untilAt, 220, "lease deadline is exposed")
		loaded.stockpile.wood = 8
		initial.stockpile.stone = 17
		equal(adapter.values["island:101"].data.stockpile.wood, 0, "returned profile does not alias stored data")
		equal(adapter.values["island:101"].data.stockpile.stone, 0, "default does not alias stored data")
		local second, secondReason = manager:load(101, initial)
		equal(second, nil, "repeated load is rejected")
		equal(secondReason, "already loaded", "repeated load preserves live local ownership")
		equal(adapter.writes, 1, "repeated load does not touch storage")
	end)

	run("active session excludes a second server", function()
		local adapter, _, first, second = setup()
		assert(first:load(101, profile(101)))
		local data, reason = second:load(101, profile(101))
		equal(data, nil, "second server cannot load")
		equal(reason, "locked", "lease conflict is reported")
		equal(second:isOwned(101), false, "second server never owns profile")
		equal(adapter.writes, 1, "conflict does not overwrite")
	end)

	run("save renews and release flushes before returning profile on another server", function()
		local adapter, clock, first, second = setup()
		local data = assert(first:load(101, profile(101)))
		data.stockpile.wood = 23
		clock.now = 130
		equal(first:save(101, data), true, "save succeeds")
		equal(adapter.values["island:101"].leaseUntil, 250, "save renews lease")
		equal(adapter.values["island:101"].revision, 2, "save advances revision")
		data.projects.campfire = true
		data.stockpile.wood = 11
		equal(first:release(101, data), true, "release succeeds")
		equal(first:isOwned(101), false, "released profile is not locally owned")
		equal(adapter.values["island:101"].sessionId, "", "release clears remote session")
		equal(adapter.values["island:101"].leaseUntil, 0, "release clears deadline")
		local returned = assert(second:load(101, profile(101)))
		equal(returned.stockpile.wood, 11, "returning player keeps supplies")
		equal(returned.projects.campfire, true, "returning player keeps projects")
		equal(adapter.values["island:101"].revision, 4, "load preserves revision history")
		data.stockpile.wood = 999
		equal(adapter.values["island:101"].data.stockpile.wood, 11, "release saved a detached snapshot")
	end)

	run("expired owner cannot renew or release after a takeover", function()
		local adapter, clock, first, second = setup()
		local old = assert(first:load(101, profile(101)))
		clock.now = 220
		local current = assert(second:load(101, profile(101)))
		current.stockpile.wood = 9
		assert(second:save(101, current))
		old.stockpile.wood = 999
		equal(first:save(101, old), false, "stale save fails")
		equal(first:release(101, old), false, "stale release fails")
		equal(adapter.values["island:101"].sessionId, "server-B", "stale owner cannot unlock successor")
		equal(adapter.values["island:101"].data.stockpile.wood, 9, "successor data survives")
	end)

	run("deadline is exclusive even before another server takes over", function()
		local adapter, clock, manager = setup()
		local data = assert(manager:load(101, profile(101)))
		clock.now = 220
		local owned, deadline = manager:isOwned(101)
		equal(owned, false, "lease expires at its deadline")
		equal(deadline, 220, "first expiry observation includes known deadline")
		equal(manager:save(101, data), false, "expired session cannot self renew")
		equal(manager:release(101, data), false, "expired session cannot release")
		equal(adapter.writes, 1, "expired calls do not write")
	end)

	run("malformed stored envelopes never become a fresh profile", function()
		local malformed: { any } = {
			false,
			0,
			"corrupt",
			{},
			{ data = profile(101), sessionId = "", leaseUntil = 0, revision = -1 },
			{ data = profile(101), sessionId = "", leaseUntil = 80, revision = 1 },
			{ data = profile(101), sessionId = "other", leaseUntil = 0, revision = 1 },
			{ data = profile(101), sessionId = "", leaseUntil = 0 / 0, revision = 1 },
			{ data = profile(102), sessionId = "", leaseUntil = 0, revision = 1 },
			{ data = "wrong", sessionId = "", leaseUntil = 0, revision = 1 },
		}
		for _, envelope in ipairs(malformed) do
			local adapter, _, manager = setup()
			adapter.values["island:101"] = envelope
			local data, reason = manager:load(101, profile(101))
			equal(data, nil, "malformed data is rejected")
			equal(reason, "malformed envelope", "malformed envelope is distinguished from missing")
			equal(adapter.writes, 0, "malformed data is untouched")
		end
	end)

	run("failed and thrown loads never create or overwrite data", function()
		local adapter, _, manager = setup()
		adapter.failure = "unavailable"
		equal(manager:load(101, profile(101)), nil, "failed load has no playable data")
		equal(manager:isOwned(101), false, "failed load is not owned")
		equal(adapter.writes, 0, "failed load does not create a profile")
		adapter.failure = nil
		adapter.throws = true
		equal(manager:load(101, profile(101)), nil, "thrown load is caught")
		adapter.throws = nil
		assert(manager:load(101, profile(101)))
		equal(adapter.writes, 1, "failed operations release the busy guard")
	end)

	run("unconfirmed saves lose local ownership and cannot overwrite later", function()
		local adapter, clock, first, second = setup()
		local data = assert(first:load(101, profile(101)))
		data.stockpile.stone = 7
		adapter.loseAcknowledgement = true
		equal(first:save(101, data), false, "lost acknowledgement is a failed save")
		equal(first:isOwned(101), false, "unknown revision loses local ownership")
		adapter.loseAcknowledgement = nil
		equal(first:save(101, data), false, "failed session cannot blindly retry")
		equal(first:load(101, profile(101)), nil, "lost session cannot reacquire its own active token")
		clock.now = 221
		local recovered = assert(second:load(101, profile(101)))
		equal(recovered.stockpile.stone, 7, "committed save survives lost acknowledgement")
	end)

	run("revision and token changes reject stale saves even before local expiry", function()
		for _, field in ipairs({ "revision", "sessionId", "leaseUntil" }) do
			local adapter, _, manager = setup()
			local data = assert(manager:load(101, profile(101)))
			adapter.values["island:101"][field] = if field == "sessionId"
				then "replacement"
				else adapter.values["island:101"][field] + 1
			data.stockpile.wood = 40
			equal(manager:save(101, data), false, field .. " mismatch rejects save")
			equal(manager:isOwned(101), false, "remote mismatch drops ownership")
			equal(adapter.writes, 1, "mismatch never overwrites")
		end
	end)

	run("a retry after another session acquires a missing key cancels", function()
		local adapter, _, first, second = setup()
		adapter.retry = function(_: any, _: string, candidate: any)
			equal(candidate.sessionId, "server-A", "first callback proposed acquisition")
			assert(second:load(101, profile(101)))
		end
		local data, reason = first:load(101, profile(101))
		equal(data, nil, "retried acquisition loses to committed owner")
		equal(reason, "locked", "last callback rejection is used")
		equal(adapter.writes, 1, "only winner writes")
		equal(adapter.values["island:101"].sessionId, "server-B", "winner remains owner")
	end)

	run("save callbacks recheck expiry and ownership on every retry", function()
		local adapter, clock, first, second = setup()
		local data = assert(first:load(101, profile(101)))
		data.stockpile.wood = 99
		adapter.retry = function(_: any, _: string, _: any)
			clock.now = 220
			assert(second:load(101, profile(101)))
		end
		equal(first:save(101, data), false, "retried expired save fails")
		equal(adapter.values["island:101"].data.stockpile.wood, 0, "uncommitted snapshot is discarded")
		equal(adapter.values["island:101"].sessionId, "server-B", "new lease survives callback retry")
	end)

	run("competing release cannot clear a replacement lease on retry", function()
		local adapter, clock, first, second = setup()
		local data = assert(first:load(101, profile(101)))
		adapter.returnCurrent = true
		adapter.retry = function(_: any, _: string, candidate: any)
			equal(candidate.sessionId, "", "first callback proposed unlock")
			clock.now = 220
			assert(second:load(101, profile(101)))
		end
		equal(first:release(101, data), false, "retried release fails")
		equal(adapter.values["island:101"].sessionId, "server-B", "competing release preserves successor")
		equal(second:isOwned(101), true, "successor still owns its lease")
	end)

	run("retries receive fresh copies of the pre-yield save snapshot", function()
		local adapter, _, manager = setup()
		local data = assert(manager:load(101, profile(101)))
		data.stockpile.wood = 6
		adapter.retry = function(_: any, _: string, candidate: any)
			candidate.data.stockpile.wood = 999
			data.stockpile.wood = 777
		end
		equal(manager:save(101, data), true, "retry save succeeds")
		equal(adapter.values["island:101"].data.stockpile.wood, 6, "retry saves original copied snapshot")
		equal(adapter.values["island:101"].revision, 2, "retries advance revision only once")
	end)

	run("same-owner overlapping operations are busy while other owners proceed", function()
		local adapter, _, manager = setup()
		local data = assert(manager:load(101, profile(101)))
		data.stockpile.wood = 5
		adapter.before = function(_: any, _: string)
			coroutine.yield("paused")
		end
		local saved: boolean? = nil
		local worker = coroutine.create(function()
			saved = manager:save(101, data)
		end)
		local resumed, marker = coroutine.resume(worker)
		equal(resumed, true, "save can yield through adapter")
		equal(marker, "paused", "save is paused before transform")
		data.stockpile.wood = 20
		local released, releaseReason = manager:release(101, data)
		equal(released, false, "overlapping release fails")
		equal(releaseReason, "busy", "overlap reports busy")
		local loaded, loadReason = manager:load(101, profile(101))
		equal(loaded, nil, "overlapping load fails")
		equal(loadReason, "busy", "load reports busy")
		assert(manager:load(102, profile(102)))
		equal(coroutine.resume(worker), true, "original save resumes")
		equal(saved, true, "original save succeeds")
		equal(adapter.values["island:101"].data.stockpile.wood, 5, "pre-yield snapshot is saved")
	end)

	run("abandon fences a yielded save without touching remote storage", function()
		local adapter, _, manager = setup()
		local data = assert(manager:load(101, profile(101)))
		adapter.before = function(_: any, _: string)
			coroutine.yield()
		end
		local saved, reason: any = nil, nil
		local worker = coroutine.create(function()
			saved, reason = manager:save(101, data)
		end)
		assert(coroutine.resume(worker))
		manager:abandon(101)
		equal(manager:isOwned(101), false, "abandoned profile loses local ownership")
		assert(coroutine.resume(worker))
		equal(saved, false, "abandoned in-flight save fails")
		equal(reason, "operation abandoned", "abandon is reported")
		equal(adapter.writes, 1, "abandon never writes or unlocks")
	end)

	run("lease expiry during a yielded operation is checked before writing", function()
		local adapter, clock, manager = setup()
		local data = assert(manager:load(101, profile(101)))
		adapter.before = function(_: any, _: string)
			clock.now = 220
		end
		equal(manager:save(101, data), false, "expired in-flight save fails")
		equal(adapter.writes, 1, "in-flight expiration prevents write")
	end)

	run("late load confirmation cannot revive an expired lease", function()
		local adapter, clock, manager = setup()
		adapter.after = function(_: any, _: string)
			clock.now = 221
		end
		equal(manager:load(101, profile(101)), nil, "expired confirmation is rejected")
		equal(manager:isOwned(101), false, "expired confirmation cannot become playable")
	end)

	run("missing or mismatched confirmations do not count as successful writes", function()
		local adapter, _, manager = setup()
		local data = assert(manager:load(101, profile(101)))
		adapter.badConfirmation = copy(adapter.values["island:101"])
		equal(manager:save(101, data), false, "old returned revision fails confirmation")
		equal(manager:isOwned(101), false, "unconfirmed update cannot retain ownership")
	end)

	run("wrong-owner and cyclic snapshots cannot overwrite a healthy profile", function()
		local adapter, _, manager = setup()
		assert(manager:load(101, profile(101)))
		equal(manager:save(101, profile(102)), false, "wrong-owner save fails")
		local cyclic = profile(101)
		cyclic.loop = cyclic
		equal(manager:save(101, cyclic), false, "cyclic save fails safely")
		equal(adapter.writes, 1, "invalid snapshots never reach storage")
		equal(manager:isOwned(101), true, "input validation leaves healthy session intact")
	end)

	run("negative Studio owner IDs remain isolated", function()
		local adapter, _, manager = setup()
		assert(manager:load(-1, profile(-1)))
		assert(manager:load(-2, profile(-2)))
		equal(adapter.values["island:-1"].data.ownerId, -1, "first Studio player has own key")
		equal(adapter.values["island:-2"].data.ownerId, -2, "second Studio player has own key")
	end)
end
