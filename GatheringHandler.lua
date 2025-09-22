local _L = require(game.ReplicatedStorage.Library)

-- Define types
type ZoneData = {
	Objects: {},
	SpawnOnTerrain: boolean,
	SpawnOnFlat: boolean,
	ObjectName: string,
	SpawnRate: number,
	MaxSpawned: number,
	Rewards: {
		Exp: number,
		Item: string,	
	},
	NextId: number,
}

local GatheringHandler = {}
GatheringHandler.__index = GatheringHandler
GatheringHandler.Zones = {
	["Zone1"] = {
		Objects = {},
		SpawnOnTerrain = false,
		SpawnOnFlat = true, -- Spawn on Flat
		ObjectName = "Gold",
		SpawnRate = 1,
		HoldDuration = 5,
		MaxSpawned = 20,
		Rewards = {
			Exp = 5,
			Item = "ItemName",
		},
	},
	["Zone2"] = {
		Objects = {},
		SpawnOnTerrain = true, -- Spawn on Terrain
		SpawnOnFlat = false,
		ObjectName = "Gold",
		SpawnRate = 1,
		HoldDuration = 5,
		MaxSpawned = 20,
		Rewards = {
			Exp = 5,
			Item = "ItemName",
		},
	}
} :: ZoneData -- Cast to ZoneData

-- Intitiate a zone
function GatheringHandler.Init(zoneName: string)
	local zoneData = GatheringHandler.Zones[zoneName]
	if not zoneData then return end
	
	-- Start spawn loop
	task.spawn(function()
		while true do
			-- Count currently alive objects
			local aliveCount = 0
			for _, obj in pairs(zoneData.Objects) do
				if obj and obj.object and obj.object.Parent then
					aliveCount += 1
				end
			end

			-- If under max, spawn one
			if aliveCount < zoneData.MaxSpawned then
				GatheringHandler.CreateObject(zoneName, zoneData)
			end

			-- Wait spawnRate seconds before trying again
			task.wait(zoneData.SpawnRate)
		end
	end)
end


-- Create the object
function GatheringHandler.CreateObject(zoneName: string, zoneData: ZoneData)
	local self = setmetatable({}, GatheringHandler)
		
	-- Zone variables
	self.zoneName = zoneName
	self.zoneData = zoneData
	
	-- Give the object a ID
	self.zoneData.NextId = (self.zoneData.NextId or 0) + 1
	self.objectId = self.zoneName .. "_" .. tostring(self.zoneData.NextId)
	
	-- Setup the object
	self.object = script:FindFirstChild(zoneData.ObjectName)
	if self.object then
		-- Clone the object
		self.object = self.object:Clone()
		
		-- Create the ProximityPrompt
		self.ProximityPrompt = script.ProximityPrompt:Clone()
		self.ProximityPrompt.ActionText = "Gather"
		self.ProximityPrompt.ObjectText = zoneData.ObjectName
		self.ProximityPrompt.HoldDuration = zoneData.HoldDuration
		self.ProximityPrompt.Parent = self.object.PrimaryPart or self.object
		self.ProximityPrompt.Triggered:Connect(function(triggeringPlr)
			self:CollectInstance(triggeringPlr)
		end)
		
		-- Make character not move
		self.ProximityPrompt.PromptButtonHoldBegan:Connect(function(triggeringPlr)
			_L.LockCharacter.SetState(triggeringPlr, true)
		end)
		self.ProximityPrompt.PromptButtonHoldEnded:Connect(function(triggeringPlr)
			_L.LockCharacter.SetState(triggeringPlr, false)
		end)

		
		-- Spawn the object
		self:Spawn()
	end
	
	-- Add self to the objects table
	self.zoneData.Objects[self.objectId] = self
end

-- Spawn the object within the zone
function GatheringHandler:Spawn()
	local zonePart = _L.Game.GatheringZones[self.zoneName] :: BasePart
	local zoneSize = zonePart.Size
	local zoneCFrame = zonePart.CFrame
	local objectsFolder = _L.Game.GatheringZones[self.zoneName].Objects

	-- Function to get the object's height
	local function getObjectHeight(obj)
		if obj:IsA("Model") then
			return obj:GetExtentsSize().Y / 2
		elseif obj:IsA("BasePart") then
			return obj.Size.Y / 2
		end
		return 0
	end
	local objectSizeY = getObjectHeight(self.object)
	
	-- Loop until the object is placed in a valid position
	local validPos, spawnPos = false, nil
	while not validPos do
		-- Pick a random X/Z within the zone
		local minX = zoneCFrame.Position.X - zoneSize.X / 2
		local maxX = zoneCFrame.Position.X + zoneSize.X / 2
		local minZ = zoneCFrame.Position.Z - zoneSize.Z / 2
		local maxZ = zoneCFrame.Position.Z + zoneSize.Z / 2

		local randomX = math.random() * (maxX - minX) + minX
		local randomZ = math.random() * (maxZ - minZ) + minZ

		-- Spawn based on SpawnOnFlat or SpawnOnTerrain
		if self.zoneData.SpawnOnFlat then
			local yPos = zoneCFrame.Position.Y + zoneSize.Y / 2 + objectSizeY
			spawnPos = Vector3.new(randomX, yPos, randomZ)
		elseif self.zoneData.SpawnOnTerrain then
			local startPos = Vector3.new(randomX, zoneCFrame.Position.Y + 1000, randomZ)
			local direction = Vector3.new(0, -2000, 0) -- Raycast down
			local raycastParams = RaycastParams.new()
			
			-- Make sure it doesn't spawn on a player's character
			local playerCharacters = {}
			for _,plr in pairs(_L.Players:GetPlayers()) do
				table.insert(playerCharacters, plr.Character)
			end
			raycastParams.FilterDescendantsInstances = {playerCharacters, zonePart, self.object}
			raycastParams.FilterType = Enum.RaycastFilterType.Exclude

			-- Initiate the raycast
			local result = workspace:Raycast(startPos, direction, raycastParams)
			if result then
				spawnPos = result.Position + Vector3.new(0, objectSizeY, 0)
			else
				continue -- raycast missed, pick another position
			end
		end

		-- Create a bounding box to check for collisions
		local boxSize = if self.object:IsA("Model") then self.object:GetExtentsSize() else self.object.Size
		local boxCFrame = CFrame.new(spawnPos)
		
		-- Create OverlapParams to only consider parts in the zone's Objects folder
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = objectsFolder:GetDescendants()
		local overlappingParts = workspace:GetPartBoundsInBox(boxCFrame, boxSize, overlapParams)
		if #overlappingParts == 0 then
			validPos = true
		end
	end

	-- Move the object to the valid spawn position
	if self.object:IsA("Model") then
		self.object:PivotTo(CFrame.new(spawnPos))
	elseif self.object:IsA("BasePart") then
		self.object.Position = spawnPos
	end

	-- Parent the object
	self.object.Parent = objectsFolder

	-- Apply a random Y-axis rotation
	local randomY = math.rad(math.random(0, 360))
	if self.object:IsA("Model") then
		local pivot = self.object:GetPivot()
		self.object:PivotTo(pivot * CFrame.Angles(0, randomY, 0))
	elseif self.object:IsA("BasePart") then
		self.object.CFrame = self.object.CFrame * CFrame.Angles(0, randomY, 0)
	end
end

-- Collect the object
function GatheringHandler:CollectInstance(plr: Player)
	-- Verify character
	local char = plr.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	
	-- Distance check
	local dist
	if self.object:IsA("Model") then
		dist = (hrp.Position - self.object.PrimaryPart.Position).Magnitude
	elseif self.object:IsA("Part") then
		dist = (hrp.Position - self.object.Position).Magnitude
	end
	if dist > 10 then return end
	
	-- Check if object exists
	if self.object.Parent == _L.Game.GatheringZones[self.zoneName].Objects and not self.Claimed then
		-- Mark as claimed, give reward and destroy the object
		self.Claimed = true
		self:Reward(plr)
		self:DestroyObject()
		
		print("[GatheringHandler]", plr.Name, "gathered", self.zoneData.ObjectName)		
	end	
end

-- Reward the player
function GatheringHandler:Reward(plr: Player)
	-- Add to player's inventory
	-- Function to add to player's inventory
	
	-- Add EXP
	--local expAmount = self.zoneData.Rewards.Exp
	-- Function to add to EXP
end

-- Destroy method
function GatheringHandler:DestroyObject()
	-- Delete the object
	if self.object then
		self.object:Destroy()
		self.object = nil
	end

	-- Remove from zone objects
	if self.zoneData.Objects[self.objectId] then
		self.zoneData.Objects[self.objectId] = nil
	end
	self = nil
end

-- Intitiate all of the zones
for zoneName,zoneData in pairs(GatheringHandler.Zones) do
	GatheringHandler.Init(zoneName)
end
	
return GatheringHandler