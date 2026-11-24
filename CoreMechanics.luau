local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type ItemConfig = {
	Id: string,
	DisplayName: string,
	Category: "Tool" | "Upgrade" | "Trail",
	Price: number,
	RequiredWins: number,
	SpeedMultiplier: number,
}

export type PlayerInventoryState = {
	Owned: { [string]: boolean },
	Equipped: { [string]: string? },
	LastRequestTime: number,
}

local CoreMechanics = {}
CoreMechanics.__index = CoreMechanics

local REQUEST_COOLDOWN = 0.35

local ITEM_CATALOG: { [string]: ItemConfig } = {
	["SpeedCoil_T1"] = {
		Id = "SpeedCoil_T1",
		DisplayName = "Kinetic Speed Coil",
		Category = "Tool",
		Price = 250,
		RequiredWins = 0,
		SpeedMultiplier = 1.25,
	},
	["GravityCoil_T2"] = {
		Id = "GravityCoil_T2",
		DisplayName = "Zero-G Coil",
		Category = "Tool",
		Price = 800,
		RequiredWins = 3,
		SpeedMultiplier = 1.45,
	},
	["EmeraldTrail"] = {
		Id = "EmeraldTrail",
		DisplayName = "Emerald Surge Trail",
		Category = "Trail",
		Price = 1500,
		RequiredWins = 5,
		SpeedMultiplier = 1.15,
	},
}

function CoreMechanics.new()
	local self = setmetatable({}, CoreMechanics)
	self.PlayerStates = {} :: { [number]: PlayerInventoryState }
	self.RemoteFunction = nil :: RemoteFunction?
	return self
end

function CoreMechanics:Init()
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local shopRemote = remotesFolder:FindFirstChild("ShopAction") :: RemoteFunction?
	if not shopRemote then
		shopRemote = Instance.new("RemoteFunction")
		shopRemote.Name = "ShopAction"
		shopRemote.Parent = remotesFolder
	end

	self.RemoteFunction = shopRemote

	shopRemote.OnServerInvoke = function(player: Player, action: unknown, itemId: unknown)
		return self:HandleClientRequest(player, action, itemId)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		self:RegisterPlayer(player)
		player.CharacterAdded:Connect(function(character: Model)
			self:ApplyEquippedModifiers(player, character)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self.PlayerStates[player.UserId] = nil
	end)

	for _, existingPlayer in ipairs(Players:GetPlayers()) do
		self:RegisterPlayer(existingPlayer)
	end
end

function CoreMechanics:RegisterPlayer(player: Player)
	if self.PlayerStates[player.UserId] then
		return
	end

	self.PlayerStates[player.UserId] = {
		Owned = {},
		Equipped = {},
		LastRequestTime = 0,
	}
end

function CoreMechanics:IsRateLimited(state: PlayerInventoryState): boolean
	local now = os.clock()
	if (now - state.LastRequestTime) < REQUEST_COOLDOWN then
		return true
	end
	state.LastRequestTime = now
	return false
end

function CoreMechanics:HandleClientRequest(
	player: Player,
	action: unknown,
	itemId: unknown
): (boolean, string)
	local state = self.PlayerStates[player.UserId]
	if not state then
		return false, "Session state not initialized."
	end

	if self:IsRateLimited(state) then
		return false, "Too many requests. Please slow down."
	end

	if type(action) ~= "string" or type(itemId) ~= "string" then
		return false, "Malformed request payload."
	end

	local item = ITEM_CATALOG[itemId]
	if not item then
		return false, "Requested item does not exist."
	end

	if action == "Purchase" then
		return self:PurchaseItem(player, state, item)
	elseif action == "Equip" then
		return self:EquipItem(player, state, item)
	end

	return false, "Unknown action type."
end

function CoreMechanics:PurchaseItem(
	player: Player,
	state: PlayerInventoryState,
	item: ItemConfig
): (boolean, string)
	if state.Owned[item.Id] then
		return false, "Item is already owned."
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	local coins = leaderstats and leaderstats:FindFirstChild("Coins") :: IntValue?
	local wins = leaderstats and leaderstats:FindFirstChild("Wins") :: IntValue?

	if not coins or not wins then
		return false, "Player stats unavailable."
	end

	if wins.Value < item.RequiredWins then
		return false, `Requires at least {item.RequiredWins} wins.`
	end

	if coins.Value < item.Price then
		return false, "Insufficient coins."
	end

	coins.Value -= item.Price
	state.Owned[item.Id] = true
	state.Equipped[item.Category] = item.Id

	if player.Character then
		self:ApplyEquippedModifiers(player, player.Character)
	end

	return true, `Purchased and equipped {item.DisplayName}!`
end

function CoreMechanics:EquipItem(
	player: Player,
	state: PlayerInventoryState,
	item: ItemConfig
): (boolean, string)
	if not state.Owned[item.Id] then
		return false, "You do not own this item."
	end

	state.Equipped[item.Category] = item.Id

	if player.Character then
		self:ApplyEquippedModifiers(player, player.Character)
	end

	return true, `Equipped {item.DisplayName}.`
end

function CoreMechanics:ApplyEquippedModifiers(player: Player, character: Model)
	local state = self.PlayerStates[player.UserId]
	if not state then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local totalMultiplier = 1.0
	for _, equippedId in pairs(state.Equipped) do
		if equippedId then
			local item = ITEM_CATALOG[equippedId]
			if item then
				totalMultiplier = math.max(totalMultiplier, item.SpeedMultiplier)
			end
		end
	end

	humanoid.WalkSpeed = math.round(16 * totalMultiplier)
end

function CoreMechanics:GetCatalog(): { [string]: ItemConfig }
	return ITEM_CATALOG
end

return CoreMechanics
