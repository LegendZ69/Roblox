--!strict
-- Exercise the same request coordinator used by Main with real game/persistence
-- modules. Ports represent transport, character facts, and time, not Roblox mocks.
local Session = require("../src/server/Session")
local Island = require("../src/server/Island")
local Persistence = require("../src/server/Persistence")

local function equal(actual: any, expected: any, message: string)
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function rig(): any
	local h: any = {
		now = 100,
		clock = 0,
		models = {},
		alive = {},
		distance = {},
		moves = {},
		notices = {},
		changes = {},
		broadcasts = 0,
		syncs = 0,
		frozen = {},
		records = {},
		storageFail = false,
	}
	local adapter = {}
	function adapter:update(key: string, transform: any): (boolean, any)
		if h.storageFail then
			return false, "unavailable"
		end
		local proposal = transform(h.records[key])
		if proposal ~= nil then
			h.records[key] = proposal
		end
		return true, proposal
	end
	h.persistence = Persistence.new(adapter, {
		sessionId = "cloud-session",
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
			local model = h.models[ownerId]
			return if model and model.accepting then model else nil
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
			table.insert(h.moves, { userId = userId, ownerId = ownerId })
		end,
		notice = function(userId: number, message: string, ok: boolean)
			table.insert(h.notices, { userId = userId, message = message, ok = ok })
		end,
		changed = function(ownerId: number)
			h.changes[ownerId] = (h.changes[ownerId] or 0) + 1
		end,
		freeze = function(ownerId: number)
			h.frozen[ownerId] = true
			h.models[ownerId]:close()
			h.session:closeIsland(ownerId, "Island paused")
		end,
		sync = function(_userId: number)
			h.syncs += 1
		end,
		broadcast = function()
			h.broadcasts += 1
		end,
	})
	function h.add(self: any, userId: number, complete: boolean?)
		assert(self.session:add(userId, "Player " .. tostring(userId)))
		self.alive[userId] = true
		local initial = Island.defaultRecord(userId)
		if complete then
			initial.projects = { campfire = true, bridge = true, beacon = true }
			initial.tutorialStage = 4
		end
		local record, problem = self.persistence:load(userId, initial)
		assert(record, tostring(problem))
		self.models[userId] = Island.new(userId, record)
		self.session:travel(userId, userId)
	end
	function h.act(self: any, userId: number, kind: string, target: string?, otherId: number?)
		-- Normal interactions are spaced out; rate-limit scenarios call request directly.
		self.clock += 1
		return self.session:request(userId, { kind = kind, target = target, userId = otherId })
	end
	function h.invite(self: any, ownerId: number, helperId: number)
		self:act(ownerId, "invite", nil, helperId)
		self:act(helperId, "acceptInvite", nil, ownerId)
	end
	return h
end

return function()
	local h = rig()
	h:add(101)
	h:add(202)
	h:act(202, "visit", nil, 101)
	equal(h.session:current(202), 101, "visitor travels to host")
	h:act(202, "harvest", "wood1")
	equal(h.models[101].record.stockpile.wood, 0, "visitor cannot harvest")
	h:invite(101, 202)
	equal(h.models[101]:canEdit(202), true, "accepting grants helper permission")
	for _, node in { "wood1", "wood2", "wood3", "wood4" } do
		h:act(202, "harvest", node)
	end
	h:act(202, "build", "campfire")
	equal(h.models[101].record.projects.campfire, true, "helper builds on host island")
	equal(h.models[101].record.stockpile.wood, 0, "host pays cost once")
	equal(h.models[202].record.stockpile.wood, 0, "helper stockpile is unchanged")
	equal(h.models[202].record.projects.campfire, false, "helper's own project stays unbuilt")
	equal(h.persistence:save(101, h.models[101].record), true, "host progress can be saved")
	equal(h.records["island:101"].data.projects.campfire, true, "persisted host owns helper work")
	equal(h.records["island:202"].data.projects.campfire, false, "persisted helper record remains separate")
	print("PASS Session: two-player invitations route work and saved progress exclusively to the host")

	local revoked = rig()
	revoked:add(101)
	revoked:add(202)
	revoked:invite(101, 202)
	revoked:act(101, "revoke", nil, 202)
	equal(revoked.session:current(202), 202, "revoked helper is returned home")
	equal(revoked.models[101]:canEdit(202), false, "permission ends immediately")
	revoked.clock += 1
	revoked.session:request(202, { kind = "harvest", target = "wood1" }, 101)
	equal(revoked.models[101].record.stockpile.wood, 0, "late host prompt cannot gather from home")
	revoked:act(202, "visit", nil, 101)
	revoked:act(202, "harvest", "wood1")
	equal(revoked.models[101].record.stockpile.wood, 0, "visiting again does not restore permission")
	revoked:act(202, "home")
	revoked:act(202, "harvest", "wood1")
	equal(revoked.models[202].record.stockpile.wood, 3, "home requests use own island")
	print("PASS Session: revocation returns helpers home and rejects stale host prompts")

	local guarded = rig()
	guarded:add(101)
	guarded:add(202)
	local function noEffects(payload: any, actor: number?)
		guarded.clock += 1
		local notices, moves = #guarded.notices, #guarded.moves
		local broadcasts, syncs = guarded.broadcasts, guarded.syncs
		guarded.session:request(actor or 101, payload)
		equal(#guarded.notices, notices, "invalid request sends no notices")
		equal(#guarded.moves, moves, "invalid request performs no travel")
		equal(guarded.broadcasts, broadcasts, "invalid request cannot amplify broadcasts")
		equal(guarded.syncs, syncs, "invalid request cannot trigger sync")
		equal(guarded.models[101].record.stockpile.wood, 0, "invalid request cannot grant supplies")
	end
	for _, payload in
		{
			false,
			"harvest",
			{},
			{ kind = {} },
			{ kind = "unsupported", userId = 202 },
			{ kind = "harvest", target = {} },
			{ kind = "harvest", target = string.rep("x", 41) },
			{ kind = "invite", userId = 0 / 0 },
			{ kind = "invite", userId = math.huge },
			{ kind = "invite", userId = 2.5 },
			{ kind = "invite", userId = "202" },
		}
	do
		noEffects(payload)
	end
	noEffects(nil)
	noEffects({ kind = "sync" }, 999)
	guarded.distance[101] = 100
	guarded.clock += 1
	guarded.session:request(101, { kind = "harvest", target = "wood1", distance = 1, alive = true, ownerId = 202 })
	equal(guarded.models[101].record.stockpile.wood, 0, "client cannot forge distance")
	guarded.distance[101] = 2
	guarded.alive[101] = false
	guarded:act(101, "harvest", "wood1")
	equal(guarded.models[101].record.stockpile.wood, 0, "dead character cannot act")
	guarded.alive[101] = true
	guarded.clock += 1
	guarded.session:request(101, { kind = "harvest", target = "wood1", ownerId = 202, userId = 202, amount = 999 })
	equal(guarded.models[101].record.stockpile.wood, 3, "only configured yield reaches active island")
	equal(guarded.models[202].record.stockpile.wood, 0, "client owner ID cannot redirect action")
	print("PASS Session: malformed requests are inert and character facts and routing stay authoritative")

	local invites = rig()
	invites:add(101)
	invites:add(202)
	invites:act(101, "invite", nil, 202)
	equal(#invites.session:view(202).invites, 1, "invite reaches recipient")
	invites.now = 130
	invites:act(101, "invite", nil, 202)
	equal(#invites.session:view(202).invites, 1, "duplicate does not add an invitation")
	invites.now = 160
	invites:act(202, "acceptInvite", nil, 101)
	equal(invites.models[101]:canEdit(202), false, "expiry is enforced without waiting for tick")
	equal(#invites.session:view(202).invites, 0, "duplicate does not extend deadline")
	invites.session:tick()
	invites:act(101, "invite", nil, 202)
	invites:act(202, "declineInvite", nil, 101)
	invites:act(202, "acceptInvite", nil, 101)
	equal(invites.models[101]:canEdit(202), false, "declined invitation cannot be replayed")
	invites:invite(101, 202)
	invites:act(101, "revoke", nil, 202)
	invites:act(202, "acceptInvite", nil, 101)
	equal(invites.models[101]:canEdit(202), false, "consumed invitation cannot restore revoked access")
	print("PASS Session: invitation deadlines, duplicate delivery, decline and replay preserve consent")

	local departed = rig()
	for _, id in { 101, 202, 303, 404 } do
		departed:add(id, true)
	end
	departed:invite(101, 202)
	departed:act(303, "visit", nil, 101)
	departed:act(101, "invite", nil, 404)
	departed:act(101, "startEvent")
	departed.session:remove(101)
	departed.models[101]:close()
	for _, id in { 202, 303 } do
		equal(departed.session:current(id), id, "owner departure returns helpers and visitors")
	end
	equal(#departed.session:view(404).invites, 0, "owner departure clears pending invites")
	equal(#departed.session:view(202).players, 3, "departed owner leaves roster")
	equal(departed.models[101]:snapshot(100).event, nil, "closing cancels unfinished storm")
	departed:act(404, "acceptInvite", nil, 101)
	equal(departed.models[101]:canEdit(404), false, "late invite cannot join departed host")
	equal(departed.persistence:release(101, departed.models[101].record), true, "departure saves closed record")
	departed:add(101, true)
	equal(#departed.models[101]:snapshot(100).helpers, 0, "rejoining never restores temporary helpers")
	equal(departed.models[101].record.nextEventAt, 370, "rejoin preserves interrupted storm cooldown")
	print("PASS Session: host departure returns visitors, clears invitations and saves interruption safely")

	local helperLeft = rig()
	for _, id in { 101, 202, 303 } do
		helperLeft:add(id)
	end
	helperLeft:invite(101, 202)
	helperLeft:invite(303, 202)
	helperLeft:act(202, "invite", nil, 101)
	helperLeft.session:remove(202)
	helperLeft.models[202]:close()
	equal(helperLeft.models[101]:canEdit(202), false, "helper departure removes first host access")
	equal(helperLeft.models[303]:canEdit(202), false, "helper departure removes other host access")
	equal(#helperLeft.session:view(101).invites, 0, "departed helper's own invitations are cleared")
	equal(helperLeft.persistence:release(202, helperLeft.models[202].record), true, "helper profile releases")
	helperLeft:add(202)
	helperLeft:act(202, "visit", nil, 101)
	helperLeft:act(202, "harvest", "wood1")
	equal(helperLeft.models[101].record.stockpile.wood, 0, "rejoined helper needs fresh consent")
	print("PASS Session: helper departure revokes access across all hosts before rejoining")

	local group = rig()
	for _, id in { 101, 202, 303, 404 } do
		group:add(id, true)
		if id ~= 101 then
			group:invite(101, id)
		end
	end
	group.clock += 1
	group.session:request(101, { kind = "startEvent", participants = 1 })
	equal(group.models[101]:snapshot(100).event.required, 24, "four present crew members determine workload")
	for round = 0, 5 do
		group.now = 100 + round * 5
		for _, id in { 101, 202, 303, 404 } do
			group:act(id, "repair", "repair1")
		end
	end
	group:act(202, "repair", "repair1")
	equal(group.models[101].record.stockpile.wood, 24, "four-player repair awards only one host reward")
	equal(group.models[101].record.stockpile.stone, 12, "stone reward matches one completion")
	for _, id in { 202, 303, 404 } do
		equal(group.models[id].record.stockpile.wood, 0, "helpers do not duplicate host reward")
	end
	equal(group.persistence:release(101, group.models[101].record), true, "completed reward releases atomically")
	local restored = group.persistence:load(101, Island.defaultRecord(101))
	assert(restored)
	equal(restored.lastRewardEvent, 1, "receipt survives storage round trip")
	equal(restored.stockpile.wood, 24, "reward survives storage round trip")
	print("PASS Session: four-player storm uses server crew count and persists exactly one reward")

	local eligibility = rig()
	for _, id in { 101, 202, 303, 404 } do
		eligibility:add(id, true)
	end
	eligibility:invite(101, 202)
	eligibility:act(202, "home")
	eligibility:act(303, "visit", nil, 101)
	eligibility:invite(101, 404)
	eligibility.alive[404] = false
	eligibility.clock += 1
	eligibility.session:request(101, { kind = "startEvent", participants = 4 })
	equal(eligibility.models[101]:snapshot(100).event.required, 12, "away helpers, visitors and dead crew do not count")
	print("PASS Session: storm scaling excludes absent, unauthorized and dead players")

	local limited = rig()
	limited:add(101)
	limited:add(202)
	for _ = 1, 12 do
		limited.session:request(101, { kind = "sync" })
	end
	equal(limited.syncs, 12, "initial burst is bounded")
	limited.session:request(101, { kind = "harvest", target = "wood1" }, 101)
	equal(limited.models[101].record.stockpile.wood, 0, "prompts share exhausted remote budget")
	limited.session:request(202, { kind = "sync" })
	equal(limited.syncs, 13, "another player has an independent budget")
	limited.clock = 0.199
	limited.session:request(101, { kind = "sync" })
	equal(limited.syncs, 13, "partial token cannot send a request")
	limited.clock = 0.201
	limited.session:request(101, { kind = "harvest", target = "wood1" }, 101)
	equal(limited.models[101].record.stockpile.wood, 3, "one token refills at five requests per second")
	limited.clock = 100
	for _ = 1, 13 do
		limited.session:request(101, { kind = "sync" })
	end
	equal(limited.syncs, 25, "idle time refills only to burst capacity")
	local malformed = rig()
	malformed:add(101)
	for _ = 1, 12 do
		malformed.session:request(101, false)
	end
	malformed.session:request(101, { kind = "sync" })
	equal(malformed.syncs, 0, "malformed floods also consume the request budget")
	print("PASS Session: per-player limits cap bursts and share a budget across prompts and remotes")

	local views = rig()
	for _, id in { -1, -4, -2, -3 } do
		views:add(id)
	end
	views:act(-1, "invite", nil, -2)
	views:act(-4, "invite", nil, -2)
	local view = views.session:view(-2)
	equal(view.players[1].userId, -4, "roster is sorted with Studio IDs")
	equal(view.invites[1].ownerId, -4, "invitations are sorted with Studio IDs")
	view.players[1].displayName = "tampered"
	view.invites[1].ownerId = 999
	table.clear(view.players)
	equal(#views.session:view(-2).players, 4, "roster view cannot remove connected players")
	equal(views.session:view(-2).invites[1].ownerId, -4, "view cannot rewrite invitations")
	equal(views.session:add(-1, "duplicate"), false, "duplicate registration cannot replace identity")
	equal(views.session:view(-2).players[4].displayName, "Player -1", "duplicate leaves original name")
	views.models[-4]:close()
	views.session:closeIsland(-4, "Paused")
	equal(views.session:view(-2).players[1].hasIsland, false, "paused player remains in roster without active island")
	equal(#views.session:view(-2).invites, 1, "paused host loses pending invitations")
	views:act(-2, "visit", nil, -4)
	equal(views.session:current(-2), -2, "unavailable host cannot become active destination")
	print("PASS Session: detached sorted views support Studio IDs and distinguish paused islands")

	for _, failure in { "expiry", "unconfirmed save" } do
		local paused = rig()
		paused:add(101)
		paused:add(202)
		paused:invite(101, 202)
		paused:act(202, "harvest", "wood1")
		if failure == "expiry" then
			paused.now = 220
		else
			paused.storageFail = true
			equal(paused.persistence:save(101, paused.models[101].record), false, "save failure is reported")
		end
		paused:act(202, "harvest", "wood2")
		equal(paused.frozen[101], true, failure .. " freezes host before next mutation")
		equal(paused.models[101].record.stockpile.wood, 3, "paused island cannot mint further supplies")
		equal(paused.models[101].accepting, false, "paused model rejects all further work")
		equal(paused.session:current(202), 202, "paused island returns helper home")
		equal(
			paused.records["island:101"].data.stockpile.wood,
			0,
			"failed connection never overwrites confirmed record"
		)
	end
	print("PASS Session: lease expiry and uncertain saves freeze mutation and return helpers home")
end
