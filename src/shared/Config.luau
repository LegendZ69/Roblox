--!strict
local Config = {
	Title = "Driftwood Isles",
	MaxPlayers = 4,
	InteractionDistance = 18,
	EventDuration = 90,
	EventCooldown = 180,
	RepairCooldown = 5,
	EventReward = { wood = 24, stone = 12 },
	LeaseSeconds = 120,
	AutosaveSeconds = 30,
	DataStoreName = "DriftwoodIsles_v1",
	ProjectOrder = { "campfire", "bridge", "beacon" },
	Resources = {
		wood = { label = "Wood", yield = 3, cooldown = 7 },
		stone = { label = "Stone", yield = 2, cooldown = 8 },
	},
	Projects = {
		campfire = { label = "Campfire", cost = { wood = 12, stone = 0 }, position = { x = -8, y = 3, z = 6 } },
		bridge = {
			label = "Stoneway Bridge",
			cost = { wood = 30, stone = 0 },
			prerequisite = "campfire",
			position = { x = 31, y = 3, z = 0 },
		},
		beacon = {
			label = "Storm Beacon",
			cost = { wood = 40, stone = 20 },
			prerequisite = "bridge",
			position = { x = 12, y = 3, z = -18 },
		},
	},
	Nodes = {
		wood1 = { kind = "wood", position = { x = -25, y = 3, z = -17 } },
		wood2 = { kind = "wood", position = { x = -16, y = 3, z = -25 } },
		wood3 = { kind = "wood", position = { x = -30, y = 3, z = 8 } },
		wood4 = { kind = "wood", position = { x = -19, y = 3, z = 23 } },
		wood5 = { kind = "wood", position = { x = 7, y = 3, z = 24 } },
		wood6 = { kind = "wood", position = { x = 23, y = 3, z = 18 } },
		stone1 = { kind = "stone", prerequisite = "bridge", position = { x = 62, y = 3, z = -9 } },
		stone2 = { kind = "stone", prerequisite = "bridge", position = { x = 75, y = 3, z = -7 } },
		stone3 = { kind = "stone", prerequisite = "bridge", position = { x = 63, y = 3, z = 9 } },
		stone4 = { kind = "stone", prerequisite = "bridge", position = { x = 76, y = 3, z = 8 } },
	},
	RepairStations = {
		repair1 = { x = -5, y = 3, z = -17 },
		repair2 = { x = 20, y = 3, z = 10 },
		repair3 = { x = -17, y = 3, z = 14 },
	},
}
return table.freeze(Config)
