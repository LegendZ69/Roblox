--!strict
local Island = require("../src/server/Island")

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

local near = { distance = 4, alive = true, participants = 1 }

local function rejectsUnchanged(island: any, actor: any, action: any, now: any, context: any)
	local before = island:snapshot(100)
	local result = island:act(actor, action, now, context)
	equal(result.ok, false, "invalid action is rejected")
	same(island:snapshot(100), before, "rejected action leaves island unchanged")
end

local function completeIsland(): any
	local record = Island.defaultRecord(101)
	record.projects = { campfire = true, bridge = true, beacon = true }
	record.tutorialStage = 4
	return Island.new(101, record)
end

return function()
	local island = Island.new(101)
	local result = island:act(101, { kind = "harvest", target = "wood1" }, 100, { distance = 4, alive = true })
	equal(result.ok, true, "nearby owner harvest succeeds")
	equal(island:snapshot(100).stockpile.wood, 3, "harvest deposits wood into island stockpile")
	equal(island:snapshot(100).tutorialStage, 1, "first successful harvest advances onboarding")
	print("PASS Island: nearby owner harvest adds supplies and advances onboarding")

	local cooperative = Island.new(101)
	cooperative:setHelper(202, true)
	equal(cooperative:act(101, { kind = "harvest", target = "wood1" }, 100, near).ok, true, "owner gathers")
	rejectsUnchanged(cooperative, 202, { kind = "harvest", target = "wood1" }, 100, near)
	equal(cooperative:act(202, { kind = "harvest", target = "wood2" }, 100, near).ok, true, "helper gathers")
	equal(cooperative:act(101, { kind = "harvest", target = "wood3" }, 100, near).ok, true, "owner gathers more")
	equal(cooperative:act(202, { kind = "harvest", target = "wood4" }, 100, near).ok, true, "helper fills cost")
	equal(cooperative:act(202, { kind = "build", target = "campfire" }, 100, near).ok, true, "helper buys campfire")
	rejectsUnchanged(cooperative, 101, { kind = "build", target = "campfire" }, 100, near)
	equal(cooperative:snapshot(100).stockpile.wood, 0, "two purchases deduct cost only once")
	equal(cooperative:snapshot(100).projects.campfire, true, "campfire is completed")
	equal(cooperative:snapshot(100).tutorialStage, 2, "campfire advances onboarding")
	equal(cooperative:act(101, { kind = "harvest", target = "wood1" }, 107, near).ok, true, "node becomes available")
	print("PASS Island: helpers share depletion and atomic one-time construction")

	local storm = completeIsland()
	equal(storm:act(101, { kind = "startEvent" }, 100, near).ok, true, "owner starts unlocked storm")
	equal(storm:snapshot(100).event.required, 12, "solo workload is completable")
	equal(storm:snapshot(100).event.endsAt, 190, "storm has a ninety-second deadline")
	equal(storm.record.nextEventAt, 370, "start reserves cooldown across a server restart")
	for repair = 1, 12 do
		local now = 100 + (repair - 1) * 5
		equal(
			storm:act(101, { kind = "repair", target = "repair1" }, now, near).ok,
			true,
			"solo repairs before deadline"
		)
		rejectsUnchanged(storm, 101, { kind = "repair", target = "repair2" }, now, near)
	end
	local earned = storm:snapshot(155)
	equal(earned.event.phase, "success", "last repair completes storm")
	equal(earned.stockpile.wood, 24, "storm deposits wood reward once")
	equal(earned.stockpile.stone, 12, "storm deposits stone reward once")
	equal(earned.lastRewardEvent, 1, "reward receipt matches completed run")
	equal(earned.nextEventAt, 335, "successful run enters cooldown")
	equal(earned.tutorialStage, 5, "first storm success completes onboarding")
	storm:tick(156)
	rejectsUnchanged(storm, 101, { kind = "startEvent" }, 334, near)
	local restored = Island.new(101, storm.record)
	equal(restored:snapshot(156).event, nil, "transient storm does not restart from save")
	same(restored.record, storm.record, "completed receipt and supplies survive restore")
	rejectsUnchanged(restored, 101, { kind = "repair", target = "repair1" }, 156, near)
	equal(restored:act(101, { kind = "startEvent" }, 335, near).ok, true, "new storm starts at cooldown boundary")
	equal(restored:snapshot(335).event.serial, 2, "retry gets a new receipt identity")
	print("PASS Island: solo storm rewards exactly once and persists completion and cooldown")

	local guarded = Island.new(101)
	local harvest = { kind = "harvest", target = "wood1" }
	for _, actor in { 202, 0, 1.5, math.huge, 0 / 0, "101", {} } do
		rejectsUnchanged(guarded, actor, harvest, 100, near)
	end
	rejectsUnchanged(guarded, nil, harvest, 100, near)
	for _, malformed in
		{
			false,
			"harvest",
			{},
			{ kind = false },
			{ kind = "withdraw" },
			{ kind = "harvest" },
			{ kind = "harvest", target = {} },
			{ kind = "harvest", target = "missing" },
			{ kind = "build", target = "missing" },
			{ kind = "repair", target = "missing" },
		}
	do
		rejectsUnchanged(guarded, 101, malformed, 100, near)
	end
	rejectsUnchanged(guarded, 101, nil, 100, near)
	for _, context in
		{
			false,
			{},
			{ alive = false, distance = 1 },
			{ alive = true },
			{ alive = true, distance = -1 },
			{ alive = true, distance = 18.01 },
			{ alive = true, distance = math.huge },
			{ alive = true, distance = 0 / 0 },
			{ alive = true, distance = "1" },
			{ alive = "true", distance = 1 },
		}
	do
		rejectsUnchanged(guarded, 101, harvest, 100, context)
	end
	rejectsUnchanged(guarded, 101, harvest, 100, nil)
	for _, time in { -1, math.huge, 0 / 0, "100" } do
		rejectsUnchanged(guarded, 101, harvest, time, near)
	end
	equal(guarded:act(101, harvest, 100, { alive = true, distance = 18 }).ok, true, "interaction boundary is inclusive")
	for _ = 1, 30 do
		rejectsUnchanged(guarded, 101, harvest, 100, near)
	end
	equal(guarded.record.stockpile.wood, 3, "replayed node requests cannot mint supplies")
	print("PASS Island: malformed, distant, dead, unauthorized and replayed actions leave state unchanged")

	local progression = Island.new(101)
	rejectsUnchanged(progression, 101, { kind = "harvest", target = "stone1" }, 100, near)
	rejectsUnchanged(progression, 101, { kind = "build", target = "bridge" }, 100, near)
	rejectsUnchanged(progression, 101, { kind = "build", target = "campfire" }, 100, near)
	for count = 1, 4 do
		equal(
			progression:act(101, { kind = "harvest", target = "wood1" }, 100 + count * 8, near).ok,
			true,
			"wood funds campfire"
		)
	end
	equal(
		progression:act(101, { kind = "build", target = "campfire" }, 140, near).ok,
		true,
		"first project unlocks bridge"
	)
	for count = 1, 10 do
		equal(
			progression:act(101, { kind = "harvest", target = "wood1" }, 140 + count * 8, near).ok,
			true,
			"wood funds bridge"
		)
	end
	equal(
		progression:act(101, { kind = "build", target = "bridge" }, 230, near).ok,
		true,
		"bridge unlocks reachable stone"
	)
	for count = 1, 14 do
		equal(
			progression:act(101, { kind = "harvest", target = "wood1" }, 230 + count * 8, near).ok,
			true,
			"wood funds beacon"
		)
	end
	local woodBeforeFailedPurchase = progression.record.stockpile.wood
	rejectsUnchanged(progression, 101, { kind = "build", target = "beacon" }, 350, near)
	equal(progression.record.stockpile.wood, woodBeforeFailedPurchase, "missing stone never partially spends wood")
	for count = 1, 10 do
		equal(
			progression:act(101, { kind = "harvest", target = "stone1" }, 350 + count * 8, near).ok,
			true,
			"stone is obtainable after bridge"
		)
	end
	equal(progression:act(101, { kind = "build", target = "beacon" }, 440, near).ok, true, "beacon uses both resources")
	same(progression.record.stockpile, { wood = 2, stone = 0 }, "full loop spends exact configured costs")
	equal(progression.record.tutorialStage, 4, "all building objectives complete")
	same(Island.new(101, progression.record).record, progression.record, "all progression survives reload")
	print("PASS Island: campfire, bridge and beacon are obtainable in sequence with atomic multi-resource spending")

	local permissions = Island.new(-1)
	equal(permissions:setHelper(-2, true), true, "Studio helper can accept")
	equal(permissions:setHelper(-3, true), true, "second helper can accept")
	equal(permissions:setHelper(-4, true), true, "third helper can accept")
	equal(permissions:setHelper(-5, true), false, "owner plus helpers never exceeds four")
	equal(permissions:setHelper(-1, true), false, "owner is not duplicated as helper")
	equal(permissions:setHelper(0 / 0, true), false, "invalid helper ID is rejected")
	equal(permissions:setHelper(-2, "true"), false, "permission requires a boolean")
	same(permissions:snapshot(100).helpers, { -4, -3, -2 }, "helper snapshot is a serializable array")
	equal(permissions:act(-2, harvest, 100, near).ok, true, "accepted helper contributes to host")
	permissions:setHelper(-2, false)
	rejectsUnchanged(permissions, -2, { kind = "harvest", target = "wood2" }, 100, near)
	permissions:close()
	rejectsUnchanged(permissions, -1, { kind = "build", target = "campfire" }, 100, near)
	rejectsUnchanged(permissions, -3, { kind = "harvest", target = "wood2" }, 100, near)
	equal(permissions:setHelper(-2, true), false, "closed island cannot grant new permission")
	equal(permissions:canEdit(-1), false, "closed owner cannot edit")
	equal(permissions:snapshot(100).accepting, false, "closed snapshot disables world interactions")
	equal(#permissions:snapshot(100).helpers, 0, "owner departure clears temporary permissions")
	print("PASS Island: helper capacity, revocation and owner departure preserve ownership")

	local failing = completeIsland()
	failing:setHelper(202, true)
	rejectsUnchanged(failing, 202, { kind = "startEvent" }, 100, near)
	rejectsUnchanged(Island.new(101), 101, { kind = "startEvent" }, 100, near)
	rejectsUnchanged(failing, 101, { kind = "startEvent", target = "bad" }, 100, near)
	rejectsUnchanged(failing, 101, { kind = "startEvent" }, 100, { alive = true, distance = 1, participants = 0 / 0 })
	equal(failing:act(101, { kind = "startEvent" }, 100, near).ok, true, "unlocked owner starts")
	rejectsUnchanged(failing, 101, { kind = "startEvent" }, 100, near)
	rejectsUnchanged(failing, 101, { kind = "repair", target = "repair4" }, 101, near)
	equal(failing:act(202, { kind = "repair", target = "repair1" }, 101, near).ok, true, "helper repairs")
	failing:setHelper(202, false)
	rejectsUnchanged(failing, 202, { kind = "repair", target = "repair1" }, 106, near)
	rejectsUnchanged(failing, 101, { kind = "repair", target = "repair1" }, 190, near)
	equal(failing:tick(190), true, "deadline resolves event")
	equal(failing:snapshot(190).event.phase, "failed", "unfinished storm fails")
	same(failing.record.stockpile, { wood = 0, stone = 0 }, "failure causes no resource loss")
	equal(failing.record.lastRewardEvent, 0, "failure earns no receipt")
	equal(failing.record.nextEventAt, 370, "failure cooldown starts at deadline")
	equal(failing:tick(191), false, "timeout cannot resolve again")
	rejectsUnchanged(failing, 101, { kind = "startEvent" }, 369, near)
	equal(failing:tick(370), true, "expired result clears for next storm")
	equal(failing:snapshot(370).event, nil, "cooldown returns to ready state")
	equal(failing:act(101, { kind = "startEvent" }, 370, near).ok, true, "failed storm can retry")
	print("PASS Island: storm permissions, deadlines, failure and cooldown reject late or repeated resolution")

	local group = completeIsland()
	for _, helper in { 202, 303, 404 } do
		group:setHelper(helper, true)
	end
	equal(
		group:act(101, { kind = "startEvent" }, 100, { alive = true, distance = 1, participants = 99 }).ok,
		true,
		"large count clamps to four"
	)
	equal(group:snapshot(100).event.required, 24, "four-player workload is fixed at start")
	for round = 0, 5 do
		for _, actor in { 101, 202, 303, 404 } do
			equal(
				group:act(actor, { kind = "repair", target = "repair1" }, 100 + round * 5, near).ok,
				true,
				"all helpers can contribute"
			)
		end
	end
	equal(group:snapshot(125).event.phase, "success", "four-player storm completes")
	same(group.record.stockpile, { wood = 24, stone = 12 }, "group earns one island reward")
	local interrupted = completeIsland()
	interrupted:act(101, { kind = "startEvent" }, 100, { alive = true, distance = 1, participants = -2 })
	equal(interrupted:snapshot(100).event.required, 12, "small count clamps to solo")
	local restarted = Island.new(101, interrupted.record)
	rejectsUnchanged(restarted, 101, { kind = "startEvent" }, 101, near)
	equal(restarted:snapshot(101).event, nil, "interrupted run is not resumed")
	interrupted:act(101, { kind = "repair", target = "repair1" }, 100, near)
	interrupted:close()
	interrupted:tick(190)
	equal(interrupted:snapshot(190).event, nil, "owner departure cancels unfinished run")
	same(interrupted.record.stockpile, { wood = 0, stone = 0 }, "cancelled run earns no reward")
	equal(interrupted.record.nextEventAt, 370, "cancellation preserves restart cooldown")
	print("PASS Island: four-player cooperation pays once; departure and restart cancel unfinished storms")

	local mutations: { (any) -> () } = {
		function(record)
			record.ownerId = 202
		end,
		function(record)
			record.schemaVersion = 2
		end,
		function(record)
			record.stockpile = nil
		end,
		function(record)
			record.stockpile.wood = -1
		end,
		function(record)
			record.stockpile.wood = 0 / 0
		end,
		function(record)
			record.stockpile.stone = math.huge
		end,
		function(record)
			record.stockpile.stone = 1.5
		end,
		function(record)
			record.projects.campfire = 1
		end,
		function(record)
			record.projects.bridge = true
		end,
		function(record)
			record.tutorialStage = 6
		end,
		function(record)
			record.nextEventAt = -1
		end,
		function(record)
			record.eventSerial = 1.5
		end,
		function(record)
			record.lastRewardEvent = 1
		end,
	}
	for _, mutate in mutations do
		local invalid = Island.defaultRecord(101)
		mutate(invalid)
		local checked, reason = Island.validateRecord(invalid, 101)
		equal(checked, nil, "invalid save is rejected")
		equal(type(reason), "string", "invalid save returns recovery reason")
		local ok = pcall(Island.new, 101, invalid)
		equal(ok, false, "constructor never replaces corrupt save with defaults")
	end
	for _, invalid in { false, "record", 1, {} } do
		equal(Island.validateRecord(invalid, 101), nil, "malformed save is rejected")
	end
	equal(Island.validateRecord(nil, 101), nil, "missing loaded record is not a confirmed new profile")
	print("PASS Island: corrupt, foreign and unsupported profiles fail without a default overwrite")

	local source = Island.defaultRecord(101)
	source.stockpile.wood = 15
	local detached = Island.new(101, source)
	source.stockpile.wood = 900
	equal(detached.record.stockpile.wood, 15, "constructor copies loaded data")
	local validated = Island.validateRecord(detached.record, 101)
	assert(validated)
	validated.projects.campfire = true
	equal(detached.record.projects.campfire, false, "validator returns detached normalized data")
	detached:setHelper(202, true)
	local view = detached:snapshot(100)
	view.stockpile.wood = 999
	view.projects.campfire = true
	view.helpers[1] = 999
	view.nodes.wood1 = 999
	equal(detached.record.stockpile.wood, 15, "client snapshot cannot mutate resources")
	equal(detached.record.projects.campfire, false, "client snapshot cannot construct projects")
	equal(detached:canEdit(999), false, "client snapshot cannot grant helpers")
	equal(detached:snapshot(100).nodes.wood1, 0, "client snapshot cannot deplete nodes")
	local eventView = group:snapshot(125)
	eventView.event.progress = 999
	equal(group:snapshot(125).event.progress, 24, "event snapshot is detached")
	local secondDefault = Island.defaultRecord(101)
	equal(secondDefault.stockpile.wood, 0, "default profiles do not share mutable tables")
	print("PASS Island: loaded records, validation results and nested snapshots have no writable aliases")
end
