--!nonstrict
-- Roblox integration: untrusted requests enter here; island rules never yield.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Island = require(script.Parent.Island)
local Persistence = require(script.Parent.Persistence)
local World = require(script.Parent.World)

local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
remotes.Parent = ReplicatedStorage
local actionRemote = Instance.new("RemoteEvent")
actionRemote.Name = "Action"
actionRemote.Parent = remotes
local stateRemote = Instance.new("RemoteEvent")
stateRemote.Name = "State"
stateRemote.Parent = remotes

local studio = RunService:IsStudio()
local sessionOnly = studio and ServerScriptService:GetAttribute("EnableStudioPersistence") ~= true
local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = copy(item)
	end
	return result
end

local adapter = {}
if sessionOnly then
	local records = {}
	function adapter:update(key, transform)
		local nextValue = transform(copy(records[key]))
		if nextValue ~= nil then
			records[key] = copy(nextValue)
		end
		return true, copy(nextValue)
	end
else
	-- GetDataStore itself can fail; production never silently switches to fake saves.
	local ok, dataStore = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStoreName .. (studio and "_Studio" or ""))
	end)
	function adapter:update(key, transform)
		if not ok then
			return false, "Data store unavailable"
		end
		local lastError
		for attempt = 1, 3 do
			local success, result = pcall(function()
				return dataStore:UpdateAsync(key, transform)
			end)
			if success then
				return true, result
			end
			lastError = result
			if attempt < 3 then
				task.wait(attempt * 0.75)
			end
		end
		warn("[Driftwood] Data store request failed:", tostring(lastError))
		return false, "Saving is temporarily unavailable"
	end
end

local persistence = Persistence.new(adapter, {
	sessionId = (game.JobId ~= "" and game.JobId or "studio") .. ":" .. HttpService:GenerateGUID(false),
	now = os.time,
	leaseSeconds = Config.LeaseSeconds,
})
local world = World.create(Config)
local runtimes = {}
local slots = {}
local currentIsland = {}
local invitations = {}
local buckets = {}
local shuttingDown = false

local function notice(player, message, ok)
	if player.Parent == Players then
		stateRemote:FireClient(player, { kind = "notice", message = message, ok = ok == true })
	end
end

local function findPlayer(userId)
	return Players:GetPlayerByUserId(userId)
end

local function healthyRuntime(ownerId)
	local runtime = ownerId and runtimes[ownerId]
	if runtime and runtime.model and not runtime.closing and runtime.model.accepting then
		return runtime
	end
	return nil
end

local function avatar(player)
	local character = player.Character
	if not character then
		return nil, nil
	end
	return character:FindFirstChild("HumanoidRootPart"), character:FindFirstChildOfClass("Humanoid")
end

local function teleport(player, ownerId)
	local target = healthyRuntime(ownerId) and ownerId or nil
	currentIsland[player.UserId] = target or player.UserId
	local root, humanoid = avatar(player)
	if root and humanoid and humanoid.Health > 0 then
		local spawn = world:getSpawn(target)
		if spawn then
			player.Character:PivotTo(spawn)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function sendSnapshot(player)
	if player.Parent ~= Players then
		return
	end
	local runtime = runtimes[currentIsland[player.UserId] or player.UserId]
	local ownRuntime = runtimes[player.UserId]
	local now = os.time()
	local playerList = {}
	for _, other in ipairs(Players:GetPlayers()) do
		table.insert(playerList, {
			userId = other.UserId,
			displayName = other.DisplayName,
			hasIsland = healthyRuntime(other.UserId) ~= nil,
		})
	end
	table.sort(playerList, function(a, b)
		return a.userId < b.userId
	end)
	local pending = {}
	for ownerId, expiresAt in pairs(invitations[player.UserId] or {}) do
		local host = healthyRuntime(ownerId)
		if expiresAt > now and host then
			table.insert(pending, { ownerId = ownerId, ownerName = host.ownerName })
		end
	end
	table.sort(pending, function(a, b)
		return a.ownerId < b.ownerId
	end)
	stateRemote:FireClient(player, {
		kind = "snapshot",
		island = runtime and runtime.model and runtime.model:snapshot(now) or nil,
		ownerName = runtime and runtime.ownerName or player.DisplayName,
		isOwner = runtime ~= nil and runtime.ownerId == player.UserId,
		canEdit = runtime ~= nil and runtime.model ~= nil and not runtime.closing and runtime.model:canEdit(
			player.UserId
		),
		saveStatus = runtime and runtime.saveStatus or (ownRuntime and ownRuntime.saveStatus or "loading"),
		studioMode = sessionOnly,
		players = playerList,
		invites = pending,
		now = now,
	})
end

local function broadcast()
	for _, player in ipairs(Players:GetPlayers()) do
		sendSnapshot(player)
	end
end

local function returnVisitors(ownerId, message)
	for _, player in ipairs(Players:GetPlayers()) do
		if currentIsland[player.UserId] == ownerId and player.UserId ~= ownerId then
			teleport(player, player.UserId)
			notice(player, message, false)
		end
	end
end

local function freeze(runtime, message)
	if runtime.model and runtime.model.accepting then
		runtime.model:close()
		world:updateIsland(runtime.ownerId, runtime.model:snapshot(os.time()))
	end
	runtime.saveStatus = "recovery"
	returnVisitors(runtime.ownerId, "This island is paused while its save connection recovers.")
	local owner = findPlayer(runtime.ownerId)
	if owner then
		notice(owner, message, false)
	end
	broadcast()
end

local function markChanged(runtime)
	runtime.version += 1
	if not sessionOnly then
		runtime.saveStatus = "pending"
	end
	world:updateIsland(runtime.ownerId, runtime.model:snapshot(os.time()))
end

local function save(runtime)
	if runtime.saving or runtime.closing or not runtime.model or not runtime.model.accepting then
		return
	end
	runtime.saving = true
	runtime.lastSaveAttempt = os.time()
	local version = runtime.version
	local record = copy(runtime.model.record)
	if not sessionOnly then
		runtime.saveStatus = "saving"
	end
	local ok, reason = persistence:save(runtime.ownerId, record)
	runtime.saving = false
	if runtime.closing then
		return
	end
	if ok then
		runtime.lastSaveAt = os.time()
		runtime.saveStatus = sessionOnly and "session" or (runtime.version == version and "saved" or "pending")
	else
		local owned = persistence:isOwned(runtime.ownerId)
		if not owned then
			freeze(runtime, "Your island is safely paused. Please rejoin to reconnect to your saved progress.")
		else
			runtime.saveStatus = sessionOnly and "session" or "recovery"
			warn("[Driftwood] Save retry needed for", runtime.ownerId, reason)
		end
	end
end

local function allowedRequest(player)
	local now = os.clock()
	local bucket = buckets[player.UserId]
	if not bucket then
		bucket = { tokens = 12, updated = now }
		buckets[player.UserId] = bucket
	end
	bucket.tokens = math.min(12, bucket.tokens + (now - bucket.updated) * 5)
	bucket.updated = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function validUserId(value)
	return type(value) == "number" and value == value and math.abs(value) < 2 ^ 53 and value ~= 0 and value % 1 == 0
end

local function participants(ownerId)
	local runtime = healthyRuntime(ownerId)
	local count = 0
	if runtime then
		for _, player in ipairs(Players:GetPlayers()) do
			local _, humanoid = avatar(player)
			if
				currentIsland[player.UserId] == ownerId
				and runtime.model:canEdit(player.UserId)
				and humanoid
				and humanoid.Health > 0
			then
				count += 1
			end
		end
	end
	return math.clamp(count, 1, Config.MaxPlayers)
end

local function playAction(player, ownerId, action)
	local runtime = healthyRuntime(ownerId)
	if not runtime or currentIsland[player.UserId] ~= ownerId then
		notice(player, "Visit this island before interacting with it.", false)
		return
	end
	if not persistence:isOwned(ownerId) then
		freeze(runtime, "Your save session expired. Please rejoin before continuing.")
		return
	end
	local root, humanoid = avatar(player)
	local targetPosition = world:getTargetPosition(ownerId, action.kind, action.target)
	local distance = (root and targetPosition) and (root.Position - targetPosition).Magnitude or math.huge
	local result = runtime.model:act(player.UserId, action, os.time(), {
		distance = distance,
		alive = humanoid ~= nil and humanoid.Health > 0,
		participants = participants(ownerId),
	})
	if result.changed then
		markChanged(runtime)
		broadcast()
	end
	notice(player, result.message, result.ok)
end

local function socialAction(player, action)
	local kind = action.kind
	if kind == "sync" then
		sendSnapshot(player)
		return
	elseif kind == "home" then
		teleport(player, player.UserId)
		sendSnapshot(player)
		return
	end
	if not validUserId(action.userId) then
		return
	end
	local other = findPlayer(action.userId)
	if not other or other == player then
		notice(player, "That player is no longer available.", false)
		return
	end
	if kind == "visit" then
		if healthyRuntime(other.UserId) then
			teleport(player, other.UserId)
			notice(player, "Welcome to " .. other.DisplayName .. "'s island. An invitation is needed to help.", true)
		else
			notice(player, "That island is still loading or unavailable.", false)
		end
	elseif kind == "invite" then
		local own = healthyRuntime(player.UserId)
		if not own then
			notice(player, "Your island is unavailable right now.", false)
			return
		end
		if own.model:canEdit(other.UserId) then
			notice(player, "This player is already a helper.", false)
			return
		end
		invitations[other.UserId] = invitations[other.UserId] or {}
		if (invitations[other.UserId][player.UserId] or 0) > os.time() then
			notice(player, "Your invitation is already waiting for a reply.", false)
			return
		end
		invitations[other.UserId][player.UserId] = os.time() + 60
		notice(other, player.DisplayName .. " invited you to help. Open Crew to accept.", true)
		notice(player, "Invitation sent. It expires in 60 seconds.", true)
	elseif kind == "acceptInvite" or kind == "declineInvite" then
		local pending = invitations[player.UserId]
		local expiresAt = pending and pending[other.UserId]
		local host = healthyRuntime(other.UserId)
		if not host or not expiresAt or expiresAt <= os.time() then
			notice(player, "This invitation has expired.", false)
			return
		end
		pending[other.UserId] = nil
		if kind == "acceptInvite" then
			if not host.model:setHelper(player.UserId, true) then
				notice(player, "This island's crew is full or unavailable.", false)
				return
			end
			teleport(player, other.UserId)
			notice(player, "You're helping " .. host.ownerName .. ". Progress stays on their island.", true)
			notice(other, player.DisplayName .. " joined your crew.", true)
		end
	elseif kind == "revoke" then
		local own = healthyRuntime(player.UserId)
		if own then
			own.model:setHelper(other.UserId, false)
			if invitations[other.UserId] then
				invitations[other.UserId][player.UserId] = nil
			end
			if currentIsland[other.UserId] == player.UserId then
				teleport(other, other.UserId)
			end
			notice(other, "Your helper access has ended. Welcome home.", false)
		end
	end
	broadcast()
end

actionRemote.OnServerEvent:Connect(function(player, action)
	if shuttingDown or not allowedRequest(player) or type(action) ~= "table" then
		return
	end
	if type(action.kind) ~= "string" or #action.kind > 24 then
		return
	end
	if action.target ~= nil and (type(action.target) ~= "string" or #action.target > 40) then
		return
	end
	if action.kind == "harvest" or action.kind == "build" or action.kind == "startEvent" or action.kind == "repair" then
		playAction(player, currentIsland[player.UserId], { kind = action.kind, target = action.target })
	else
		socialAction(player, action)
	end
end)

world.onAction = function(player, ownerId, action)
	if not shuttingDown and allowedRequest(player) then
		playAction(player, ownerId, action)
	end
end

local function removeInvitations(userId)
	invitations[userId] = nil
	for _, pending in pairs(invitations) do
		pending[userId] = nil
	end
end

local function closeRuntime(runtime)
	if runtime.closing then
		return
	end
	runtime.closing = true
	if runtime.model then
		runtime.model:close()
		world:updateIsland(runtime.ownerId, runtime.model:snapshot(os.time()))
	end
	returnVisitors(runtime.ownerId, "The island owner left. Your work stays on their island.")
	removeInvitations(runtime.ownerId)
	local deadline = os.clock() + 20
	while (runtime.loading or runtime.saving) and os.clock() < deadline do
		task.wait(0.1)
	end
	local record = runtime.model and runtime.model.record or runtime.loadedRecord
	if record and not runtime.loading and not runtime.saving then
		local ok, reason = persistence:release(runtime.ownerId, copy(record))
		if not ok then
			warn("[Driftwood] Final save not confirmed for", runtime.ownerId, reason)
		end
	end
	persistence:abandon(runtime.ownerId)
	world:removeIsland(runtime.ownerId)
	slots[runtime.slot] = nil
	if runtimes[runtime.ownerId] == runtime then
		runtimes[runtime.ownerId] = nil
	end
	broadcast()
end

local function addPlayer(player)
	if shuttingDown then
		return
	end
	-- A replacement Player may arrive while the previous instance is still saving.
	-- Do not confuse it with duplicate initialization of the same Player object.
	local joinDeadline = os.clock() + 25
	while runtimes[player.UserId] do
		if runtimes[player.UserId].player == player then
			return
		end
		if shuttingDown or player.Parent ~= Players then
			return
		end
		if os.clock() >= joinDeadline then
			player:Kick("Your previous island session is still closing. Please rejoin shortly.")
			return
		end
		task.wait(0.1)
	end
	if player.Parent ~= Players then
		return
	end
	local slot
	repeat
		for index = 1, Config.MaxPlayers do
			if not slots[index] then
				slot = index
				break
			end
		end
		if slot then
			break
		end
		local closingSlot = false
		for _, existing in pairs(runtimes) do
			if existing.closing then
				closingSlot = true
				break
			end
		end
		if not closingSlot or os.clock() >= joinDeadline then
			break
		end
		task.wait(0.1)
		if shuttingDown or player.Parent ~= Players then
			return
		end
	until false
	if not slot then
		player:Kick("This island server is full. Please join another server.")
		return
	end
	slots[slot] = player.UserId
	local runtime = {
		player = player,
		ownerId = player.UserId,
		ownerName = player.DisplayName,
		slot = slot,
		loading = true,
		closing = false,
		saving = false,
		saveStatus = "loading",
		version = 0,
		lastSaveAt = os.time(),
		lastSaveAttempt = os.time(),
	}
	runtimes[player.UserId] = runtime
	currentIsland[player.UserId] = player.UserId
	player.CharacterAdded:Connect(function(character)
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if root and player.Parent == Players then
			teleport(player, currentIsland[player.UserId] or player.UserId)
		end
	end)
	teleport(player, nil)
	sendSnapshot(player)
	local record, reason = persistence:load(player.UserId, Island.defaultRecord(player.UserId))
	local loadDeadline = os.clock() + 10
	while not record and reason == "busy" and os.clock() < loadDeadline and not runtime.closing do
		task.wait(0.2)
		record, reason = persistence:load(player.UserId, Island.defaultRecord(player.UserId))
	end
	runtime.loadedRecord = record
	runtime.loading = false
	if runtime.closing or player.Parent ~= Players then
		return
	end
	if not record then
		runtime.saveStatus = "recovery"
		notice(
			player,
			"Your island could not be loaded. Please rejoin shortly; existing progress has not been reset.",
			false
		)
		warn("[Driftwood] Load failed for", player.UserId, reason)
		sendSnapshot(player)
		return
	end
	local validRecord, validationError = Island.validateRecord(record, player.UserId)
	if not validRecord then
		persistence:abandon(player.UserId)
		runtime.loadedRecord = nil
		runtime.saveStatus = "recovery"
		notice(player, "Your island data needs recovery. No replacement island has been saved.", false)
		warn("[Driftwood] Invalid profile for", player.UserId, validationError)
		sendSnapshot(player)
		return
	end
	runtime.model = Island.new(player.UserId, validRecord)
	runtime.saveStatus = sessionOnly and "session" or "saved"
	world:addIsland(player.UserId, slot, player.DisplayName, runtime.model:snapshot(os.time()))
	teleport(player, player.UserId)
	broadcast()
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(addPlayer, player)
end)
Players.PlayerRemoving:Connect(function(player)
	currentIsland[player.UserId] = nil
	buckets[player.UserId] = nil
	removeInvitations(player.UserId)
	for _, other in pairs(runtimes) do
		if other.model then
			other.model:setHelper(player.UserId, false)
		end
	end
	local runtime = runtimes[player.UserId]
	if runtime then
		closeRuntime(runtime)
	end
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(addPlayer, player)
end

task.spawn(function()
	while not shuttingDown do
		task.wait(1)
		local now = os.time()
		for _, runtime in pairs(runtimes) do
			if runtime.model and runtime.model.accepting and not runtime.closing then
				if not persistence:isOwned(runtime.ownerId) then
					freeze(runtime, "Your save session expired. Please rejoin before continuing.")
				else
					if runtime.model:tick(now) then
						markChanged(runtime)
					end
					world:updateIsland(runtime.ownerId, runtime.model:snapshot(now))
					local retry = runtime.saveStatus == "recovery" and 5 or Config.AutosaveSeconds
					if now - runtime.lastSaveAttempt >= retry then
						task.spawn(save, runtime)
					end
				end
			end
		end
		for _, pending in pairs(invitations) do
			for ownerId, expiresAt in pairs(pending) do
				if expiresAt <= now then
					pending[ownerId] = nil
				end
			end
		end
		for _, player in ipairs(Players:GetPlayers()) do
			local root = avatar(player)
			if root and root.Position.Y < -20 then
				teleport(player, currentIsland[player.UserId] or player.UserId)
			end
		end
		broadcast()
	end
end)

game:BindToClose(function()
	shuttingDown = true
	local remaining = 0
	for _, runtime in pairs(runtimes) do
		remaining += 1
		task.spawn(function()
			if runtime.closing then
				while runtimes[runtime.ownerId] == runtime do
					task.wait(0.1)
				end
			else
				closeRuntime(runtime)
			end
			remaining -= 1
		end)
	end
	local deadline = os.clock() + 25
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)
