--!strict
-- HUD eligibility only. The server still validates every request, including
-- permissions, distance, resources, invitation expiry, and persistence leases.
local ClientPolicy = {}

export type Snapshot = {
	island: { ownerId: number, accepting: boolean?, helpers: { number } }?,
	isOwner: boolean,
	canEdit: boolean,
	saveStatus: string,
	players: { { userId: number, hasIsland: boolean } },
	invites: { { ownerId: number } },
}

function ClientPolicy.canEdit(snapshot: Snapshot?): boolean
	return snapshot ~= nil
		and snapshot.island ~= nil
		and snapshot.island.accepting ~= false
		and snapshot.saveStatus ~= "loading"
		and snapshot.canEdit
end

local function validUserId(value: any): boolean
	return type(value) == "number" and value ~= 0 and math.abs(value) < 9007199254740992 and value % 1 == 0
end

function ClientPolicy.canRequest(snapshot: Snapshot?, localUserId: number, action: any): boolean
	if type(action) ~= "table" or type(action.kind) ~= "string" then
		return false
	end
	if action.target ~= nil and (type(action.target) ~= "string" or #action.target > 40) then
		return false
	end
	local kind = action.kind
	if kind == "sync" then
		return true
	end
	if snapshot == nil then
		return false
	end
	-- Travel and invitation responses do not depend on the player's own profile.
	-- In recovery, home safely returns to the hub if their island is unavailable.
	if kind == "home" then
		return true
	end
	if kind == "harvest" or kind == "build" or kind == "repair" then
		return ClientPolicy.canEdit(snapshot) and type(action.target) == "string" and #action.target > 0
	elseif kind == "startEvent" then
		return ClientPolicy.canEdit(snapshot) and snapshot.isOwner
	elseif
		kind ~= "visit"
		and kind ~= "acceptInvite"
		and kind ~= "declineInvite"
		and kind ~= "invite"
		and kind ~= "revoke"
	then
		return false
	end
	local otherId = action.userId
	if not validUserId(otherId) or otherId == localUserId then
		return false
	end
	local other = nil
	for _, entry in snapshot.players do
		if entry.userId == otherId then
			other = entry
			break
		end
	end
	if other == nil then
		return false
	end
	local island = snapshot.island
	if kind == "visit" then
		return other.hasIsland and (island == nil or island.ownerId ~= otherId)
	elseif kind == "acceptInvite" or kind == "declineInvite" then
		if not other.hasIsland then
			return false
		end
		for _, invite in snapshot.invites do
			if invite.ownerId == otherId then
				return true
			end
		end
		return false
	end
	if not ClientPolicy.canEdit(snapshot) or not snapshot.isOwner or island == nil or island.ownerId ~= localUserId then
		return false
	end
	return kind == "revoke" or table.find(island.helpers, otherId) == nil
end

return ClientPolicy
