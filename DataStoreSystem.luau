local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local PlayerDataStore = DataStoreService:GetDataStore("PlayerData_Production_v1")

local MAX_RETRIES = 4
local RETRY_DELAY = 1.5
local AUTO_SAVE_INTERVAL = 180

export type PlayerProfile = {
	Coins: number,
	Gems: number,
	Wins: number,
	Level: number,
	Experience: number,
	Inventory: { string },
	SessionLock: string?,
}

local DEFAULT_TEMPLATE: PlayerProfile = {
	Coins = 100,
	Gems = 0,
	Wins = 0,
	Level = 1,
	Experience = 0,
	Inventory = {},
	SessionLock = nil,
}

local ActiveProfiles: { [number]: PlayerProfile } = {}
local LoadedPlayers: { [number]: boolean } = {}

local function deepCopy(source: { [any]: any }): { [any]: any }
	local copy = {}
	for key, value in pairs(source) do
		copy[key] = if type(value) == "table" then deepCopy(value) else value
	end
	return copy
end

local function reconcileData(target: { [any]: any }, template: { [any]: any })
	for key, value in pairs(template) do
		if target[key] == nil then
			target[key] = if type(value) == "table" then deepCopy(value) else value
		elseif type(target[key]) == "table" and type(value) == "table" then
			reconcileData(target[key], value)
		end
	end
end

local function retryAsync(callback: () -> any): (boolean, any)
	local success = false
	local result = nil

	for attempt = 1, MAX_RETRIES do
		success, result = pcall(callback)
		if success then
			return true, result
		end
		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end

	return false, result
end

local function setupLeaderstats(player: Player, profile: PlayerProfile)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = profile.Coins
	coins.Parent = leaderstats

	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Value = profile.Wins
	wins.Parent = leaderstats

	coins.Changed:Connect(function(newValue: number)
		if ActiveProfiles[player.UserId] then
			ActiveProfiles[player.UserId].Coins = newValue
		end
	end)

	wins.Changed:Connect(function(newValue: number)
		if ActiveProfiles[player.UserId] then
			ActiveProfiles[player.UserId].Wins = newValue
		end
	end)
end

local function loadProfile(player: Player)
	local userId = player.UserId
	local key = `Player_{userId}`
	local currentJobId = if game.JobId ~= "" then game.JobId else "StudioSession"

	local success, data = retryAsync(function()
		return PlayerDataStore:UpdateAsync(key, function(oldData: PlayerProfile?)
			local profile: PlayerProfile = if type(oldData) == "table"
				then oldData
				else (deepCopy(DEFAULT_TEMPLATE) :: PlayerProfile)

			reconcileData(profile, DEFAULT_TEMPLATE)
			profile.SessionLock = currentJobId
			return profile
		end)
	end)

	if not player:IsDescendantOf(Players) then
		return
	end

	if not success or type(data) ~= "table" then
		player:Kick("Unable to load your data safely. Please rejoin in a moment.")
		return
	end

	ActiveProfiles[userId] = data :: PlayerProfile
	LoadedPlayers[userId] = true
	setupLeaderstats(player, ActiveProfiles[userId])
end

local function saveProfile(player: Player, releaseLock: boolean)
	local userId = player.UserId
	if not LoadedPlayers[userId] then
		return
	end

	local profile = ActiveProfiles[userId]
	if not profile then
		return
	end

	local key = `Player_{userId}`
	local snapshot = deepCopy(profile) :: PlayerProfile
	if releaseLock then
		snapshot.SessionLock = nil
	end

	retryAsync(function()
		PlayerDataStore:UpdateAsync(key, function()
			return snapshot
		end)
	end)
end

Players.PlayerAdded:Connect(loadProfile)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
	task.spawn(loadProfile, existingPlayer)
end

Players.PlayerRemoving:Connect(function(player: Player)
	local userId = player.UserId
	saveProfile(player, true)
	ActiveProfiles[userId] = nil
	LoadedPlayers[userId] = nil
end)

task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			if LoadedPlayers[player.UserId] then
				task.spawn(saveProfile, player, false)
			end
		end
	end
end)

game:BindToClose(function()
	if RunService:IsStudio() then
		task.wait(1)
		return
	end

	local activeTasks = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if LoadedPlayers[player.UserId] then
			activeTasks += 1
			task.spawn(function()
				saveProfile(player, true)
				activeTasks -= 1
			end)
		end
	end

	local timeout = 0
	while activeTasks > 0 and timeout < 10 do
		task.wait(0.25)
		timeout += 0.25
	end
end)
