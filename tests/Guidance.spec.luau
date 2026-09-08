--!strict
-- The production HUD consumes this presenter; no fake engine UI or copied rules.
local Guidance = require("../src/shared/Guidance")
local Island = require("../src/server/Island")
local Config = require("../src/shared/Config")

local function equal(actual: any, expected: any, message: string)
	assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function contains(actual: string, fragment: string, message: string)
	assert(string.find(actual, fragment, 1, true) ~= nil, message .. ": " .. actual)
end

local function snapshot(model: any?): any
	local island: any = model or Island.new(101)
	return {
		island = island:snapshot(100),
		ownerName = "Harbor",
		isOwner = true,
		canEdit = true,
		saveStatus = "saved",
		studioMode = false,
		players = { { userId = 101, hasIsland = true } },
		invites = {},
	}
end

local function ready(): any
	local state = snapshot()
	for _, id in Config.ProjectOrder do
		state.island.projects[id] = true
	end
	state.island.tutorialStage = 4
	return state
end

return function()
	local waiting = Guidance.present(nil, 100, 101)
	equal(waiting.role, "Loading", "initial role")
	equal(waiting.summary, "Loading your island…", "initial next step")
	equal(waiting.event.enabled, false, "initial event unavailable")
	local failed = snapshot()
	failed.island = nil
	failed.canEdit = false
	failed.saveStatus = "recovery"
	local recovery = Guidance.present(failed, 100, 101)
	equal(recovery.role, "Paused", "failed load is not a blank new island")
	contains(recovery.detail, "Crew", "safe recovery route")
	contains(recovery.detail, "Rejoin", "retry route")
	for _, id in Config.ProjectOrder do
		equal(recovery.projects[id].enabled, false, "failed load cannot build " .. id)
	end
	print("PASS Guidance: initial and failed-load guidance preserves safe recovery without inventing progress")

	local state = snapshot()
	local view = Guidance.present(state, 100, 101)
	equal(view.summary, "Gather for the Campfire", "first interaction explained")
	contains(view.detail, "12 more wood", "exact first deficit")
	equal(view.projects.campfire.cost, "12 wood", "campfire price")
	equal(view.projects.bridge.action, "Locked", "bridge requires campfire")
	state.island.stockpile.wood = 12
	view = Guidance.present(state, 100, 101)
	equal(view.summary, "Build the Campfire", "affordable objective")
	contains(view.detail, "marked Campfire site", "button is not remote building")
	equal(view.projects.campfire.enabled, true, "build enabled when affordable")
	print("PASS Guidance: first-session wood and campfire instructions follow shared stockpile affordability")

	state.island.projects.campfire = true
	state.island.stockpile.wood = 29
	view = Guidance.present(state, 100, 101)
	contains(view.detail, "1 more wood", "bridge deficit uses current supplies")
	equal(view.projects.campfire.action, "Built", "completed card is retained")
	equal(view.projects.campfire.enabled, false, "completed project cannot rebuild")
	state.island.projects.bridge = true
	state.island.stockpile.wood = 39
	state.island.stockpile.stone = 18
	view = Guidance.present(state, 100, 101)
	contains(view.detail, "1 more wood + 2 more stone", "both beacon deficits shown")
	contains(view.detail, "Cross the bridge", "unlocked resource location explained")
	equal(view.projects.beacon.cost, "40 wood + 20 stone", "beacon full price")
	state.island.stockpile.wood = 40
	state.island.stockpile.stone = 20
	equal(Guidance.present(state, 100, 101).projects.beacon.enabled, true, "exact-price beacon enabled")
	print("PASS Guidance: bridge and beacon cards explain prerequisites, exact deficits, and world sites")

	local complete = ready()
	view = Guidance.present(complete, 100, 101)
	equal(view.summary, "Weather your first storm", "beacon leads to first storm")
	equal(view.event.enabled, true, "owner starts ready storm")
	complete.island.tutorialStage = 5
	view = Guidance.present(complete, 100, 101)
	equal(view.summary, "An island worth coming back to", "finished onboarding does not restart")
	local model = Island.new(101, complete.island)
	local reloaded = snapshot(Island.new(101, model.record))
	equal(Guidance.present(reloaded, 100, 101).summary, view.summary, "real saved-record reload keeps completion")
	for _, id in Config.ProjectOrder do
		equal(Guidance.present(reloaded, 100, 101).projects[id].action, "Built", "reload retains " .. id)
	end
	print("PASS Guidance: persisted completion resumes after reload without forced completed tutorial steps")

	local guest = ready()
	guest.isOwner = false
	guest.canEdit = false
	guest.island.event = { phase = "active", endsAt = 190, progress = 2, required = 12, serial = 1 }
	view = Guidance.present(guest, 100, 202)
	equal(view.role, "Visitor", "read-only role")
	equal(view.summary, "Explore Harbor's island", "storm does not overwrite visitor objective")
	contains(view.detail, "invitation", "visitor needs consent")
	equal(view.event.button, "Watching the storm", "visitor is not told to repair")
	equal(view.event.enabled, false, "visitor cannot start")
	guest.canEdit = true
	view = Guidance.present(guest, 100, 202)
	equal(view.role, "Helper", "accepted helper role")
	contains(view.summary, "Protect the beacon", "helper can defend")
	contains(view.detail, "host island", "helper ownership explained")
	equal(view.event.button, "Use the repair stations", "helper receives valid repair instruction")
	guest.island.event = nil
	view = Guidance.present(guest, 100, 202)
	equal(view.event.button, "Host starts the storm", "helper does not own event start")
	equal(view.event.enabled, false, "helper cannot start")
	guest.island.tutorialStage = 5
	view = Guidance.present(guest, 100, 202)
	contains(view.detail, "Crew to return home", "completed helper retains a valid next step")
	equal(string.find(view.detail, "Invite friends", 1, true), nil, "helper is not told to manage the host crew")
	contains(view.detail, "host", "completed helper still understands ownership")
	print("PASS Guidance: owner, helper, and visitor guidance remains permission-aware during storms")

	for _, isOwner in { true, false } do
		local paused = ready()
		paused.isOwner = isOwner
		paused.island.accepting = false
		paused.saveStatus = "recovery"
		paused.island.event = { phase = "active", endsAt = 190, progress = 2, required = 12, serial = 1 }
		view = Guidance.present(paused, 100, if isOwner then 101 else 202)
		equal(view.role, "Paused", "closed island role")
		equal(view.summary, "Island actions are paused", "closed island objective dominates storm")
		equal(view.event.button, "Island actions paused", "closed event is not actionable")
		equal(view.event.enabled, false, "closed event start disabled")
		contains(view.detail, if isOwner then "Rejoin" else "Crew", "role-specific recovery path")
		for _, id in Config.ProjectOrder do
			equal(view.projects[id].enabled, false, "closed project disabled " .. id)
		end
	end
	print("PASS Guidance: frozen owner and helper islands explain recovery before gameplay instructions")

	local eventState = ready()
	eventState.island.event = { phase = "active", endsAt = 190, progress = 6, required = 12, serial = 1 }
	view = Guidance.present(eventState, 189.2, 101)
	contains(view.event.status, "0:01 left", "fractional seconds round up")
	equal(view.event.progress, 0.5, "progress ratio")
	view = Guidance.present(eventState, 191, 101)
	equal(view.event.button, "Resolving storm…", "elapsed timer awaits authority")
	contains(view.event.status, "0:00 left", "timer never negative")
	contains(view.detail, "server", "no optimistic reward claim")
	eventState.island.event.phase = "failed"
	eventState.island.nextEventAt = 370
	view = Guidance.present(eventState, 190, 101)
	contains(view.event.status, "Storm ended", "failure has distinct explanation")
	equal(view.event.progress, 0, "failure is not victory")
	equal(view.event.enabled, false, "cooldown start disabled")
	eventState.island.event.phase = "success"
	view = Guidance.present(eventState, 190, 101)
	contains(view.event.status, "Storm survived", "acknowledged success")
	equal(view.event.progress, 1, "success progress complete")
	equal(Guidance.present(eventState, 370, 101).event.enabled, true, "cooldown boundary opens owner request")
	print("PASS Guidance: event countdown, resolution, failure, success, and cooldown use server state")

	local saving = snapshot()
	local expected: { [string]: string } = {
		loading = "Loading saved progress…",
		session = "Session only",
		saved = "Progress saved",
		pending = "Unsaved changes · saving soon",
		saving = "Saving progress…",
		recovery = "Retrying save…",
	}
	for status, label in expected do
		saving.saveStatus = status
		equal(Guidance.present(saving, 100, 101).saveLabel, label, status .. " production save status")
		saving.studioMode = true
		local studio = Guidance.present(saving, 100, 101).saveLabel
		contains(studio, label, status .. " remains visible in Studio")
		contains(studio, "Studio", status .. " identifies Studio")
		saving.studioMode = false
	end
	saving.saveStatus = "recovery"
	saving.canEdit = false
	view = Guidance.present(saving, 100, 101)
	equal(view.saveLabel, "Save unavailable · building paused", "frozen save status")
	equal(view.saveWarning, true, "recovery highlighted")
	saving.saveStatus = "future-status"
	equal(Guidance.present(saving, 100, 101).saveLabel, "Checking save status…", "unknown status does not claim save")
	print("PASS Guidance: all persistence and Studio states preserve truthful save and recovery labels")

	local original = snapshot()
	local first = Guidance.present(original, 100, 101)
	first.projects.campfire.cost = "changed"
	first.event.enabled = true
	local second = Guidance.present(original, 100, 101)
	equal(second.projects.campfire.cost, "12 wood", "returned cards are detached")
	equal(second.event.enabled, false, "returned event is detached")
	equal(original.island.stockpile.wood, 0, "presentation cannot spend resources")
	equal(original.island.projects.campfire, false, "presentation cannot build")
	print("PASS Guidance: presentation is detached and never mutates authoritative progress")
end
