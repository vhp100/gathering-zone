--[[
    This module is responsible for **managing player items** in the inventory.
    It abstracts away logic for:
    - Giving new items
    - Removing or trashing items
    - Locking items (protection against deletion)
    - Attribute handling (stacking, rarity, defaults)
    - Inventory caps / bypasses (normal vs. gamepass)
    - Client/server synchronization

    Design philosophy:
    - Each item is saved individually with a unique ItemID ("Item_1", "Item_2"...).
    - Items can carry attributes (damage, durability, custom stats).
    - Non-unique stackable items are handled by simply saving multiple entries.
    - This ensures consistent behavior across all cases (unique vs stackable).
    - Functions always validate player data before modifying.

    By separating this from UI code, we ensure inventory logic is **server-authoritative**.
]]

local _L = require(game.ReplicatedStorage.Library)

local ItemsHandler = {}

-- Types used in this handler
export type ItemData = {
	ItemID: string,                     -- unique string ID per item instance
	ItemName: string,                   -- the template name (matches _L.Items)
	Amt: number,                        -- amount to give/remove (used when spawning items)
	Attributes: {[string]: any}?,       -- optional attributes, e.g. {Damage=10, Durability=50}
	BypassInventoryCap: boolean,        -- allows ignoring cap (e.g. for quest rewards)
}

----------------------------------------------------------------
-- Internal Utility Functions
----------------------------------------------------------------

-- Shallow compare two attributes tables to check if they "match"
-- This allows us to distinguish between items that look the same
-- but have different stats (e.g., Sword with 5 damage vs. 10 damage).
local function attributesMatch(a: {[string]: any}?, b: {[string]: any}?): boolean
	a = a or {}
	b = b or {}

	-- Case 1: both empty → match
	if next(a) == nil and next(b) == nil then
		return true
	end

	-- Case 2: check values in `a` against `b`
	for k, v in pairs(a) do
		local bv = b[k]
		if type(v) == "table" and type(bv) == "table" then
			for nk, nv in pairs(v) do
				if bv[nk] ~= nv then return false end
			end
		elseif bv ~= v then
			return false
		end
	end

	-- Case 3: check values in `b` against `a` (catch mismatched keys)
	for k, v in pairs(b) do
		local av = a[k]
		if type(v) == "table" and type(av) == "table" then
			for nk, nv in pairs(v) do
				if av[nk] ~= nv then return false end
			end
		elseif av ~= v then
			return false
		end
	end

	return true
end

-- Generates a unique ItemID for new items.
-- The system always increments the **highest found index**,
-- ensuring no collisions even if items were deleted.
local function generateItemID(savedItems: {[string]: ItemData}): string
	local maxId = 0

	for id, _ in pairs(savedItems) do
		local num = tonumber(string.match(id, "^Item_(%d+)$"))
		if num and num > maxId then
			maxId = num
		end
	end

	return "Item_" .. tostring(maxId + 1)
end

-- Returns a player’s saved items safely.
-- This ensures we always access the correct **profile inventory**.
function ItemsHandler.GetSavedItems(plr: Player): {ItemData}
	local profile = _L.DataHolder.Profiles[plr]
	if not profile then return end
	return profile.Data.Inventory
end

----------------------------------------------------------------
-- Attribute Initialization / Default Sync
----------------------------------------------------------------

-- Update default values for a saved item using the template in _L.Items.
-- Example: If a Sword template defines {Damage=10}, but the saved data is missing it,
--          this ensures the player's Sword item gets updated with DefaultAmt=10.
function ItemsHandler.UpdateDefaultData(plr: Player, data: ItemData)
	local itemTemplate = _L.Items:FindFirstChild(data.ItemName)
	if not itemTemplate then return end

	local attributesFolder = itemTemplate:FindFirstChild("Attributes")
	if not attributesFolder then return end

	-- Ensure Attributes table exists
	if not data.Attributes then
		data.Attributes = {}
	end

	-- Iterate template attributes and sync missing defaults
	for _, attribute in pairs(attributesFolder:GetChildren()) do
		if not data.Attributes[attribute.Name] then
			data.Attributes[attribute.Name] = {}
		end
		data.Attributes[attribute.Name].DefaultAmt = attribute.Value
	end
	
	-- Sync rarity from template
	local rarity = itemTemplate:FindFirstChild("Rarity")
	if rarity then
		data.Rarity = rarity.Value
	end
end

-- Initialize all items for a player at login.
-- Ensures that items remain **up-to-date** even after template changes.
function ItemsHandler.Init(plr: Player)
	local savedItems = ItemsHandler.GetSavedItems(plr)
	if not savedItems then return end

	for _, item in pairs(savedItems) do
		ItemsHandler.UpdateDefaultData(plr, item)
	end
end

----------------------------------------------------------------
-- Core Inventory Functions
----------------------------------------------------------------

-- GiveItem: Adds one or more items to the player's saved inventory.
-- Handles inventory caps, unique IDs, and client synchronization.
function ItemsHandler.GiveItem(plr: Player, data: ItemData)
	local savedItems = ItemsHandler.GetSavedItems(plr)
	if not savedItems then return end

	local itemTemplate = _L.Items:FindFirstChild(data.ItemName)
	if not itemTemplate then
		warn("Invalid item:", data.ItemName)
		return
	end

	-- Normalize fields
	local amtToGive = data.Amt or 1
	data.Amt = nil
	local bypassInventoryCap = data.BypassInventoryCap or false
	data.BypassInventoryCap = nil
	data.Locked = false -- new items never start locked
	
	-- Sync rarity if defined in template
	if itemTemplate:FindFirstChild("Rarity") then
		data.Rarity = itemTemplate.Rarity.Value
	end

	-- Ensure attributes exist
	if not data.Attributes then
		data.Attributes = {}
		local attributesFolder = itemTemplate:FindFirstChild("Attributes")
		if attributesFolder then
			for _, attribute in pairs(attributesFolder:GetChildren()) do
				if attribute:IsA("ValueBase") then
					data.Attributes[attribute.Name] = { DefaultAmt = attribute.Value }
				end
			end
		end
	end
	
	-- Inventory Cap Logic
	local hasIncreasedCap = _L.GamepassHandler.HasGamepass(plr, _L.GamepassIDS["InventoryCapIncrease"])
	local capLimit = hasIncreasedCap and _L.InventoryHandler.GAMEPASS_CAP or _L.InventoryHandler.DEFAULT_CAP
	
	local inventorySize = _L.InventoryHandler.GetInventorySize(plr)
	local canGive = ((inventorySize + amtToGive) <= capLimit) or bypassInventoryCap

	if canGive then
		-- Insert each item individually (unique ID per entry)
		for i = 1, amtToGive do
			local newData = table.clone(data)
			newData.ItemID = generateItemID(savedItems)
			savedItems[newData.ItemID] = newData
			
			print("[ItemsHandler] Added", newData.ItemID, "to:", plr.Name, "| BypassCap:", bypassInventoryCap)
			
			-- Replicate to client immediately
			_L.InventoryHandler.AddItemToClient(plr, newData)
		end
	else
		warn("[ItemsHandler] ❌", plr.Name, "has reached their inventory limit! (", inventorySize, "/", capLimit, ")")
	end
end

-- LockItem: Prevents accidental deletion/trashing of an item.
-- Useful for rare/valuable items.
function ItemsHandler.LockItem(plr: Player, itemID: string, state: boolean)
	local savedItems = ItemsHandler.GetSavedItems(plr)
	if not savedItems or not savedItems[itemID] then return end
	if typeof(state) ~= "boolean" then return end
	savedItems[itemID].Locked = state
	return { Success = true, CurrentState = savedItems[itemID].Locked }
end

-- TrashItem: Deletes an item permanently unless it is locked.
-- This prevents accidental deletion of locked valuables.
function ItemsHandler.TrashItem(plr: Player, itemID: string)
	local savedItems = ItemsHandler.GetSavedItems(plr)
	if not savedItems or not savedItems[itemID] then return end

	if savedItems[itemID].Locked then
		warn("[ItemsHandler] Cannot remove locked item:", itemID, "Player:", plr.Name)
	else
		savedItems[itemID] = nil
		print("[ItemsHandler] Trashed", itemID, "from:", plr.Name)
		return { Success = true }
	end
end

-- RemoveItem: Removes an item based on filters.
-- Supports matching by:
--   - ItemName
--   - Attributes
--   - ItemID (exact match)
--   - Amt (number to remove)
function ItemsHandler.RemoveItem(plr: Player, data: ItemData, amt: number?)
	local savedItems = ItemsHandler.GetSavedItems(plr)
	if not savedItems then return end

	local checkAttributes = data.Attributes ~= nil
	local checkID = data.ItemID ~= nil
	local removed = 0

	for itemID, item in pairs(savedItems) do
		if item.ItemName == data.ItemName
			and (not checkAttributes or attributesMatch(item.Attributes, data.Attributes))
			and (not checkID or item.ItemID == data.ItemID) then

			savedItems[itemID] = nil
			removed += 1
			print("[ItemsHandler] Removed", itemID, "from:", plr.Name)

			if amt and removed >= amt then
				break -- removed enough
			elseif not amt then
				break -- remove only one by default
			end
		end
	end
end

-- HasItem: Checks if a player owns enough of an item.
-- Supports checking by attributes (e.g., "Has Sword with Damage=10?").
function ItemsHandler.HasItem(plr: Player, data: ItemData, amt: number?): boolean
	local savedItems = ItemsHandler.GetSavedItems(plr)
	if not savedItems then return false end

	local checkAttributes = data.Attributes ~= nil
	local count = 0

	for _, item in pairs(savedItems) do
		if item.ItemName == data.ItemName then
			if not checkAttributes or attributesMatch(item.Attributes, data.Attributes) then
				count += 1
				if not amt then
					return true -- exists
				elseif count >= amt then
					return true -- enough found
				end
			end
		end
	end

	return false
end

----------------------------------------------------------------
-- Remote Event Bindings
----------------------------------------------------------------
_L.Events.ItemsHandler.LockItem.OnServerInvoke = ItemsHandler.LockItem
_L.Events.ItemsHandler.TrashItem.OnServerInvoke = ItemsHandler.TrashItem

----------------------------------------------------------------
return ItemsHandler
