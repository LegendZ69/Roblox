--!strict
-- Multiplayer routing uses plain user IDs and synchronous engine adapters. Island
-- mutations and permission changes finish before any persistence work can yield.
type Action = { kind: string, target: string?, userId: number? }
type Player = { userId: number, displayName: string }
type Bucket = { tokens: number, updated: number }
type PlayerView = { userId: number, displayName: string, hasIsland: boolean }
type InviteView = { ownerId: number, ownerName: string }

export type Ports = {
	now: () -> number,
	clock: () -> number,
	maxPlayers: number,
	island: (number) -> any,
	isOwned: (number) -> boolean,
	alive: (number) -> boolean,
	facts: (number, number, Action) -> { distance: number, alive: boolean },
	move: (number, number?) -> (),
	notice: (number, string, boolean) -> (),
	changed: (number) -> (),
	freeze: (number) -> (),
	sync: (number) -> (),
	broadcast: () -> (),
}

type State = {
	_ports: Ports,
	_players: { [number]: Player },
	_current: { [number]: number },
	_invitations: { [number]: { [number]: number } },
	_buckets: { [number]: Bucket },
}

local Session = {}
Session.__index = Session
export type Session = typeof(setmetatable({} :: State, Session))

local gameplay = { harvest = true, build = true, startEvent = true, repair = true }
local social = {
	sync = true,
	home = true,
	visit = true,
	invite = true,
	acceptInvite = true,
	declineInvite = true,
	revoke = true,
}

local function validUserId(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < 2 ^ 53 and value ~= 0 and value % 1 == 0
end

function Session.new(ports: Ports): Session
	assert(ports.maxPlayers >= 1 and ports.maxPlayers % 1 == 0, "maxPlayers must be a positive integer")
	return setmetatable({
		_ports = ports,
		_players = {},
		_current = {},
		_invitations = {},
		_buckets = {},
	}, Session)
end

local function island(self: Session, ownerId: number?): any
	if ownerId == nil or self._players[ownerId] == nil then
		return nil
	end
	local model = self._ports.island(ownerId)
	return if model and model.accepting then model else nil
end

function Session.add(self: Session, userId: number, displayName: string): boolean
	if not validUserId(userId) or type(displayName) ~= "string" or self._players[userId] ~= nil then
		return false
	end
	self._players[userId] = { userId = userId, displayName = displayName }
	self._current[userId] = userId
	return true
end

function Session.current(self: Session, userId: number): number
	return self._current[userId] or userId
end

function Session.travel(self: Session, userId: number, ownerId: number?)
	if self._players[userId] == nil then
		return
	end
	local target = if island(self, ownerId) then ownerId else nil
	self._current[userId] = target or userId
	self._ports.move(userId, target)
end

function Session.view(self: Session, userId: number): { players: { PlayerView }, invites: { InviteView } }
	local players: { PlayerView } = {}
	for _, player in self._players do
		table.insert(players, {
			userId = player.userId,
			displayName = player.displayName,
			hasIsland = island(self, player.userId) ~= nil,
		})
	end
	table.sort(players, function(left: PlayerView, right: PlayerView)
		return left.userId < right.userId
	end)
	local invites: { InviteView } = {}
	local now = self._ports.now()
	for ownerId, expiresAt in self._invitations[userId] or {} do
		local owner = self._players[ownerId]
		if expiresAt > now and owner and island(self, ownerId) then
			table.insert(invites, { ownerId = ownerId, ownerName = owner.displayName })
		end
	end
	table.sort(invites, function(left: InviteView, right: InviteView)
		return left.ownerId < right.ownerId
	end)
	return { players = players, invites = invites }
end

local function allowedRequest(self: Session, userId: number): boolean
	local now = self._ports.clock()
	local bucket = self._buckets[userId]
	if not bucket then
		bucket = { tokens = 12, updated = now }
		self._buckets[userId] = bucket
	end
	bucket.tokens = math.min(12, bucket.tokens + math.max(0, now - bucket.updated) * 5)
	bucket.updated = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function participants(self: Session, ownerId: number, model: any): number
	local count = 0
	for userId in self._players do
		if self:current(userId) == ownerId and model:canEdit(userId) and self._ports.alive(userId) then
			count += 1
		end
	end
	return math.clamp(count, 1, self._ports.maxPlayers)
end

local function play(self: Session, userId: number, action: Action, promptOwnerId: number?): boolean
	local ownerId = promptOwnerId or self:current(userId)
	local model = island(self, ownerId)
	if not model or self:current(userId) ~= ownerId then
		self._ports.notice(userId, "Visit this island before interacting with it.", false)
		return false
	end
	if not self._ports.isOwned(ownerId) then
		self._ports.freeze(ownerId)
		return false
	end
	local facts = self._ports.facts(userId, ownerId, action)
	local result = model:act(userId, action, self._ports.now(), {
		distance = facts.distance,
		alive = facts.alive,
		participants = participants(self, ownerId, model),
	})
	if result.changed then
		self._ports.changed(ownerId)
		self._ports.broadcast()
	end
	self._ports.notice(userId, result.message, result.ok == true)
	return result.ok == true
end

local function socialize(self: Session, userId: number, action: Action): boolean
	local ports = self._ports
	local kind = action.kind
	if kind == "sync" then
		ports.sync(userId)
		return true
	elseif kind == "home" then
		self:travel(userId, userId)
		ports.sync(userId)
		return true
	end
	local otherId = action.userId
	if otherId == nil then
		return false
	end
	local other = self._players[otherId]
	local player = self._players[userId]
	if other == nil or otherId == userId then
		ports.notice(userId, "That player is no longer available.", false)
		return false
	end
	if kind == "visit" then
		if not island(self, otherId) then
			ports.notice(userId, "That island is still loading or unavailable.", false)
			return false
		end
		self:travel(userId, otherId)
		ports.notice(userId, "Welcome to " .. other.displayName .. "'s island. An invitation is needed to help.", true)
	elseif kind == "invite" then
		local own = island(self, userId)
		if not own then
			ports.notice(userId, "Your island is unavailable right now.", false)
			return false
		end
		if own:canEdit(otherId) then
			ports.notice(userId, "This player is already a helper.", false)
			return false
		end
		local pending = self._invitations[otherId] or {}
		self._invitations[otherId] = pending
		local now = ports.now()
		if (pending[userId] or 0) > now then
			ports.notice(userId, "Your invitation is already waiting for a reply.", false)
			return false
		end
		pending[userId] = now + 60
		ports.notice(otherId, player.displayName .. " invited you to help. Open Crew to accept.", true)
		ports.notice(userId, "Invitation sent. It expires in 60 seconds.", true)
	elseif kind == "acceptInvite" or kind == "declineInvite" then
		local pending = self._invitations[userId]
		local expiresAt = pending and pending[otherId]
		local host = island(self, otherId)
		if not host or not pending or not expiresAt or expiresAt <= ports.now() then
			ports.notice(userId, "This invitation has expired.", false)
			return false
		end
		pending[otherId] = nil
		if kind == "acceptInvite" then
			if not host:setHelper(userId, true) then
				ports.notice(userId, "This island's crew is full or unavailable.", false)
				return false
			end
			self:travel(userId, otherId)
			ports.notice(userId, "You're helping " .. other.displayName .. ". Progress stays on their island.", true)
			ports.notice(otherId, player.displayName .. " joined your crew.", true)
		end
	elseif kind == "revoke" then
		local own = island(self, userId)
		if not own then
			return false
		end
		own:setHelper(otherId, false)
		if self._invitations[otherId] then
			self._invitations[otherId][userId] = nil
		end
		if self:current(otherId) == userId then
			self:travel(otherId, otherId)
		end
		ports.notice(otherId, "Your helper access has ended. Welcome home.", false)
	end
	ports.broadcast()
	return true
end

function Session.request(self: Session, userId: number, rawAction: any, promptOwnerId: number?): boolean
	if not validUserId(userId) or self._players[userId] == nil or not allowedRequest(self, userId) then
		return false
	end
	if type(rawAction) ~= "table" or type(rawAction.kind) ~= "string" or #rawAction.kind > 24 then
		return false
	end
	local kind = rawAction.kind
	if not gameplay[kind] and not social[kind] then
		return false
	end
	if rawAction.target ~= nil and (type(rawAction.target) ~= "string" or #rawAction.target > 40) then
		return false
	end
	if promptOwnerId ~= nil and (not validUserId(promptOwnerId) or not gameplay[kind]) then
		return false
	end
	-- Drop client-supplied balances, ownership, distance and participant counts.
	local action: Action = { kind = kind, target = rawAction.target }
	if gameplay[kind] then
		return play(self, userId, action, promptOwnerId)
	end
	if kind ~= "sync" and kind ~= "home" then
		if not validUserId(rawAction.userId) then
			return false
		end
		action.userId = rawAction.userId
	end
	return socialize(self, userId, action)
end

function Session.closeIsland(self: Session, ownerId: number, message: string)
	for _, pending in self._invitations do
		pending[ownerId] = nil
	end
	for userId in self._players do
		if userId ~= ownerId and self:current(userId) == ownerId then
			self:travel(userId, userId)
			self._ports.notice(userId, message, false)
		end
	end
end

function Session.remove(self: Session, userId: number)
	if self._players[userId] == nil then
		return
	end
	self._players[userId] = nil
	self._current[userId] = nil
	self._buckets[userId] = nil
	self._invitations[userId] = nil
	for ownerId in self._players do
		local model = island(self, ownerId)
		if model then
			model:setHelper(userId, false)
		end
	end
	self:closeIsland(userId, "The island owner left. Your work stays on their island.")
end

function Session.tick(self: Session)
	local now = self._ports.now()
	for userId, pending in self._invitations do
		for ownerId, expiresAt in pending do
			if expiresAt <= now then
				pending[ownerId] = nil
			end
		end
		if next(pending) == nil then
			self._invitations[userId] = nil
		end
	end
end

return Session
