--!strict
-- The world is presentation only. Every prompt returns to the server's action dispatcher.
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local World = {}
World.__index = World

type Action = { kind: string, target: string? }
type NodeVisual = {
	model: Model,
	prompt: ProximityPrompt,
	foliage: { BasePart },
	available: boolean?,
}
type ProjectVisual = {
	built: Model,
	site: Model,
	prompt: ProximityPrompt,
	label: TextLabel,
}
type RepairVisual = { model: Model, prompt: ProximityPrompt, lamp: BasePart }
type Plot = {
	ownerId: number,
	origin: Vector3,
	slotIndex: number,
	model: Model,
	nodes: { [string]: NodeVisual },
	projects: { [string]: ProjectVisual },
	repairs: { [string]: RepairVisual },
	targets: { [string]: Vector3 },
	connections: { RBXScriptConnection },
	outcrop: Model,
	stormClouds: Model,
	eventPrompt: ProximityPrompt?,
	beaconLight: PointLight?,
	beaconLens: BasePart?,
	eventLabel: TextLabel?,
	eventActive: boolean?,
}
type Slot = { origin: Vector3, pad: Model, ownerId: number? }
type WorldData = {
	config: any,
	root: Folder,
	plots: { [number]: Plot },
	slots: { Slot },
	hubSpawn: CFrame,
	onAction: ((Player, number, Action) -> ())?,
}
type WorldObject = typeof(setmetatable({} :: WorldData, World))

local Colors = {
	sand = Color3.fromRGB(239, 219, 166),
	sandEdge = Color3.fromRGB(201, 178, 126),
	grass = Color3.fromRGB(112, 174, 109),
	grassLight = Color3.fromRGB(155, 199, 117),
	rock = Color3.fromRGB(106, 132, 134),
	rockLight = Color3.fromRGB(158, 178, 169),
	wood = Color3.fromRGB(137, 91, 59),
	woodLight = Color3.fromRGB(189, 141, 90),
	leaves = Color3.fromRGB(50, 134, 105),
	leavesLight = Color3.fromRGB(96, 173, 106),
	sea = Color3.fromRGB(50, 182, 189),
	foam = Color3.fromRGB(185, 233, 217),
	cream = Color3.fromRGB(255, 246, 219),
	ink = Color3.fromRGB(29, 65, 67),
	gold = Color3.fromRGB(255, 195, 85),
	glow = Color3.fromRGB(135, 244, 217),
	storm = Color3.fromRGB(255, 161, 96),
}

local function model(parent: Instance, name: string): Model
	local result = Instance.new("Model")
	result.Name = name
	result.Parent = parent
	return result
end

local function part(
	parent: Instance,
	name: string,
	size: Vector3,
	frame: CFrame,
	color: Color3,
	material: Enum.Material?,
	collidable: boolean?,
	transparency: number?
): Part
	local result = Instance.new("Part")
	result.Name = name
	result.Size = size
	result.CFrame = frame
	result.Color = color
	result.Material = material or Enum.Material.SmoothPlastic
	result.Anchored = true
	result.CanCollide = collidable ~= false
	result.CanTouch = false
	result.CanQuery = collidable ~= false
	result.Transparency = transparency or 0
	result.TopSurface = Enum.SurfaceType.Smooth
	result.BottomSurface = Enum.SurfaceType.Smooth
	result:SetAttribute("VisibleTransparency", result.Transparency)
	result:SetAttribute("VisibleCollision", result.CanCollide)
	result:SetAttribute("VisibleQuery", result.CanQuery)
	result.Parent = parent
	return result
end

local function disk(
	parent: Instance,
	name: string,
	origin: Vector3,
	position: Vector3,
	diameter: number,
	height: number,
	color: Color3,
	material: Enum.Material?
): Part
	local result = part(
		parent,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(origin + position) * CFrame.Angles(0, 0, math.pi / 2),
		color,
		material
	)
	result.Shape = Enum.PartType.Cylinder
	return result
end

local function ball(
	parent: Instance,
	name: string,
	size: Vector3,
	position: Vector3,
	color: Color3,
	collide: boolean?
): Part
	local result = part(parent, name, size, CFrame.new(position), color, nil, collide)
	result.Shape = Enum.PartType.Ball
	return result
end

local function setVisible(container: Model, visible: boolean)
	if container:GetAttribute("WorldVisible") == visible then
		return
	end
	container:SetAttribute("WorldVisible", visible)
	for _, item in container:GetDescendants() do
		if item:IsA("BasePart") then
			item.Transparency = if visible then item:GetAttribute("VisibleTransparency") or 0 else 1
			item.CanCollide = visible and item:GetAttribute("VisibleCollision") == true
			item.CanQuery = visible and item:GetAttribute("VisibleQuery") == true
		elseif item:IsA("BillboardGui") or item:IsA("SurfaceGui") then
			item.Enabled = visible
		elseif item:IsA("Light") or item:IsA("Beam") or item:IsA("Fire") or item:IsA("ParticleEmitter") then
			item.Enabled = visible
		elseif item:IsA("ProximityPrompt") and not visible then
			item.Enabled = false
		end
	end
end

local function setPrompt(prompt: ProximityPrompt, enabled: boolean, actionText: string?)
	if prompt.Enabled ~= enabled then
		prompt.Enabled = enabled
	end
	if actionText and prompt.ActionText ~= actionText then
		prompt.ActionText = actionText
	end
end

local function label(anchor: BasePart, text: string, width: number?, height: number?): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "WorldLabel"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(width or 220, height or 54)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
	gui.MaxDistance = 90
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Parent = anchor
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundColor3 = Colors.ink
	textLabel.BackgroundTransparency = 0.1
	textLabel.TextColor3 = Colors.cream
	textLabel.Font = Enum.Font.GothamBold
	textLabel.TextSize = 15
	textLabel.TextWrapped = true
	textLabel.Text = text
	textLabel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 9)
	corner.Parent = textLabel
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 9)
	padding.PaddingRight = UDim.new(0, 9)
	padding.Parent = textLabel
	return textLabel
end

local function localPosition(origin: Vector3, position: any): Vector3
	return origin + Vector3.new(position.x, position.y, position.z)
end

local function tree(parent: Instance, origin: Vector3, x: number, z: number, seed: number, scale: number?): { BasePart }
	local factor = scale or 1
	local base = origin + Vector3.new(x, 0, z)
	local turn = seed * 0.71
	part(
		parent,
		"TimberTrunk",
		Vector3.new(1.5, 7.1, 1.5) * factor,
		CFrame.new(base + Vector3.new(0, 3.5 * factor, 0)) * CFrame.Angles(0.04, turn, 0.06),
		Colors.wood,
		Enum.Material.Wood
	)
	part(
		parent,
		"Branch",
		Vector3.new(0.7, 3.8, 0.7) * factor,
		CFrame.new(base + Vector3.new(1.05 * factor, 5.1 * factor, 0)) * CFrame.Angles(0, turn, -0.6),
		Colors.wood,
		Enum.Material.Wood,
		false
	)
	local leaves = {
		ball(
			parent,
			"Crown",
			Vector3.new(9.5, 7, 8.5) * factor,
			base + Vector3.new(0, 9.4 * factor, 0),
			Colors.leaves,
			false
		),
		ball(
			parent,
			"SunlitCrown",
			Vector3.new(7.1, 6.7, 6.8) * factor,
			base + Vector3.new(2.5 * factor, 11.3 * factor, 0.7 * factor),
			Colors.leavesLight,
			false
		),
		ball(
			parent,
			"SideCrown",
			Vector3.new(6.5, 5.3, 6.3) * factor,
			base + Vector3.new(-3 * factor, 8.8 * factor, -0.6 * factor),
			Colors.leavesLight,
			false
		),
	}
	for _, leaf in leaves do
		leaf:SetAttribute("HealthyColor", leaf.Color)
	end
	return leaves
end

local function islandGround(
	parent: Instance,
	origin: Vector3,
	name: string,
	x: number,
	z: number,
	diameter: number,
	grass: boolean
)
	disk(parent, name .. "Reef", origin, Vector3.new(x, -5, z), diameter + 12, 3, Colors.rock, Enum.Material.Slate)
	disk(
		parent,
		name .. "Sandbank",
		origin,
		Vector3.new(x, -2.2, z),
		diameter + 5,
		3,
		Colors.sandEdge,
		Enum.Material.Sand
	)
	disk(parent, name .. "Beach", origin, Vector3.new(x, -1.15, z), diameter + 2, 1.5, Colors.sand, Enum.Material.Sand)
	disk(
		parent,
		name .. "Ground",
		origin,
		Vector3.new(x, -0.65, z),
		diameter,
		1.3,
		if grass then Colors.grass else Colors.rockLight,
		if grass then Enum.Material.Grass else Enum.Material.Slate
	)
end

local function makeCampfire(parent: Instance, origin: Vector3, position: any)
	local center = localPosition(origin, position) - Vector3.new(0, position.y, 0)
	disk(parent, "Hearth", center, Vector3.new(0, 0.1, 0), 7, 0.2, Colors.sand, Enum.Material.Sand)
	for index = 1, 9 do
		local angle = index * math.pi * 2 / 9
		ball(
			parent,
			"HearthStone",
			Vector3.new(1.3, 0.8, 1.1),
			center + Vector3.new(math.cos(angle) * 2.1, 0.45, math.sin(angle) * 2.1),
			Colors.rockLight,
			true
		)
	end
	for index = 1, 3 do
		part(
			parent,
			"Firewood",
			Vector3.new(3.7, 0.6, 0.65),
			CFrame.new(center + Vector3.new(0, 0.65 + index * 0.15, 0)) * CFrame.Angles(0, index * 2, 0),
			Colors.wood,
			Enum.Material.Wood,
			false
		)
	end
	local ember =
		ball(parent, "WarmEmbers", Vector3.new(2, 0.5, 2), center + Vector3.new(0, 0.95, 0), Colors.gold, false)
	ember.Material = Enum.Material.Neon
	local flame = Instance.new("Fire")
	flame.Color = Colors.gold
	flame.SecondaryColor = Color3.fromRGB(255, 113, 63)
	flame.Size = 3.8
	flame.Heat = 3
	flame.Parent = ember
	local light = Instance.new("PointLight")
	light.Color = Colors.gold
	light.Brightness = 1.7
	light.Range = 21
	light.Parent = ember
	for _, side in { -1, 1 } do
		part(
			parent,
			"CampBench",
			Vector3.new(5, 0.6, 1.3),
			CFrame.new(center + Vector3.new(0, 1, side * 4.6)),
			Colors.woodLight,
			Enum.Material.WoodPlanks
		)
		for _, leg in { -1, 1 } do
			part(
				parent,
				"BenchLeg",
				Vector3.new(0.5, 0.8, 0.9),
				CFrame.new(center + Vector3.new(leg * 1.8, 0.4, side * 4.6)),
				Colors.wood,
				Enum.Material.Wood
			)
		end
	end
end

local function makeBridge(parent: Instance, origin: Vector3)
	-- The continuous invisible deck keeps feet stable over the decorative plank seams.
	part(
		parent,
		"BridgeCollision",
		Vector3.new(29, 0.35, 8),
		CFrame.new(origin + Vector3.new(52, -0.05, 0)),
		Colors.wood,
		nil,
		true,
		1
	)
	for index = 0, 23 do
		part(
			parent,
			"DeckPlank",
			Vector3.new(1.14, 0.3, 8),
			CFrame.new(origin + Vector3.new(38.2 + index * 1.2, 0.06, 0)),
			if index % 3 == 0 then Colors.wood else Colors.woodLight,
			Enum.Material.WoodPlanks,
			false
		)
	end
	for _, side in { -1, 1 } do
		part(
			parent,
			"Handrail",
			Vector3.new(28.8, 0.35, 0.4),
			CFrame.new(origin + Vector3.new(52, 3.25, side * 4.35)),
			Colors.woodLight,
			Enum.Material.Wood
		)
		part(
			parent,
			"LowerRail",
			Vector3.new(28.8, 0.22, 0.28),
			CFrame.new(origin + Vector3.new(52, 1.65, side * 4.35)),
			Colors.wood,
			Enum.Material.Wood
		)
		for index = 0, 5 do
			part(
				parent,
				"BridgePost",
				Vector3.new(0.6, 6.2, 0.6),
				CFrame.new(origin + Vector3.new(38.2 + index * 5.5, 0.6, side * 4.35)),
				Colors.wood,
				Enum.Material.Wood
			)
		end
	end
end

local function makeBeacon(parent: Instance, origin: Vector3, position: any): (Part, PointLight)
	local center = localPosition(origin, position) - Vector3.new(0, position.y, 0)
	disk(parent, "BeaconFoundation", center, Vector3.new(0, 0.2, 0), 7.5, 0.4, Colors.rock, Enum.Material.Slate)
	part(
		parent,
		"BeaconPedestal",
		Vector3.new(3.5, 6.7, 3.5),
		CFrame.new(center + Vector3.new(0, 3.55, 0)),
		Colors.rockLight,
		Enum.Material.Slate
	)
	for _, height in { 1.3, 5.6, 7 } do
		part(
			parent,
			"CopperBand",
			Vector3.new(3.8, 0.3, 3.8),
			CFrame.new(center + Vector3.new(0, height, 0)),
			Colors.woodLight,
			Enum.Material.Metal,
			false
		)
	end
	local lens =
		ball(parent, "BeaconLens", Vector3.new(3.7, 4.1, 3.7), center + Vector3.new(0, 9.2, 0), Colors.glow, false)
	lens.Material = Enum.Material.Neon
	for _, side in { -1, 1 } do
		part(
			parent,
			"LanternFrame",
			Vector3.new(0.4, 4.3, 0.4),
			CFrame.new(center + Vector3.new(side * 2.1, 9.1, -2.1)),
			Colors.wood,
			Enum.Material.Metal,
			false
		)
		part(
			parent,
			"LanternFrame",
			Vector3.new(0.4, 4.3, 0.4),
			CFrame.new(center + Vector3.new(side * 2.1, 9.1, 2.1)),
			Colors.wood,
			Enum.Material.Metal,
			false
		)
	end
	disk(parent, "LanternRoof", center, Vector3.new(0, 11.45, 0), 6, 0.6, Colors.wood, Enum.Material.Metal)
	local bottom = Instance.new("Attachment")
	bottom.Name = "SignalBase"
	bottom.Parent = lens
	local top = Instance.new("Attachment")
	top.Name = "SignalTop"
	top.Position = Vector3.new(0, 65, 0)
	top.Parent = lens
	local beam = Instance.new("Beam")
	beam.Name = "BeaconSignal"
	beam.Attachment0 = bottom
	beam.Attachment1 = top
	beam.FaceCamera = true
	beam.Width0 = 1.8
	beam.Width1 = 6
	beam.Color = ColorSequence.new(Colors.glow)
	beam.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	beam.LightEmission = 1
	beam.Parent = lens
	local light = Instance.new("PointLight")
	light.Color = Colors.glow
	light.Range = 28
	light.Brightness = 2
	light.Parent = lens
	return lens, light
end

function World._prompt(
	self: WorldObject,
	plot: Plot,
	kind: string,
	target: string?,
	position: Vector3,
	objectText: string,
	actionText: string
): ProximityPrompt
	local key = kind .. ":" .. (target or "")
	plot.targets[key] = position
	local anchor = part(
		plot.model,
		"Target_" .. key,
		Vector3.new(0.3, 0.3, 0.3),
		CFrame.new(position),
		Colors.cream,
		nil,
		false,
		1
	)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = kind .. "Prompt"
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.MaxActivationDistance = math.min(self.config.InteractionDistance - 2, 14)
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = if kind == "startEvent" then 0.75 else 0.35
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Enabled = false
	prompt:SetAttribute("OwnerId", plot.ownerId)
	prompt:SetAttribute("ActionKind", kind)
	if target then
		prompt:SetAttribute("ActionTarget", target)
	end
	prompt.Parent = anchor
	table.insert(
		plot.connections,
		prompt.Triggered:Connect(function(player: Player)
			if self.plots[plot.ownerId] ~= plot or not prompt.Enabled then
				return
			end
			local callback = self.onAction
			if callback then
				callback(player, plot.ownerId, { kind = kind, target = target })
			end
		end)
	)
	return prompt
end

local function decorateMainland(parent: Instance, origin: Vector3, seed: number)
	local random = Random.new(9700 + seed)
	for index = 1, 25 do
		local angle = index * math.pi * 2 / 25
		local radius = random:NextNumber(33, 36)
		local x, z = math.cos(angle) * radius, math.sin(angle) * radius
		-- Leave the eastern bridge approach and southern arrival clear.
		if not (x > 29 and math.abs(z) < 9) and not (z > 29 and math.abs(x) < 9) then
			local base = origin + Vector3.new(x, 0, z)
			for blade = 1, 3 do
				part(
					parent,
					"BeachGrass",
					Vector3.new(0.18, random:NextNumber(0.8, 1.5), 0.65),
					CFrame.new(base + Vector3.new((blade - 2) * 0.4, 0.45, 0))
						* CFrame.Angles(0, angle, (blade - 2) * 0.22),
					Colors.grassLight,
					Enum.Material.SmoothPlastic,
					false
				)
			end
			if index % 4 == 0 then
				ball(
					parent,
					"BeachPebble",
					Vector3.new(2.2, 1.1, 1.7),
					base + Vector3.new(1.4, 0.4, 0.5),
					Colors.rockLight,
					false
				)
			end
		end
	end
	for index = 1, 5 do
		local steppingStone = disk(
			parent,
			"ArrivalPath",
			origin,
			Vector3.new(0, 0.04, 25 - index * 4.3),
			2.5,
			0.08,
			Colors.sand,
			Enum.Material.Sand
		)
		steppingStone.CanCollide = false
		steppingStone.CanQuery = false
		steppingStone:SetAttribute("VisibleCollision", false)
		steppingStone:SetAttribute("VisibleQuery", false)
	end
	for index = 0, 8 do
		part(
			parent,
			"ArrivalPierPlank",
			Vector3.new(7, 0.35, 1.1),
			CFrame.new(origin + Vector3.new(0, 0.08, 35 + index * 1.15)),
			Colors.woodLight,
			Enum.Material.WoodPlanks
		)
	end
	for _, x in { -3.3, 3.3 } do
		part(
			parent,
			"PierMooring",
			Vector3.new(0.65, 5.5, 0.65),
			CFrame.new(origin + Vector3.new(x, -0.7, 43)),
			Colors.wood,
			Enum.Material.Wood
		)
	end
end

function World.create(config: any): WorldObject
	local prior = Workspace:FindFirstChild("DriftwoodIsles")
	if prior then
		prior:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "DriftwoodIsles"
	root.Parent = Workspace
	local self: WorldObject = setmetatable({
		config = config,
		root = root,
		plots = {},
		slots = {},
		hubSpawn = CFrame.lookAt(Vector3.new(0, 5, 15), Vector3.new(0, 5, -5)),
		onAction = nil,
	}, World)
	Lighting.ClockTime = 14.3
	Lighting.Brightness = 2.4
	Lighting.Ambient = Color3.fromRGB(125, 147, 151)
	Lighting.OutdoorAmbient = Color3.fromRGB(156, 176, 166)
	Lighting.GlobalShadows = true
	local existingAtmosphere = Lighting:FindFirstChild("DriftwoodAtmosphere")
	if existingAtmosphere then
		existingAtmosphere:Destroy()
	end
	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Name = "DriftwoodAtmosphere"
	atmosphere.Color = Color3.fromRGB(206, 237, 233)
	atmosphere.Decay = Color3.fromRGB(118, 172, 174)
	atmosphere.Density = 0.18
	atmosphere.Haze = 1.1
	atmosphere.Glare = 0.15
	atmosphere.Parent = Lighting
	part(
		root,
		"TurquoiseOcean",
		Vector3.new(2200, 1, 2200),
		CFrame.new(0, -4.5, 0),
		Colors.sea,
		Enum.Material.SmoothPlastic,
		false
	)
	local seaDetails = model(root, "OceanShimmers")
	local random = Random.new(702)
	for index = 1, 55 do
		part(
			seaDetails,
			"FoamRibbon",
			Vector3.new(random:NextNumber(8, 21), 0.03, 0.16),
			CFrame.new(random:NextNumber(-430, 430), -3.97, random:NextNumber(-330, 330)),
			Colors.foam,
			nil,
			false,
			0.64
		)
	end
	local hub = model(root, "WelcomeHarbor")
	islandGround(hub, Vector3.zero, "Harbor", 0, 0, 57, true)
	tree(hub, Vector3.zero, -19, -7, 1, 1.2)
	tree(hub, Vector3.zero, 20, -10, 3, 1.1)
	makeCampfire(hub, Vector3.zero, { x = 0, y = 3, z = -4 })
	for _, x in { -8, 8 } do
		part(hub, "WelcomeSignPost", Vector3.new(0.8, 8, 0.8), CFrame.new(x, 4, -17), Colors.wood, Enum.Material.Wood)
	end
	local welcome =
		part(hub, "WelcomeSign", Vector3.new(18, 4, 0.55), CFrame.new(0, 7, -17), Colors.wood, Enum.Material.WoodPlanks)
	label(welcome, "DRIFTWOOD ISLES\nGather. Build. Weather the storm.", 310, 72)
	for index = 0, 11 do
		part(
			hub,
			"HarborPier",
			Vector3.new(10, 0.45, 1.25),
			CFrame.new(0, -0.02, 26 + index * 1.3),
			Colors.woodLight,
			Enum.Material.WoodPlanks
		)
	end
	-- Slots remain in the same orientation so every authority target is origin + Config position.
	local origins = {
		Vector3.new(-205, 0, -145),
		Vector3.new(135, 0, -145),
		Vector3.new(-205, 0, 145),
		Vector3.new(135, 0, 145),
	}
	for index = 1, math.min(config.MaxPlayers, #origins) do
		local origin = origins[index]
		local pad = model(root, "EmptyPlot" .. tostring(index))
		disk(pad, "PlotSandbar", origin, Vector3.new(0, -1, 0), 17, 2, Colors.sand, Enum.Material.Sand)
		local marker = part(
			pad,
			"PlotMarker",
			Vector3.new(0.7, 4, 0.7),
			CFrame.new(origin + Vector3.new(0, 2, 0)),
			Colors.wood,
			Enum.Material.Wood
		)
		label(marker, "A NEW ISLAND AWAITS", 180, 38)
		table.insert(self.slots, { origin = origin, pad = pad, ownerId = nil })
	end
	return self
end

function World.addIsland(
	self: WorldObject,
	ownerId: number,
	slotIndex: number,
	displayName: string,
	snapshot: any
): Plot
	local slot = self.slots[slotIndex]
	assert(slot, "Island slot is outside the configured world")
	assert(slot.ownerId == nil or slot.ownerId == ownerId, "Island slot is already occupied")
	if self.plots[ownerId] then
		self:removeIsland(ownerId)
	end
	local islandModel = model(self.root, "Island_" .. tostring(ownerId))
	islandModel:SetAttribute("OwnerId", ownerId)
	islandModel:SetAttribute("PlotSlot", slotIndex)
	local origin = slot.origin
	local plot: Plot = {
		ownerId = ownerId,
		origin = origin,
		slotIndex = slotIndex,
		model = islandModel,
		nodes = {},
		projects = {},
		repairs = {},
		targets = {},
		connections = {},
		outcrop = model(islandModel, "StoneOutcrop"),
		stormClouds = model(islandModel, "StormClouds"),
		eventPrompt = nil,
		beaconLight = nil,
		beaconLens = nil,
		eventLabel = nil,
		eventActive = nil,
	}
	self.plots[ownerId] = plot
	slot.ownerId = ownerId
	setVisible(slot.pad, false)
	islandGround(islandModel, origin, "HomeIsland", 0, 0, 78, true)
	islandGround(plot.outcrop, origin, "StoneIsland", 66, 0, 40, false)
	decorateMainland(islandModel, origin, slotIndex)
	-- Storm effects belong to this island; another owner's clear weather is unaffected.
	for index = 1, 7 do
		local angle = index * math.pi * 2 / 7
		local cloud = ball(
			plot.stormClouds,
			"StormCloud",
			Vector3.new(25, 7, 15),
			origin + Vector3.new(math.cos(angle) * 23, 37 + index % 3, math.sin(angle) * 23),
			Color3.fromRGB(91, 115, 131),
			false
		)
		cloud.Transparency = 0.18
		cloud:SetAttribute("VisibleTransparency", 0.18)
	end
	local ownerPost = part(
		islandModel,
		"OwnerSignPost",
		Vector3.new(0.55, 4, 0.55),
		CFrame.new(origin + Vector3.new(6, 2, 29)),
		Colors.wood,
		Enum.Material.Wood
	)
	label(ownerPost, displayName .. "'s island", 210, 42)
	for id, definition in self.config.Nodes do
		local nodeParent = if definition.kind == "stone" then plot.outcrop else islandModel
		local node = model(nodeParent, id)
		local position = localPosition(origin, definition.position)
		local foliage: { BasePart } = {}
		if definition.kind == "wood" then
			foliage =
				tree(node, origin, definition.position.x, definition.position.z, tonumber(string.match(id, "%d+")) or 1)
		else
			local groundPosition = position - Vector3.new(0, definition.position.y, 0)
			local number = tonumber(string.match(id, "%d+")) or 1
			for rockIndex = 1, 3 do
				local rock = part(
					node,
					"QuarryStone",
					Vector3.new(2.4, 2.2 + rockIndex * 0.6, 2.3),
					CFrame.new(groundPosition + Vector3.new((rockIndex - 2) * 1.6, 1.1, (rockIndex % 2) * 0.5))
						* CFrame.Angles(0.14, number + rockIndex, 0.14),
					if rockIndex == 2 then Colors.rockLight else Colors.rock,
					Enum.Material.Slate
				)
				rock:SetAttribute("HealthyColor", rock.Color)
				table.insert(foliage, rock)
			end
			local crystal = part(
				node,
				"MineralSeam",
				Vector3.new(0.6, 2, 0.6),
				CFrame.new(groundPosition + Vector3.new(0, 2.3, -0.5)) * CFrame.Angles(0.2, 0.4, 0.25),
				Colors.glow,
				Enum.Material.Neon,
				false
			)
			crystal:SetAttribute("HealthyColor", crystal.Color)
			table.insert(foliage, crystal)
		end
		local prompt = self:_prompt(
			plot,
			"harvest",
			id,
			position,
			if definition.kind == "wood" then "Timber tree" else "Stone deposit",
			if definition.kind == "wood" then "Gather wood" else "Gather stone"
		)
		plot.nodes[id] = { model = node, prompt = prompt, foliage = foliage, available = nil }
	end
	for _, id in self.config.ProjectOrder do
		local definition = self.config.Projects[id]
		local built = model(islandModel, id .. "_Built")
		local site = model(islandModel, id .. "_BuildingSite")
		local position = localPosition(origin, definition.position)
		local groundPosition = position - Vector3.new(0, definition.position.y, 0)
		disk(site, "BlueprintBase", groundPosition, Vector3.new(0, 0.1, 0), 5.5, 0.2, Colors.sand, Enum.Material.Sand)
		for _, x in { -2, 2 } do
			part(
				site,
				"SurveyStake",
				Vector3.new(0.25, 1.3, 0.25),
				CFrame.new(groundPosition + Vector3.new(x, 0.65, 1.9)),
				Colors.woodLight,
				Enum.Material.Wood,
				false
			)
		end
		local blueprint = part(
			site,
			"Blueprint",
			Vector3.new(2.8, 0.12, 2),
			CFrame.new(groundPosition + Vector3.new(0, 0.27, 0)),
			Colors.glow,
			Enum.Material.Neon,
			false
		)
		local siteLabel = label(blueprint, definition.label, 188, 48)
		local siteGui = siteLabel.Parent :: BillboardGui
		siteGui.StudsOffsetWorldSpace = Vector3.new(0, 5.3, 0)
		local prompt = self:_prompt(plot, "build", id, position, definition.label, "Build")
		if id == "campfire" then
			makeCampfire(built, origin, definition.position)
		elseif id == "bridge" then
			makeBridge(built, origin)
		elseif id == "beacon" then
			local lens, light = makeBeacon(built, origin, definition.position)
			plot.beaconLens = lens
			plot.beaconLight = light
			plot.eventPrompt = self:_prompt(plot, "startEvent", nil, position, "Storm Beacon", "Call the storm")
			plot.eventLabel = label(lens, "STORM BEACON", 205, 48)
		end
		plot.projects[id] = { built = built, site = site, prompt = prompt, label = siteLabel }
	end
	for id, position in self.config.RepairStations do
		local repairModel = model(islandModel, id .. "_RepairStation")
		local targetPosition = localPosition(origin, position)
		local groundPosition = targetPosition - Vector3.new(0, position.y, 0)
		part(
			repairModel,
			"SupplyCrate",
			Vector3.new(2.5, 1.8, 2.1),
			CFrame.new(groundPosition + Vector3.new(0, 0.9, 0)),
			Colors.woodLight,
			Enum.Material.WoodPlanks
		)
		for _, side in { -1, 1 } do
			part(
				repairModel,
				"CrateBinding",
				Vector3.new(0.18, 1.9, 2.15),
				CFrame.new(groundPosition + Vector3.new(side * 0.8, 0.95, 0)),
				Colors.wood,
				Enum.Material.Wood,
				false
			)
		end
		part(
			repairModel,
			"SignalMast",
			Vector3.new(0.3, 4.2, 0.3),
			CFrame.new(groundPosition + Vector3.new(1.3, 2.1, 0)),
			Colors.wood,
			Enum.Material.Wood,
			false
		)
		local lamp = ball(
			repairModel,
			"RepairSignal",
			Vector3.new(1.1, 1.1, 1.1),
			groundPosition + Vector3.new(1.3, 4.5, 0),
			Colors.glow,
			false
		)
		lamp.Material = Enum.Material.Neon
		local prompt = self:_prompt(plot, "repair", id, targetPosition, "Storm supply station", "Secure the island")
		plot.repairs[id] = { model = repairModel, prompt = prompt, lamp = lamp }
	end
	self:updateIsland(ownerId, snapshot)
	return plot
end

function World.updateIsland(self: WorldObject, ownerId: number, snapshot: any)
	local plot = self.plots[ownerId]
	if not plot or type(snapshot) ~= "table" then
		return
	end
	local projects = snapshot.projects or {}
	local accepting = snapshot.accepting ~= false
	local now = os.time()
	setVisible(plot.outcrop, projects.bridge == true)
	for id, visual in plot.projects do
		local definition = self.config.Projects[id]
		local complete = projects[id] == true
		local unlocked = definition.prerequisite == nil or projects[definition.prerequisite] == true
		setVisible(visual.built, complete)
		setVisible(visual.site, not complete)
		local cost = definition.cost
		local costText = tostring(cost.wood)
			.. " wood"
			.. (if cost.stone > 0 then " + " .. tostring(cost.stone) .. " stone" else "")
		local stockpile = snapshot.stockpile or {}
		local progressText = tostring(math.min(stockpile.wood or 0, cost.wood)) .. "/" .. tostring(cost.wood) .. " wood"
		if cost.stone > 0 then
			progressText ..= " · " .. tostring(math.min(stockpile.stone or 0, cost.stone)) .. "/" .. tostring(
				cost.stone
			) .. " stone"
		end
		local text = definition.label
			.. "\n"
			.. (
				if unlocked
					then progressText
					else "Build " .. self.config.Projects[definition.prerequisite].label .. " first"
			)
		if visual.label.Text ~= text then
			visual.label.Text = text
		end
		setPrompt(visual.prompt, accepting and not complete and unlocked, "Build · " .. costText)
	end
	for id, visual in plot.nodes do
		local definition = self.config.Nodes[id]
		local unlocked = definition.prerequisite == nil or projects[definition.prerequisite] == true
		local availableAt = if snapshot.nodes then snapshot.nodes[id] or 0 else 0
		local available = unlocked and availableAt <= now
		setPrompt(visual.prompt, accepting and available)
		if visual.available ~= available then
			visual.available = available
			for _, foliage in visual.foliage do
				local healthy = foliage:GetAttribute("HealthyColor")
				if typeof(healthy) == "Color3" then
					foliage.Color = if available then healthy else healthy:Lerp(Colors.sandEdge, 0.55)
				end
			end
		end
	end
	local event = snapshot.event
	local active = event ~= nil and event.phase == "active"
	local beaconBuilt = projects.beacon == true
	setVisible(plot.stormClouds, beaconBuilt and active)
	for _, repair in plot.repairs do
		setVisible(repair.model, beaconBuilt)
		setPrompt(repair.prompt, accepting and beaconBuilt and active)
		if plot.eventActive ~= active then
			repair.lamp.Color = if active then Colors.storm else Colors.glow
		end
	end
	if plot.eventPrompt then
		setPrompt(plot.eventPrompt, accepting and beaconBuilt and not active and (snapshot.nextEventAt or 0) <= now)
	end
	if plot.eventActive ~= active then
		plot.eventActive = active
		if plot.beaconLens then
			plot.beaconLens.Color = if active then Colors.storm else Colors.glow
			local signal = plot.beaconLens:FindFirstChild("BeaconSignal")
			if signal and signal:IsA("Beam") then
				signal.Color = ColorSequence.new(if active then Colors.storm else Colors.glow)
			end
		end
		if plot.beaconLight then
			plot.beaconLight.Color = if active then Colors.storm else Colors.glow
		end
	end
	if plot.eventLabel then
		local nextEvent = math.max(0, (snapshot.nextEventAt or 0) - now)
		local text = "STORM BEACON\n"
			.. (
				if active
					then "Secure supplies · " .. tostring(event.progress) .. "/" .. tostring(event.required)
					elseif nextEvent > 0 then "Recharging · " .. tostring(math.ceil(nextEvent)) .. "s"
					else "Ready to call a storm"
			)
		if plot.eventLabel.Text ~= text then
			plot.eventLabel.Text = text
		end
	end
end

function World.removeIsland(self: WorldObject, ownerId: number)
	local plot = self.plots[ownerId]
	if not plot then
		return
	end
	self.plots[ownerId] = nil
	for _, connection in plot.connections do
		connection:Disconnect()
	end
	plot.model:Destroy()
	local slot = self.slots[plot.slotIndex]
	if slot and slot.ownerId == ownerId then
		slot.ownerId = nil
		setVisible(slot.pad, true)
	end
end

function World.getSpawn(self: WorldObject, ownerId: number?): CFrame
	local plot = if ownerId then self.plots[ownerId] else nil
	if not plot then
		return self.hubSpawn
	end
	return CFrame.lookAt(plot.origin + Vector3.new(0, 5, 12), plot.origin + Vector3.new(0, 5, -4))
end

function World.getTargetPosition(self: WorldObject, ownerId: number, kind: string, target: string?): Vector3?
	local plot = self.plots[ownerId]
	if not plot then
		return nil
	end
	return plot.targets[kind .. ":" .. (if kind == "startEvent" then "" else target or "")]
end

return World
