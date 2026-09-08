--!strict
-- Request eligibility uses the same policy as the real HUD, without a fake GUI.
local ClientPolicy = require("../src/shared/ClientPolicy")

local function equal(actual: any, expected: any, message: string)
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function snapshot(): any
	return {
		island = { ownerId = 101, accepting = true, helpers = { 303 } },
		isOwner = true,
		canEdit = true,
		saveStatus = "saved",
		players = {
			{ userId = 101, hasIsland = true },
			{ userId = 202, hasIsland = true },
			{ userId = 303, hasIsland = false },
		},
		invites = { { ownerId = 202 } },
	}
end

local actions = {
	{ kind = "home" },
	{ kind = "visit", userId = 202 },
	{ kind = "acceptInvite", userId = 202 },
	{ kind = "declineInvite", userId = 202 },
	{ kind = "invite", userId = 202 },
	{ kind = "revoke", userId = 303 },
	{ kind = "harvest", target = "wood1" },
	{ kind = "build", target = "campfire" },
	{ kind = "repair", target = "repair1" },
	{ kind = "startEvent" },
}

return function()
	equal(ClientPolicy.canRequest(nil, 101, { kind = "sync" }), true, "initial state request is allowed")
	for _, action in actions do
		equal(ClientPolicy.canRequest(nil, 101, action), false, action.kind .. " waits for a server snapshot")
	end
	print("PASS ClientPolicy: only initial synchronization is available before the first snapshot")

	for _, status in { "loading", "recovery" } do
		local state = snapshot()
		state.island = nil
		state.isOwner = false
		state.canEdit = false
		state.saveStatus = status
		for index, action in actions do
			equal(ClientPolicy.canRequest(state, 101, action), index <= 4, status .. " eligibility for " .. action.kind)
		end
	end
	print("PASS ClientPolicy: loading and failed profiles can travel and answer invitations but cannot mutate islands")

	local owner = snapshot()
	for _, action in actions do
		equal(ClientPolicy.canRequest(owner, 101, action), true, "active owner eligibility for " .. action.kind)
	end
	equal(ClientPolicy.canRequest(owner, 101, { kind = "invite", userId = 303 }), false, "do not reinvite a helper")
	print("PASS ClientPolicy: active owners can manage their crew and request island actions")

	local guest = snapshot()
	guest.island.ownerId = 202
	guest.isOwner = false
	guest.canEdit = false
	for index = 5, #actions do
		local action = actions[index]
		equal(ClientPolicy.canRequest(guest, 101, action), false, "visitor cannot " .. action.kind)
	end
	equal(ClientPolicy.canRequest(guest, 101, { kind = "home" }), true, "visitor can return home")
	guest.canEdit = true
	for _, kind in { "harvest", "build", "repair" } do
		equal(ClientPolicy.canRequest(guest, 101, { kind = kind, target = "target" }), true, "helper can " .. kind)
	end
	for _, action in { actions[5], actions[6], actions[10] } do
		equal(ClientPolicy.canRequest(guest, 101, action), false, "helper cannot " .. action.kind)
	end
	print("PASS ClientPolicy: visitors remain read-only and helpers cannot acquire owner-only actions")

	for _, cause in { "loading", "closed", "permission" } do
		local frozen = snapshot()
		if cause == "loading" then
			frozen.saveStatus = "loading"
		elseif cause == "closed" then
			frozen.island.accepting = false
		else
			frozen.canEdit = false
			frozen.saveStatus = "recovery"
		end
		for index, action in actions do
			equal(ClientPolicy.canRequest(frozen, 101, action), index <= 4, cause .. " eligibility for " .. action.kind)
		end
	end
	print("PASS ClientPolicy: loading, closed, and permission-frozen islands retain only safe social controls")

	local targets = snapshot()
	for _, action in
		{
			{ kind = "visit", userId = 303 },
			{ kind = "visit", userId = 101 },
			{ kind = "visit", userId = 404 },
			{ kind = "acceptInvite", userId = 303 },
			{ kind = "declineInvite", userId = 303 },
			{ kind = "invite", userId = 404 },
			{ kind = "revoke", userId = 404 },
		}
	do
		equal(ClientPolicy.canRequest(targets, 101, action), false, "unavailable social target for " .. action.kind)
	end
	targets.island.ownerId = 202
	equal(ClientPolicy.canRequest(targets, 101, { kind = "visit", userId = 202 }), false, "already on target island")
	targets.invites = {}
	equal(ClientPolicy.canRequest(targets, 101, { kind = "acceptInvite", userId = 202 }), false, "invitation required")
	targets.island.ownerId = 101
	targets.players[2].userId = -2
	targets.invites = { { ownerId = -2 } }
	equal(ClientPolicy.canRequest(targets, 101, { kind = "acceptInvite", userId = -2 }), true, "Studio player IDs work")
	print("PASS ClientPolicy: social controls use current roster, island, helper, and invitation context")

	for _, status in { "session", "pending", "saving", "saved", "recovery" } do
		local active = snapshot()
		active.saveStatus = status
		equal(ClientPolicy.canRequest(active, 101, actions[8]), true, status .. " retains server-granted editing")
	end
	print("PASS ClientPolicy: active editing follows server permission through save and retry states")

	local state = snapshot()
	for _, action in
		{
			false,
			"home",
			{},
			{ kind = "purchase" },
			{ kind = 2 },
			{ kind = "build" },
			{ kind = "harvest", target = "" },
			{ kind = "repair", target = 2 },
			{ kind = "startEvent", target = string.rep("x", 41) },
			{ kind = "invite" },
			{ kind = "invite", userId = 0 },
			{ kind = "invite", userId = math.huge },
			{ kind = "invite", userId = 0 / 0 },
			{ kind = "invite", userId = 202.5 },
			{ kind = "invite", userId = 9007199254740992 },
			{ kind = "invite", userId = "202" },
		}
	do
		equal(ClientPolicy.canRequest(state, 101, action), false, "invalid action is unavailable")
	end
	equal(ClientPolicy.canRequest(state, 101, nil), false, "nil action is unavailable")
	print("PASS ClientPolicy: unknown and malformed actions cannot enable controls or leave the client")
end
