--!strict
-- Adapter contract: update(key, transform) returns (ok, committedValueOrError).
-- A nil transform result cancels the write. The adapter may retry the transform.
local Persistence = {}
Persistence.__index = Persistence

type Lease = { revision: number, leaseUntil: number }
type Envelope = { data: any, sessionId: string, leaseUntil: number, revision: number }

local MAX_INTEGER = 9007199254740991

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function ownerIsValid(ownerId: any): boolean
	-- Studio uses negative UserIds for local multiplayer test players.
	return finite(ownerId) and ownerId ~= 0 and ownerId % 1 == 0 and math.abs(ownerId) <= MAX_INTEGER
end

local function clone(value: any, visiting: { [any]: boolean }?): any
	local kind = type(value)
	if kind ~= "table" then
		assert(kind == "string" or kind == "boolean" or (kind == "number" and finite(value)), "unsupported saved value")
		return value
	end
	assert(getmetatable(value) == nil, "saved tables cannot have metatables")
	local seen = visiting or {}
	assert(not seen[value], "saved tables cannot contain cycles")
	seen[value] = true
	local result: { [any]: any } = {}
	for key, child in pairs(value) do
		assert(type(key) == "string" or (finite(key) and key % 1 == 0), "unsupported saved key")
		result[key] = clone(child, seen)
	end
	seen[value] = nil
	return result
end

local function copyRecord(record: any, ownerId: number): (any?, string?)
	if type(record) ~= "table" or record.ownerId ~= ownerId then
		return nil, "record owner does not match"
	end
	local ok, copied = pcall(clone, record)
	if not ok then
		return nil, "record contains unsupported data"
	end
	return copied, nil
end

local function envelopeIsValid(value: any, ownerId: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	if type(value.sessionId) ~= "string" or not finite(value.leaseUntil) or value.leaseUntil < 0 then
		return false
	end
	if not finite(value.revision) or value.revision < 0 or value.revision % 1 ~= 0 or value.revision >= MAX_INTEGER then
		return false
	end
	if (value.sessionId == "") ~= (value.leaseUntil == 0) then
		return false
	end
	local record = copyRecord(value.data, ownerId)
	return record ~= nil
end

local function sameData(left: any, right: any): boolean
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	for key, value in pairs(left) do
		if not sameData(value, right[key]) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function invalidate(self: any, ownerId: number)
	self._sessions[ownerId] = nil
	self._generations[ownerId] = (self._generations[ownerId] or 0) + 1
end

function Persistence.new(adapter: any, options: any): any
	assert(type(adapter) == "table" and type(adapter.update) == "function", "an update adapter is required")
	assert(
		type(options) == "table" and type(options.sessionId) == "string" and #options.sessionId > 0,
		"a unique sessionId is required"
	)
	assert(type(options.now) == "function", "a clock is required")
	assert(finite(options.leaseSeconds) and options.leaseSeconds > 0, "leaseSeconds must be positive")
	return setmetatable({
		_adapter = adapter,
		_sessionId = options.sessionId,
		_now = options.now,
		_leaseSeconds = options.leaseSeconds,
		_sessions = {} :: { [number]: Lease },
		_busy = {} :: { [number]: boolean },
		_generations = {} :: { [number]: number },
	}, Persistence)
end

function Persistence.isOwned(self: any, ownerId: number): (boolean, number?)
	local lease: Lease? = self._sessions[ownerId]
	if not lease then
		return false, nil
	end
	if self._now() >= lease.leaseUntil then
		invalidate(self, ownerId)
		return false, lease.leaseUntil
	end
	-- This reports locally known ownership; every write also checks remote ownership.
	return true, lease.leaseUntil
end

function Persistence.abandon(self: any, ownerId: number)
	invalidate(self, ownerId)
end

local function update(self: any, ownerId: number, record: any, mode: string): (any?, string?)
	if not ownerIsValid(ownerId) then
		return nil, "invalid owner"
	end
	if self._busy[ownerId] then
		return nil, "busy"
	end
	local owned = self:isOwned(ownerId)
	if mode == "load" and owned then
		return nil, "already loaded"
	end
	if mode ~= "load" and not owned then
		return nil, "lease lost"
	end
	-- Copy before the first possible yield. Transform retries each get their own copy.
	local snapshot, copyError = copyRecord(record, ownerId)
	if not snapshot then
		return nil, copyError
	end
	local expected: Lease? = self._sessions[ownerId]
	local generation = self._generations[ownerId] or 0
	local proposal: Envelope? = nil
	local rejection: string? = nil
	self._busy[ownerId] = true

	local function transform(current: any): Envelope?
		proposal = nil
		rejection = nil
		if (self._generations[ownerId] or 0) ~= generation then
			rejection = "operation abandoned"
			return nil
		end
		local now = self._now()
		if not finite(now) or now < 0 or not finite(now + self._leaseSeconds) then
			rejection = "invalid clock"
			return nil
		end
		if current ~= nil and not envelopeIsValid(current, ownerId) then
			rejection = "malformed envelope"
			return nil
		end
		local data = snapshot
		local revision = 1
		if mode == "load" then
			if current ~= nil then
				if current.sessionId ~= "" and current.leaseUntil > now then
					rejection = "locked"
					return nil
				end
				data = current.data
				revision = current.revision + 1
			end
		else
			if
				not expected
				or now >= expected.leaseUntil
				or current == nil
				or current.sessionId ~= self._sessionId
				or now >= current.leaseUntil
				or current.revision ~= expected.revision
				or current.leaseUntil ~= expected.leaseUntil
			then
				rejection = "lease lost"
				return nil
			end
			revision = current.revision + 1
		end
		if revision >= MAX_INTEGER then
			rejection = "revision exhausted"
			return nil
		end
		proposal = {
			data = clone(data),
			sessionId = if mode == "release" then "" else self._sessionId,
			leaseUntil = if mode == "release" then 0 else now + self._leaseSeconds,
			revision = revision,
		}
		-- Keep the confirmation snapshot separate from the adapter's candidate.
		return clone(proposal)
	end

	local called, ok, result = pcall(function()
		return self._adapter:update("island:" .. tostring(ownerId), transform)
	end)
	self._busy[ownerId] = nil
	if (self._generations[ownerId] or 0) ~= generation then
		return nil, "operation abandoned"
	end
	if not called or not ok then
		-- A failed request can have committed remotely. Do not guess its revision.
		invalidate(self, ownerId)
		return nil, "storage failed: " .. tostring(if called then result else ok)
	end
	local committed = proposal
	if
		committed == nil
		or not envelopeIsValid(result, ownerId)
		or result.sessionId ~= committed.sessionId
		or result.revision ~= committed.revision
		or result.leaseUntil ~= committed.leaseUntil
		or not sameData(result.data, committed.data)
	then
		invalidate(self, ownerId)
		return nil, rejection or "update was not confirmed"
	end
	if mode == "release" then
		invalidate(self, ownerId)
	else
		if self._now() >= committed.leaseUntil then
			invalidate(self, ownerId)
			return nil, "lease lost"
		end
		self._sessions[ownerId] = { revision = committed.revision, leaseUntil = committed.leaseUntil }
	end
	return clone(committed.data), nil
end

function Persistence.load(self: any, ownerId: number, defaultRecord: any): (any?, string?)
	return update(self, ownerId, defaultRecord, "load")
end

function Persistence.save(self: any, ownerId: number, record: any): (boolean, string?)
	local saved, reason = update(self, ownerId, record, "save")
	return saved ~= nil, reason
end

function Persistence.release(self: any, ownerId: number, record: any): (boolean, string?)
	local saved, reason = update(self, ownerId, record, "release")
	return saved ~= nil, reason
end

return Persistence
