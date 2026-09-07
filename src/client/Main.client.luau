--!strict
-- The server owns all island state. This HUD only displays snapshots and requests actions.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local Config: any = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local actionRemote = remotes:WaitForChild("Action") :: RemoteEvent
local stateRemote = remotes:WaitForChild("State") :: RemoteEvent

-- A packaged Roblox action cue needs no uploaded or third-party audio asset.
-- Only a newly completed project in a server snapshot triggers playback.
local constructionSound = Instance.new("Sound")
constructionSound.Name = "DriftwoodConstruction"
constructionSound.SoundId = "rbxasset://sounds/action_jump.mp3"
constructionSound.Volume = 0.25
constructionSound.PlaybackSpeed = 1.5
constructionSound.Parent = SoundService

type IslandEvent = {
	phase: string,
	endsAt: number,
	progress: number,
	required: number,
	serial: number,
}
type IslandSnapshot = {
	ownerId: number,
	stockpile: { [string]: number },
	projects: { [string]: boolean },
	tutorialStage: number,
	nextEventAt: number,
	event: IslandEvent?,
	helpers: { number },
}
type PlayerEntry = { userId: number, displayName: string, hasIsland: boolean }
type InviteEntry = { ownerId: number, ownerName: string }
type Snapshot = {
	island: IslandSnapshot?,
	ownerName: string,
	isOwner: boolean,
	canEdit: boolean,
	saveStatus: string,
	studioMode: boolean,
	players: { PlayerEntry },
	invites: { InviteEntry },
	now: number,
}
type Action = { kind: string, target: string?, userId: number? }

local palette = {
	background = Color3.fromRGB(17, 35, 42),
	panel = Color3.fromRGB(26, 47, 53),
	row = Color3.fromRGB(36, 60, 64),
	text = Color3.fromRGB(245, 245, 230),
	muted = Color3.fromRGB(176, 198, 199),
	accent = Color3.fromRGB(151, 230, 197),
	gold = Color3.fromRGB(251, 204, 122),
	error = Color3.fromRGB(255, 178, 166),
	stroke = Color3.fromRGB(87, 123, 123),
}

local current: Snapshot? = nil
local receivedAt = os.clock()
local drawerOpen = false
local goalExpanded = false
local expansionChosen = false
local socialSignature = ""
local lastActionAt = -math.huge
local noticeSerial = 0
local progressRatio = -1
local progressTween: Tween? = nil

local function round(instance: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
end

local function outline(instance: GuiObject)
	local stroke = Instance.new("UIStroke")
	stroke.Color = palette.stroke
	stroke.Transparency = 0.55
	stroke.Thickness = 1
	stroke.Parent = instance
end

local function frame(name: string, parent: Instance, color: Color3): Frame
	local object = Instance.new("Frame")
	object.Name = name
	object.BorderSizePixel = 0
	object.BackgroundColor3 = color
	object.Parent = parent
	return object
end

local function label(
	name: string,
	parent: Instance,
	value: string,
	size: number,
	color: Color3,
	bold: boolean?
): TextLabel
	local object = Instance.new("TextLabel")
	object.Name = name
	object.BackgroundTransparency = 1
	object.BorderSizePixel = 0
	object.Text = value
	object.TextSize = size
	object.TextColor3 = color
	object.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	object.TextXAlignment = Enum.TextXAlignment.Left
	object.TextYAlignment = Enum.TextYAlignment.Center
	object.RichText = false
	object.Parent = parent
	return object
end

local function button(name: string, parent: Instance, value: string, primary: boolean?): TextButton
	local object = Instance.new("TextButton")
	object.Name = name
	object.Text = value
	object.Font = Enum.Font.GothamBold
	object.TextSize = 13
	object.TextColor3 = if primary then palette.background else palette.text
	object.BackgroundColor3 = if primary then palette.accent else palette.row
	object.BorderSizePixel = 0
	object.AutoButtonColor = true
	object.Parent = parent
	object:SetAttribute("Primary", primary == true)
	round(object, 9)
	local minimum = Instance.new("UISizeConstraint")
	minimum.MinSize = Vector2.new(44, 44)
	minimum.Parent = object
	return object
end

local function setEnabled(object: TextButton, enabled: boolean)
	object.Active = enabled
	object.Selectable = enabled
	object.AutoButtonColor = enabled
	object.BackgroundTransparency = if enabled then 0 else 0.48
	object.TextColor3 = if not enabled
		then palette.muted
		elseif object:GetAttribute("Primary") then palette.background
		else palette.text
end

local function ready(): boolean
	local snapshot = current
	return snapshot ~= nil and snapshot.island ~= nil and snapshot.saveStatus ~= "loading"
end

local function send(action: Action)
	if not ready() or os.clock() - lastActionAt < 0.35 then
		return
	end
	lastActionAt = os.clock()
	actionRemote:FireServer(action)
end

local gui = Instance.new("ScreenGui")
gui.Name = "DriftwoodHUD"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
gui.DisplayOrder = 10
gui.Parent = player:WaitForChild("PlayerGui")

local root = frame("SafeArea", gui, palette.background)
root.BackgroundTransparency = 1
root.Size = UDim2.fromScale(1, 1)

local header = frame("Header", root, palette.background)
header.BackgroundTransparency = 0.06
round(header, 13)
outline(header)

local emblem = frame("IslandMark", header, palette.accent)
emblem.Size = UDim2.fromOffset(21, 21)
emblem.Position = UDim2.fromOffset(20, 18)
emblem.Rotation = 45
round(emblem, 5)
local emblemInset = frame("Beacon", emblem, palette.background)
emblemInset.Size = UDim2.fromOffset(7, 7)
emblemInset.Position = UDim2.fromOffset(7, 7)
round(emblemInset, 2)

local title = label("Title", header, "DRIFTWOOD ISLES", 17, palette.text, true)
local islandName = label("IslandOwner", header, "Preparing your island…", 12, palette.muted)
islandName.TextTruncate = Enum.TextTruncate.AtEnd
local rolePill = frame("IslandRole", header, palette.row)
rolePill.Size = UDim2.fromOffset(66, 20)
round(rolePill, 10)
local roleLabel = label("Role", rolePill, "Loading", 10, palette.accent, true)
roleLabel.Size = UDim2.fromScale(1, 1)
roleLabel.TextXAlignment = Enum.TextXAlignment.Center

local function resourceCounter(kind: string, abbreviation: string, color: Color3): (Frame, TextLabel)
	local counter = frame(kind .. "Counter", header, palette.row)
	round(counter, 9)
	local icon = frame("Icon", counter, color)
	icon.Size = UDim2.fromOffset(22, 22)
	icon.Position = UDim2.fromOffset(9, 11)
	round(icon, 6)
	local glyph = label("Glyph", icon, abbreviation, 12, palette.background, true)
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.TextXAlignment = Enum.TextXAlignment.Center
	local name = label("ResourceName", counter, kind, 10, palette.muted)
	name.Position = UDim2.fromOffset(38, 5)
	name.Size = UDim2.new(1, -42, 0, 14)
	local value = label("Value", counter, "—", 14, palette.text, true)
	value.Position = UDim2.fromOffset(38, 18)
	value.Size = UDim2.new(1, -42, 0, 21)
	value.TextTruncate = Enum.TextTruncate.AtEnd
	return counter, value
end

local woodCounter, woodValue = resourceCounter("Wood", "W", palette.gold)
local stoneCounter, stoneValue = resourceCounter("Stone", "S", palette.muted)
local crewButton = button("Crew", header, "Crew", true)

local goal = frame("Objective", root, palette.background)
goal.BackgroundTransparency = 0.06
round(goal, 13)
outline(goal)
local goalToggle = button("ToggleObjective", goal, "")
goalToggle.BackgroundTransparency = 1
goalToggle.Size = UDim2.new(1, 0, 0, 52)
local goalEyebrow = label("Eyebrow", goalToggle, "YOUR NEXT STEP", 10, palette.accent, true)
goalEyebrow.Position = UDim2.fromOffset(14, 7)
goalEyebrow.Size = UDim2.new(1, -50, 0, 14)
local goalSummary = label("Summary", goalToggle, "Loading your island…", 14, palette.text, true)
goalSummary.Position = UDim2.fromOffset(14, 24)
goalSummary.Size = UDim2.new(1, -50, 0, 20)
goalSummary.TextTruncate = Enum.TextTruncate.AtEnd
local goalChevron = label("Expand", goalToggle, "+", 22, palette.muted)
goalChevron.Position = UDim2.new(1, -38, 0, 5)
goalChevron.Size = UDim2.fromOffset(28, 42)
goalChevron.TextXAlignment = Enum.TextXAlignment.Center

local goalScroll = Instance.new("ScrollingFrame")
goalScroll.Name = "ObjectiveDetails"
goalScroll.BackgroundTransparency = 1
goalScroll.BorderSizePixel = 0
goalScroll.ScrollBarThickness = 3
goalScroll.ScrollBarImageColor3 = palette.accent
goalScroll.ScrollingDirection = Enum.ScrollingDirection.Y
goalScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
goalScroll.CanvasSize = UDim2.new()
goalScroll.Position = UDim2.fromOffset(0, 52)
goalScroll.Size = UDim2.new(1, 0, 1, -52)
goalScroll.Parent = goal
local goalPadding = Instance.new("UIPadding")
goalPadding.PaddingLeft = UDim.new(0, 12)
goalPadding.PaddingRight = UDim.new(0, 12)
goalPadding.PaddingBottom = UDim.new(0, 12)
goalPadding.Parent = goalScroll
local goalList = Instance.new("UIListLayout")
goalList.Padding = UDim.new(0, 8)
goalList.SortOrder = Enum.SortOrder.LayoutOrder
goalList.Parent = goalScroll

local objectiveDetail =
	label("Directions", goalScroll, "Saved progress will appear here when your island is ready.", 13, palette.muted)
objectiveDetail.Size = UDim2.new(1, 0, 0, 58)
objectiveDetail.LayoutOrder = 1
objectiveDetail.TextWrapped = true
objectiveDetail.TextYAlignment = Enum.TextYAlignment.Top

type ProjectRow = { marker: TextLabel, cost: TextLabel, action: TextButton }
local projectRows: { [string]: ProjectRow } = {}
for index, id in ipairs(Config.ProjectOrder) do
	local project = Config.Projects[id]
	local row = frame(id, goalScroll, palette.panel)
	row.Size = UDim2.new(1, 0, 0, 66)
	row.LayoutOrder = index + 1
	round(row, 9)
	local marker = label("Step", row, tostring(index), 15, palette.accent, true)
	marker.Position = UDim2.fromOffset(10, 0)
	marker.Size = UDim2.fromOffset(22, 66)
	marker.TextXAlignment = Enum.TextXAlignment.Center
	local projectLabel = label("Name", row, project.label, 13, palette.text, true)
	projectLabel.Position = UDim2.fromOffset(40, 11)
	projectLabel.Size = UDim2.new(1, -118, 0, 21)
	projectLabel.TextTruncate = Enum.TextTruncate.AtEnd
	local cost = label("Cost", row, "Waiting for island", 11, palette.muted)
	cost.Position = UDim2.fromOffset(40, 33)
	cost.Size = UDim2.new(1, -118, 0, 19)
	cost.TextTruncate = Enum.TextTruncate.AtEnd
	local build = button("Build", row, "Build", true)
	build.Size = UDim2.fromOffset(66, 44)
	build.Position = UDim2.new(1, -74, 0, 11)
	setEnabled(build, false)
	build.Activated:Connect(function()
		if build.Active then
			send({ kind = "build", target = id })
		end
	end)
	projectRows[id] = { marker = marker, cost = cost, action = build }
end

local eventCard = frame("Storm", goalScroll, palette.panel)
eventCard.Size = UDim2.new(1, 0, 0, 153)
eventCard.LayoutOrder = 5
round(eventCard, 9)
local eventTitle = label("Title", eventCard, "STORM DEFENSE", 10, palette.gold, true)
eventTitle.Position = UDim2.fromOffset(12, 10)
eventTitle.Size = UDim2.new(1, -24, 0, 16)
local eventStatus = label("Status", eventCard, "Complete the beacon to begin.", 13, palette.text)
eventStatus.Position = UDim2.fromOffset(12, 30)
eventStatus.Size = UDim2.new(1, -24, 0, 35)
eventStatus.TextWrapped = true
local eventTrack = frame("ProgressTrack", eventCard, palette.background)
eventTrack.Position = UDim2.fromOffset(12, 72)
eventTrack.Size = UDim2.new(1, -24, 0, 6)
eventTrack.ClipsDescendants = true
round(eventTrack, 3)
local eventFill = frame("Progress", eventTrack, palette.accent)
eventFill.Size = UDim2.fromScale(0, 1)
round(eventFill, 3)
local eventReward = label(
	"Reward",
	eventCard,
	string.format("Reward: %d wood + %d stone", Config.EventReward.wood, Config.EventReward.stone),
	11,
	palette.muted
)
eventReward.Position = UDim2.fromOffset(12, 81)
eventReward.Size = UDim2.new(1, -24, 0, 17)
local eventButton = button("StartStorm", eventCard, "Beacon required", true)
eventButton.Position = UDim2.fromOffset(12, 101)
eventButton.Size = UDim2.new(1, -24, 0, 44)
setEnabled(eventButton, false)
eventButton.Activated:Connect(function()
	if eventButton.Active then
		send({ kind = "startEvent" })
	end
end)

local promptHelp = label(
	"Controls",
	goalScroll,
	"Use nearby world prompts to gather and repair. Build buttons also require you to stand at the site.",
	11,
	palette.muted
)
promptHelp.Size = UDim2.new(1, 0, 0, 43)
promptHelp.TextWrapped = true
promptHelp.LayoutOrder = 6
promptHelp.TextYAlignment = Enum.TextYAlignment.Top

local saveLabel = label("SaveStatus", root, "Loading saved progress…", 11, palette.text)
saveLabel.TextStrokeColor3 = palette.background
saveLabel.TextStrokeTransparency = 0.35

-- Modal contents are rebuilt only when the roster/permissions change, not every timer tick.
local veil = button("CloseCrewBackdrop", root, "")
veil.Size = UDim2.fromScale(1, 1)
veil.BackgroundColor3 = Color3.fromRGB(5, 16, 20)
veil.BackgroundTransparency = 0.38
veil.AutoButtonColor = false
veil.ZIndex = 20
veil.Visible = false
local drawer = frame("CrewDrawer", root, palette.background)
drawer.ZIndex = 21
drawer.Visible = false
round(drawer, 14)
outline(drawer)
local drawerTitle = label("Title", drawer, "Island crew", 22, palette.text, true)
drawerTitle.Position = UDim2.fromOffset(16, 12)
drawerTitle.Size = UDim2.new(1, -76, 0, 34)
local closeDrawer = button("Close", drawer, "×")
closeDrawer.TextSize = 24
closeDrawer.Position = UDim2.new(1, -58, 0, 10)
closeDrawer.Size = UDim2.fromOffset(44, 44)
local socialDescription = label(
	"Ownership",
	drawer,
	"Lend a hand, build together. All resources you gather and buildings you make stay with the host island.",
	13,
	palette.muted
)
socialDescription.Position = UDim2.fromOffset(16, 62)
socialDescription.Size = UDim2.new(1, -32, 0, 61)
socialDescription.TextWrapped = true
socialDescription.TextYAlignment = Enum.TextYAlignment.Top

local socialScroll = Instance.new("ScrollingFrame")
socialScroll.Name = "CrewList"
socialScroll.BackgroundTransparency = 1
socialScroll.BorderSizePixel = 0
socialScroll.Position = UDim2.fromOffset(16, 135)
socialScroll.Size = UDim2.new(1, -32, 1, -205)
socialScroll.ScrollBarThickness = 3
socialScroll.ScrollBarImageColor3 = palette.accent
socialScroll.ScrollingDirection = Enum.ScrollingDirection.Y
socialScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
socialScroll.CanvasSize = UDim2.new()
socialScroll.Parent = drawer
local socialList = Instance.new("UIListLayout")
socialList.SortOrder = Enum.SortOrder.LayoutOrder
socialList.Padding = UDim.new(0, 9)
socialList.Parent = socialScroll
local socialPadding = Instance.new("UIPadding")
socialPadding.PaddingRight = UDim.new(0, 6)
socialPadding.PaddingBottom = UDim.new(0, 8)
socialPadding.Parent = socialScroll
local homeButton = button("ReturnHome", drawer, "Return to my island", true)
homeButton.Position = UDim2.new(0, 16, 1, -60)
homeButton.Size = UDim2.new(1, -32, 0, 44)
setEnabled(homeButton, false)
homeButton.Activated:Connect(function()
	if homeButton.Active then
		send({ kind = "home" })
	end
end)

local toast = frame("Notice", root, palette.background)
toast.ZIndex = 30
toast.Visible = false
round(toast, 12)
outline(toast)
local toastStripe = frame("Status", toast, palette.accent)
toastStripe.Position = UDim2.fromOffset(0, 10)
toastStripe.Size = UDim2.new(0, 4, 1, -20)
round(toastStripe, 2)
local toastText = label("Message", toast, "", 14, palette.text)
toastText.Position = UDim2.fromOffset(16, 8)
toastText.Size = UDim2.new(1, -30, 1, -16)
toastText.TextWrapped = true

local function serverNow(): number
	return if current then current.now + (os.clock() - receivedAt) else os.time()
end

local function clockText(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function setProgress(ratio: number)
	ratio = math.clamp(ratio, 0, 1)
	if math.abs(ratio - progressRatio) < 0.001 then
		return
	end
	progressRatio = ratio
	if progressTween then
		progressTween:Cancel()
	end
	progressTween =
		TweenService:Create(eventFill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(ratio, 1),
		})
	progressTween:Play()
end

local function renderEvent()
	local snapshot = current
	local island = if snapshot then snapshot.island else nil
	setEnabled(eventButton, false)
	if not island then
		eventStatus.Text = "Your island is getting ready."
		eventButton.Text = "Waiting for island"
		setProgress(0)
		return
	end
	local event = island.event
	local now = serverNow()
	if event and event.phase == "active" then
		local remaining = event.endsAt - now
		eventStatus.Text =
			string.format("%d / %d repairs  •  %s left", event.progress, event.required, clockText(remaining))
		eventButton.Text = if remaining > 0 then "Use the repair stations" else "Resolving storm…"
		setProgress(event.progress / math.max(1, event.required))
		goalSummary.Text = "Protect the beacon · " .. clockText(remaining)
		return
	end
	setProgress(if event and event.phase == "success" then 1 else 0)
	if not island.projects.beacon then
		eventStatus.Text = "Complete the beacon to begin."
		eventButton.Text = "Beacon required"
	elseif island.nextEventAt > now then
		local result = if event and event.phase == "success" then "Storm survived!" else "The island is recovering."
		eventStatus.Text = result .. " Next storm in " .. clockText(island.nextEventAt - now) .. "."
		eventButton.Text = "Beacon recharging"
	elseif snapshot and snapshot.isOwner then
		eventStatus.Text = "Ready for a challenge? Stand near the beacon to start."
		eventButton.Text = "Start storm"
		setEnabled(eventButton, ready() and snapshot.canEdit)
	else
		eventStatus.Text = "The host can start the storm. Stay nearby to help repair."
		eventButton.Text = "Host starts the storm"
	end
end

local function layout()
	local width = root.AbsoluteSize.X
	local height = root.AbsoluteSize.Y
	if width <= 0 or height <= 0 then
		return
	end
	local narrow = width < 760
	local short = height < 500
	local margin = if narrow then 10 else 18
	local headerHeight = if narrow then 108 else 76
	local headerWidth = width - margin * 2
	header.Position = UDim2.fromOffset(margin, margin)
	header.Size = UDim2.fromOffset(headerWidth, headerHeight)
	if narrow then
		emblem.Position = UDim2.fromOffset(16, 14)
		title.Position = UDim2.fromOffset(48, 8)
		title.Size = UDim2.new(1, -60, 0, 25)
		rolePill.Position = UDim2.fromOffset(14, 33)
		islandName.Position = UDim2.fromOffset(88, 34)
		islandName.Size = UDim2.new(1, -102, 0, 18)
		local usable = headerWidth - 24
		local counterWidth = math.floor((usable - 16) / 3)
		woodCounter.Position = UDim2.fromOffset(12, 57)
		woodCounter.Size = UDim2.fromOffset(counterWidth, 44)
		stoneCounter.Position = UDim2.fromOffset(20 + counterWidth, 57)
		stoneCounter.Size = UDim2.fromOffset(counterWidth, 44)
		crewButton.Position = UDim2.fromOffset(28 + counterWidth * 2, 57)
		crewButton.Size = UDim2.fromOffset(usable - 16 - counterWidth * 2, 44)
		woodValue.TextSize = 12
		stoneValue.TextSize = 12
	else
		emblem.Position = UDim2.fromOffset(20, 18)
		title.Position = UDim2.fromOffset(54, 12)
		title.Size = UDim2.new(1, -434, 0, 27)
		rolePill.Position = UDim2.fromOffset(18, 43)
		islandName.Position = UDim2.fromOffset(92, 44)
		islandName.Size = UDim2.new(1, -472, 0, 19)
		woodCounter.Position = UDim2.new(1, -378, 0, 16)
		woodCounter.Size = UDim2.fromOffset(120, 44)
		stoneCounter.Position = UDim2.new(1, -250, 0, 16)
		stoneCounter.Size = UDim2.fromOffset(120, 44)
		crewButton.Position = UDim2.new(1, -122, 0, 16)
		crewButton.Size = UDim2.fromOffset(104, 44)
		woodValue.TextSize = 13
		stoneValue.TextSize = 13
	end
	if not expansionChosen then
		goalExpanded = not narrow and not short
	end
	local goalWidth = math.min(336, width - margin * 2)
	local goalY = margin + headerHeight + 10
	local bottomReserve = if UserInputService.TouchEnabled then 145 else 24
	-- Details scroll on smaller displays; the collapsed objective leaves room for movement controls.
	local maxGoalHeight = math.max(112, height - goalY - bottomReserve - 22)
	local goalHeight = if goalExpanded then math.min(468, maxGoalHeight) else 52
	goal.Position = UDim2.fromOffset(margin, goalY)
	goal.Size = UDim2.fromOffset(goalWidth, goalHeight)
	goalScroll.Visible = goalExpanded
	goalChevron.Text = if goalExpanded then "−" else "+"
	saveLabel.Position = UDim2.fromOffset(margin + 4, goalY + goalHeight + 5)
	saveLabel.Size = UDim2.fromOffset(goalWidth - 8, 17)
	local drawerWidth = math.min(390, width - margin * 2)
	drawer.Position = UDim2.fromOffset(width - margin - drawerWidth, margin)
	drawer.Size = UDim2.fromOffset(drawerWidth, height - margin * 2)
	local toastWidth = math.min(440, width - margin * 2)
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, margin + headerHeight + 10)
	toast.Size = UDim2.fromOffset(toastWidth, if narrow then 92 else 76)
end

local function setDrawer(open: boolean)
	drawerOpen = open
	veil.Visible = open
	drawer.Visible = open
	crewButton.Text = if open
		then "Crew open"
		else if current and #current.invites > 0 then "Crew (" .. #current.invites .. ")" else "Crew"
end

crewButton.Activated:Connect(function()
	setDrawer(not drawerOpen)
end)
closeDrawer.Activated:Connect(function()
	setDrawer(false)
end)
veil.Activated:Connect(function()
	setDrawer(false)
end)
goalToggle.Activated:Connect(function()
	expansionChosen = true
	goalExpanded = not goalExpanded
	layout()
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape and drawerOpen then
		setDrawer(false)
	end
end)

local function renderSocial()
	local snapshot = current
	local island = if snapshot then snapshot.island else nil
	local players: { PlayerEntry } = if snapshot then snapshot.players else {}
	local invites: { InviteEntry } = if snapshot then snapshot.invites else {}
	local helpers: { number } = if island then island.helpers else {}
	local isOwner = snapshot ~= nil and snapshot.isOwner
	local editable = ready() and snapshot ~= nil and snapshot.canEdit
	local signature = HttpService:JSONEncode({
		players,
		invites,
		helpers,
		isOwner,
		editable,
		ready(),
		if island then island.ownerId else 0,
	})
	setEnabled(homeButton, ready() and island ~= nil and island.ownerId ~= player.UserId)
	homeButton.Text = if island and island.ownerId == player.UserId
		then "You are on your island"
		else "Return to my island"
	if signature == socialSignature then
		return
	end
	socialSignature = signature
	local previousScroll = socialScroll.CanvasPosition
	for _, child in ipairs(socialScroll:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	local function section(value: string)
		local heading = label("Section", socialScroll, value, 12, palette.accent, true)
		heading.Size = UDim2.new(1, 0, 0, 27)
		heading.LayoutOrder = nextOrder()
	end
	local function note(value: string, height: number)
		local object = label("Note", socialScroll, value, 13, palette.muted)
		object.Size = UDim2.new(1, 0, 0, height)
		object.TextWrapped = true
		object.LayoutOrder = nextOrder()
	end
	if #invites > 0 then
		section("INVITATIONS · " .. #invites)
		for _, invite in ipairs(invites) do
			local row = frame("Invite" .. invite.ownerId, socialScroll, palette.panel)
			row.Size = UDim2.new(1, 0, 0, 123)
			row.LayoutOrder = nextOrder()
			round(row, 9)
			local name = label("Host", row, invite.ownerName .. " invited you", 14, palette.text, true)
			name.Position = UDim2.fromOffset(12, 7)
			name.Size = UDim2.new(1, -24, 0, 25)
			name.TextTruncate = Enum.TextTruncate.AtEnd
			local explanation = label(
				"Permission",
				row,
				"Join as a helper. Contributions stay with this host; your island stays yours.",
				12,
				palette.muted
			)
			explanation.Position = UDim2.fromOffset(12, 32)
			explanation.Size = UDim2.new(1, -24, 0, 36)
			explanation.TextWrapped = true
			local accept = button("Accept", row, "Accept & visit", true)
			accept.Position = UDim2.fromOffset(10, 72)
			accept.Size = UDim2.new(0.58, -15, 0, 44)
			setEnabled(accept, ready())
			accept.Activated:Connect(function()
				if accept.Active then
					send({ kind = "acceptInvite", userId = invite.ownerId })
				end
			end)
			local decline = button("Decline", row, "Decline")
			decline.Position = UDim2.new(0.58, 3, 0, 72)
			decline.Size = UDim2.new(0.42, -13, 0, 44)
			setEnabled(decline, ready())
			decline.Activated:Connect(function()
				if decline.Active then
					send({ kind = "declineInvite", userId = invite.ownerId })
				end
			end)
		end
	end
	local helperLookup: { [number]: boolean } = {}
	local names: { [number]: string } = {}
	for _, entry in ipairs(players) do
		names[entry.userId] = entry.displayName
	end
	for _, userId in ipairs(helpers) do
		helperLookup[userId] = true
	end
	if isOwner and #helpers > 0 then
		section("YOUR HELPERS")
		for _, userId in ipairs(helpers) do
			local row = frame("Helper" .. userId, socialScroll, palette.panel)
			row.Size = UDim2.new(1, 0, 0, 65)
			row.LayoutOrder = nextOrder()
			round(row, 9)
			local name = label("Name", row, names[userId] or ("Player " .. userId), 13, palette.text, true)
			name.Position = UDim2.fromOffset(12, 8)
			name.Size = UDim2.new(1, -112, 0, 24)
			name.TextTruncate = Enum.TextTruncate.AtEnd
			local permission = label("Permission", row, "Can gather & build", 11, palette.muted)
			permission.Position = UDim2.fromOffset(12, 33)
			permission.Size = UDim2.new(1, -112, 0, 17)
			local revoke = button("Revoke", row, "Remove")
			revoke.Position = UDim2.new(1, -94, 0, 10)
			revoke.Size = UDim2.fromOffset(84, 44)
			setEnabled(revoke, editable)
			revoke.Activated:Connect(function()
				if revoke.Active then
					send({ kind = "revoke", userId = userId })
				end
			end)
		end
	end
	section("PLAYERS IN THIS SERVER")
	local otherCount = 0
	for _, entry in ipairs(players) do
		if entry.userId == player.UserId then
			continue
		end
		otherCount += 1
		local row = frame("Player" .. entry.userId, socialScroll, palette.panel)
		row.Size = UDim2.new(1, 0, 0, 107)
		row.LayoutOrder = nextOrder()
		round(row, 9)
		local name = label("Name", row, entry.displayName, 14, palette.text, true)
		name.Position = UDim2.fromOffset(12, 7)
		name.Size = UDim2.new(1, -24, 0, 24)
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local status = label(
			"Status",
			row,
			if helperLookup[entry.userId]
				then "Helping on this island"
				elseif entry.hasIsland then "Visit to look around"
				else "Island loading…",
			12,
			palette.muted
		)
		status.Position = UDim2.fromOffset(12, 33)
		status.Size = UDim2.new(1, -24, 0, 18)
		local visit = button("Visit", row, "Visit island")
		visit.Position = UDim2.fromOffset(10, 56)
		visit.Size = UDim2.new(0.5, -14, 0, 44)
		setEnabled(visit, ready() and entry.hasIsland and (not island or island.ownerId ~= entry.userId))
		visit.Activated:Connect(function()
			if visit.Active then
				send({ kind = "visit", userId = entry.userId })
			end
		end)
		local inviteButton =
			button("Invite", row, if helperLookup[entry.userId] then "Already helping" else "Invite to help", true)
		inviteButton.Position = UDim2.new(0.5, 4, 0, 56)
		inviteButton.Size = UDim2.new(0.5, -14, 0, 44)
		setEnabled(inviteButton, editable and isOwner and not helperLookup[entry.userId])
		inviteButton.Activated:Connect(function()
			if inviteButton.Active then
				send({ kind = "invite", userId = entry.userId })
			end
		end)
	end
	if otherCount == 0 then
		note("Your crew starts here. Friends can join this server from Roblox.", 62)
	end
	if not isOwner then
		note(
			"Return to your own island to invite helpers. Visits allow building only after the host's invitation is accepted.",
			65
		)
	else
		note("Invited friends can gather and build while you are here. Removing a helper returns them home.", 60)
	end
	task.defer(function()
		if socialScroll.Parent then
			socialScroll.CanvasPosition = previousScroll
		end
	end)
end

local function renderSnapshot()
	local snapshot = current
	local island = if snapshot then snapshot.island else nil
	local isReady = ready()
	local canEdit = snapshot ~= nil and snapshot.canEdit and isReady
	if island and snapshot then
		roleLabel.Text = if snapshot.isOwner then "Owner" elseif snapshot.canEdit then "Helper" else "Visitor"
		islandName.Text = if snapshot.isOwner then "Your island" else snapshot.ownerName .. "'s island"
		woodValue.Text = tostring(island.stockpile.wood or 0)
		stoneValue.Text = tostring(island.stockpile.stone or 0)
		local nextProject: string? = nil
		for _, id in ipairs(Config.ProjectOrder) do
			if not island.projects[id] then
				nextProject = id
				break
			end
		end
		if not canEdit and snapshot.isOwner then
			goalSummary.Text = "Island actions are paused"
			objectiveDetail.Text =
				"Saving is unavailable and this island is paused. Rejoin to reconnect before gathering or building again."
		elseif not canEdit and not snapshot.isOwner then
			goalSummary.Text = "Explore " .. snapshot.ownerName .. "'s island"
			objectiveDetail.Text =
				"You are visiting. Ask the host for an invitation, then accept it in Crew to gather and build here."
		elseif nextProject then
			local project = Config.Projects[nextProject]
			local woodNeeded = math.max(0, project.cost.wood - (island.stockpile.wood or 0))
			local stoneNeeded = math.max(0, project.cost.stone - (island.stockpile.stone or 0))
			if woodNeeded > 0 or stoneNeeded > 0 then
				goalSummary.Text = "Gather for the " .. project.label
				if stoneNeeded > 0 then
					objectiveDetail.Text =
						"Cross the bridge to mine stone. Gather from trees for wood; everything goes into this island's shared stockpile."
				else
					objectiveDetail.Text = "Find a tree and use its prompt to gather wood. "
						.. woodNeeded
						.. " more wood will cover the "
						.. project.label
						.. "."
				end
			else
				goalSummary.Text = "Build the " .. project.label
				objectiveDetail.Text = "Materials are ready. Walk to the marked "
					.. project.label
					.. " site and use its prompt or the Build button below."
			end
		elseif island.tutorialStage >= 5 then
			goalSummary.Text = "An island worth coming back to"
			objectiveDetail.Text =
				"Your island is complete. Invite friends, gather supplies, and defend the beacon again when it recharges."
		else
			goalSummary.Text = "Weather your first storm"
			objectiveDetail.Text =
				"The host starts the storm at the beacon. Use the three repair stations together until the repair goal is met."
		end
	else
		local recovery = snapshot ~= nil and snapshot.saveStatus == "recovery"
		roleLabel.Text = if recovery then "Paused" else "Loading"
		islandName.Text = if recovery then "Island unavailable" else "Preparing your island…"
		woodValue.Text = "—"
		stoneValue.Text = "—"
		goalSummary.Text = if recovery then "Unable to load this island" else "Loading your island…"
		objectiveDetail.Text = if recovery
			then "This island is unavailable. Check the message above, then rejoin to try loading again."
			else "Loading saved progress and preparing your island. The controls will unlock when it is ready."
	end
	for _, id in ipairs(Config.ProjectOrder) do
		local project = Config.Projects[id]
		local row = projectRows[id]
		local built = island ~= nil and island.projects[id] == true
		local unlocked = island ~= nil and (not project.prerequisite or island.projects[project.prerequisite] == true)
		local affordable = island ~= nil
			and (island.stockpile.wood or 0) >= project.cost.wood
			and (island.stockpile.stone or 0) >= project.cost.stone
		local cost = tostring(project.cost.wood) .. " wood"
		if project.cost.stone > 0 then
			cost ..= " + " .. project.cost.stone .. " stone"
		end
		row.cost.Text = if built then "Completed" else cost
		row.cost.TextColor3 = if built then palette.accent else palette.muted
		row.marker.Text = if built then "✓" else tostring(table.find(Config.ProjectOrder, id))
		row.action.Text = if built
			then "Built"
			elseif not unlocked then "Locked"
			elseif not affordable then "Gather"
			else "Build"
		setEnabled(row.action, canEdit and unlocked and affordable and not built)
	end
	if snapshot then
		local statuses: { [string]: string } = {
			loading = "Loading saved progress…",
			session = "Session only",
			saved = "Progress saved",
			pending = "Unsaved changes · saving soon",
			saving = "Saving progress…",
			recovery = if snapshot.canEdit then "Retrying save…" else "Save unavailable · building paused",
		}
		local status = statuses[snapshot.saveStatus] or "Checking save status…"
		saveLabel.Text = if snapshot.studioMode then "Session only • Studio" else status
		if snapshot.studioMode and snapshot.saveStatus == "recovery" then
			saveLabel.Text ..= if snapshot.canEdit then " · retrying" else " · building paused"
		end
		saveLabel.TextColor3 = if snapshot.saveStatus == "recovery" then palette.error else palette.text
	end
	setDrawer(drawerOpen)
	renderSocial()
	renderEvent()
end

local function showNotice(message: string, ok: boolean)
	noticeSerial += 1
	local serial = noticeSerial
	toastText.Text = message
	toastText.TextTransparency = 1
	toastStripe.BackgroundColor3 = if ok then palette.accent else palette.error
	toast.BackgroundTransparency = 1
	toast.Visible = true
	TweenService:Create(toast, TweenInfo.new(0.18), { BackgroundTransparency = 0.03 }):Play()
	TweenService:Create(toastText, TweenInfo.new(0.18), { TextTransparency = 0 }):Play()
	task.delay(if ok then 4 else 6, function()
		if serial ~= noticeSerial or not toast.Parent then
			return
		end
		TweenService:Create(toast, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		TweenService:Create(toastText, TweenInfo.new(0.2), { TextTransparency = 1 }):Play()
		task.delay(0.22, function()
			if serial == noticeSerial then
				toast.Visible = false
			end
		end)
	end)
end

stateRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.kind == "notice" then
		if typeof(payload.message) == "string" then
			showNotice(payload.message, payload.ok == true)
		end
	elseif payload.kind == "snapshot" then
		local previous = if current then current.island else nil
		local incoming = payload.island
		local projectCompleted = false
		if previous and incoming and previous.ownerId == incoming.ownerId then
			for _, id in ipairs(Config.ProjectOrder) do
				if not previous.projects[id] and incoming.projects[id] == true then
					projectCompleted = true
					break
				end
			end
		end
		current = {
			island = payload.island,
			ownerName = payload.ownerName or "Host",
			isOwner = payload.isOwner == true,
			canEdit = payload.canEdit == true,
			saveStatus = payload.saveStatus or "loading",
			studioMode = payload.studioMode == true,
			players = payload.players or {},
			invites = payload.invites or {},
			now = payload.now or os.time(),
		}
		receivedAt = os.clock()
		renderSnapshot()
		if projectCompleted then
			SoundService:PlayLocalSound(constructionSound)
		end
	end
end)

root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
layout()
renderSnapshot()
-- Connect before requesting state, so even a fast in-memory Studio load cannot be missed.
actionRemote:FireServer({ kind = "sync" })
task.spawn(function()
	while gui.Parent do
		task.wait(0.25)
		renderEvent()
	end
end)
