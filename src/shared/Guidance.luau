--!strict
-- Pure snapshot presentation used by the real HUD. This never grants permission,
-- predicts rewards, changes tutorial progress, or mutates an island record.
type ConfigData = {
	ProjectOrder: { string },
	Projects: { [string]: { label: string, cost: { [string]: number }, prerequisite: string? } },
	RepairCooldown: number,
}
local runtimeGame = (getfenv() :: any).game
local runtimeRequire: any = require
local Config: ConfigData = if runtimeGame ~= nil
	then runtimeRequire(runtimeGame:GetService("ReplicatedStorage").Shared.Config)
	else require("./Config") :: any
local ClientPolicy = if runtimeGame ~= nil
	then runtimeRequire(runtimeGame:GetService("ReplicatedStorage").Shared.ClientPolicy)
	else require("./ClientPolicy")

export type Snapshot = {
	island: {
		ownerId: number,
		accepting: boolean?,
		stockpile: { [string]: number },
		projects: { [string]: boolean },
		tutorialStage: number,
		nextEventAt: number,
		event: { phase: string, endsAt: number, progress: number, required: number, serial: number }?,
		helpers: { number },
	}?,
	ownerName: string,
	isOwner: boolean,
	canEdit: boolean,
	saveStatus: string,
	studioMode: boolean,
	players: { { userId: number, hasIsland: boolean } },
	invites: { { ownerId: number } },
}

export type View = {
	role: string,
	islandName: string,
	summary: string,
	detail: string,
	saveLabel: string,
	saveWarning: boolean,
	projects: { [string]: { built: boolean, cost: string, action: string, enabled: boolean } },
	event: { status: string, button: string, enabled: boolean, progress: number },
}

local Guidance = {}

local function clockText(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function materials(wood: number, stone: number, deficit: boolean): string
	local parts = {}
	local more = if deficit then " more" else ""
	if wood > 0 or not deficit then
		table.insert(parts, tostring(wood) .. more .. " wood")
	end
	if stone > 0 then
		table.insert(parts, tostring(stone) .. more .. " stone")
	end
	return table.concat(parts, " + ")
end

function Guidance.present(snapshot: Snapshot?, now: number, localUserId: number): View
	local island = if snapshot then snapshot.island else nil
	local editable = ClientPolicy.canEdit(snapshot)
	local recovery = snapshot ~= nil and snapshot.saveStatus == "recovery"
	local paused = island ~= nil
		and (
			island.accepting == false
			or (snapshot ~= nil and snapshot.saveStatus == "loading")
			or (snapshot ~= nil and snapshot.isOwner and not editable)
		)
	local view: View = {
		role = if recovery then "Paused" else "Loading",
		islandName = if recovery then "Island unavailable" else "Preparing your island…",
		summary = if recovery then "Unable to load this island" else "Loading your island…",
		detail = if recovery
			then "Your island is unavailable. Visit friends or accept an invitation in Crew. Rejoin to try loading your island again."
			else "Loading saved progress and preparing your island. You can visit friends or answer invitations in Crew while you wait.",
		saveLabel = "Loading saved progress…",
		saveWarning = recovery,
		projects = {},
		event = {
			status = if recovery
				then "Visit friends from Crew while your island is unavailable."
				else "Your island is getting ready.",
			button = if recovery then "Island unavailable" else "Waiting for island",
			enabled = false,
			progress = 0,
		},
	}
	local nextProject: string? = nil
	for _, id in Config.ProjectOrder do
		local project = Config.Projects[id]
		local built = island ~= nil and island.projects[id] == true
		local unlocked = island ~= nil and (not project.prerequisite or island.projects[project.prerequisite] == true)
		local affordable = island ~= nil
			and (island.stockpile.wood or 0) >= project.cost.wood
			and (island.stockpile.stone or 0) >= project.cost.stone
		view.projects[id] = {
			built = built,
			cost = if built then "Completed" else materials(project.cost.wood, project.cost.stone, false),
			action = if built
				then "Built"
				elseif not unlocked then "Locked"
				elseif not affordable then "Gather"
				else "Build",
			enabled = ClientPolicy.canRequest(snapshot, localUserId, { kind = "build", target = id }) == true
				and unlocked
				and affordable
				and not built,
		}
		if not built and not nextProject then
			nextProject = id
		end
	end
	if snapshot then
		local statuses: { [string]: string } = {
			loading = "Loading saved progress…",
			session = "Session only",
			saved = "Progress saved",
			pending = "Unsaved changes · saving soon",
			saving = "Saving progress…",
			recovery = if editable then "Retrying save…" else "Save unavailable · building paused",
		}
		view.saveLabel = statuses[snapshot.saveStatus] or "Checking save status…"
		if snapshot.studioMode then
			view.saveLabel ..= if snapshot.saveStatus == "session" then " • Studio" else " • Studio session only"
		end
	end
	if not island or not snapshot then
		return view
	end
	view.role = if paused then "Paused" elseif snapshot.isOwner then "Owner" elseif editable then "Helper" else "Visitor"
	view.islandName = if snapshot.isOwner then "Your island" else snapshot.ownerName .. "'s island"
	local event = island.event
	if paused then
		view.summary = "Island actions are paused"
		view.detail = if snapshot.saveStatus == "loading"
			then "This island is still loading. Use Crew to visit friends or answer invitations while you wait."
			elseif
				snapshot.isOwner
			then "Saving is unavailable and this island is paused. Rejoin to reconnect before gathering or building again."
			else "This host island is paused. Use Crew to return home or visit another island while the host reconnects."
		view.event.status = "This island is paused. No storm actions are available."
		view.event.button = "Island actions paused"
		return view
	elseif not editable then
		view.summary = "Explore " .. snapshot.ownerName .. "'s island"
		view.detail =
			"You are visiting. Ask the host for an invitation, then accept it in Crew to gather and build here."
	elseif event and event.phase == "active" then
		view.summary = "Protect the beacon · " .. clockText(event.endsAt - now)
		view.detail = if now < event.endsAt
			then "Use the repair stations together. Each builder can repair every "
				.. Config.RepairCooldown
				.. " seconds; rewards stay with the host island."
			else "The server is resolving this storm. Wait for the confirmed result before starting another challenge."
	elseif nextProject then
		local project = Config.Projects[nextProject]
		local woodNeeded = math.max(0, project.cost.wood - (island.stockpile.wood or 0))
		local stoneNeeded = math.max(0, project.cost.stone - (island.stockpile.stone or 0))
		if woodNeeded > 0 or stoneNeeded > 0 then
			view.summary = "Gather for the " .. project.label
			view.detail = "Gather "
				.. materials(woodNeeded, stoneNeeded, true)
				.. ". "
				.. if stoneNeeded > 0
					then "Cross the bridge to mine stone; use tree prompts for wood. Supplies stay with this host island."
					else "Find a tree and use its prompt. Supplies go into this island's shared stockpile."
		else
			view.summary = "Build the " .. project.label
			view.detail = "Materials are ready. Walk to the marked "
				.. project.label
				.. " site and use its prompt or the Build button below."
		end
	elseif island.tutorialStage >= 5 then
		view.summary = "An island worth coming back to"
		view.detail = if snapshot.isOwner
			then "This island is complete. Invite friends, gather supplies, and defend the beacon again when it recharges."
			else "This host island is complete. Gather supplies while the host readies the next storm, or use Crew to return home."
	else
		view.summary = "Weather your first storm"
		view.detail =
			"The host starts the storm at the beacon. Use the three repair stations together until the repair goal is met."
	end
	if event and event.phase == "active" then
		local remaining = event.endsAt - now
		view.event.status =
			string.format("%d / %d repairs  •  %s left", event.progress, event.required, clockText(remaining))
		view.event.button = if not editable
			then "Watching the storm"
			elseif remaining > 0 then "Use the repair stations"
			else "Resolving storm…"
		view.event.progress = math.clamp(event.progress / math.max(1, event.required), 0, 1)
	else
		view.event.progress = if event and event.phase == "success" then 1 else 0
		if not island.projects.beacon then
			view.event.status = "Complete the beacon to begin."
			view.event.button = "Beacon required"
		elseif island.nextEventAt > now then
			local result = if event and event.phase == "success"
				then "Storm survived!"
				elseif event and event.phase == "failed" then "Storm ended."
				else "The island is recovering."
			view.event.status = result .. " Next storm in " .. clockText(island.nextEventAt - now) .. "."
			view.event.button = "Beacon recharging"
		elseif snapshot.isOwner then
			view.event.status = "Ready for a challenge? Stand near the beacon to start."
			view.event.button = "Start storm"
			view.event.enabled = ClientPolicy.canRequest(snapshot, localUserId, { kind = "startEvent" })
		else
			view.event.status = if editable
				then "The host starts the storm. Stay nearby to help repair."
				else "The host starts the storm. Accept an invitation to help."
			view.event.button = "Host starts the storm"
		end
	end
	return view
end

return Guidance
