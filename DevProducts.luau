local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local PurchaseHistoryStore = DataStoreService:GetDataStore("PurchaseHistory_Production_v1")

local MAX_RETRIES = 4
local RETRY_DELAY = 1.25

type ReceiptInfo = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	PlaceIdWherePurchased: number,
	CurrencySpent: number,
	CurrencyType: Enum.CurrencyType,
}

local ProcessedReceiptsCache: { [string]: boolean } = {}

local PRODUCT_REWARDS: { [number]: (player: Player) -> boolean } = {
	[1849201451] = function(player: Player)
		local leaderstats = player:FindFirstChild("leaderstats")
		local coins = leaderstats and leaderstats:FindFirstChild("Coins") :: IntValue?
		if not coins then
			return false
		end
		coins.Value += 500
		return true
	end,

	[1849201892] = function(player: Player)
		local leaderstats = player:FindFirstChild("leaderstats")
		local coins = leaderstats and leaderstats:FindFirstChild("Coins") :: IntValue?
		if not coins then
			return false
		end
		coins.Value += 2500
		return true
	end,

	[1849202310] = function(player: Player)
		local leaderstats = player:FindFirstChild("leaderstats")
		local wins = leaderstats and leaderstats:FindFirstChild("Wins") :: IntValue?
		if not wins then
			return false
		end
		wins.Value += 10
		return true
	end,
}

local GAMEPASS_HANDLERS: { [number]: (player: Player) -> () } = {
	[842910441] = function(player: Player)
		player:SetAttribute("HasVIP", true)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = 24
		end
	end,

	[842910995] = function(player: Player)
		player:SetAttribute("DoubleCoins", true)
	end,
}

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

local function isReceiptProcessed(receiptKey: string): (boolean, boolean)
	if ProcessedReceiptsCache[receiptKey] then
		return true, true
	end

	local success, isRecorded = retryAsync(function()
		return PurchaseHistoryStore:GetAsync(receiptKey)
	end)

	if not success then
		return false, false
	end

	if isRecorded == true then
		ProcessedReceiptsCache[receiptKey] = true
		return true, true
	end

	return true, false
end

local function recordReceipt(receiptKey: string, receiptInfo: ReceiptInfo): boolean
	local success = retryAsync(function()
		PurchaseHistoryStore:UpdateAsync(receiptKey, function(existingValue: any)
			if existingValue ~= nil then
				return existingValue
			end
			return {
				ProductId = receiptInfo.ProductId,
				CurrencySpent = receiptInfo.CurrencySpent,
				Timestamp = os.time(),
			}
		end)
	end)

	if success then
		ProcessedReceiptsCache[receiptKey] = true
	end

	return success
end

local function processReceipt(receiptInfo: ReceiptInfo): Enum.ProductPurchaseDecision
	local receiptKey = `{receiptInfo.PlayerId}_{receiptInfo.PurchaseId}`

	local checkOk, alreadyGranted = isReceiptProcessed(receiptKey)
	if not checkOk then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if alreadyGranted then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player or not player:IsDescendantOf(Players) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local rewardHandler = PRODUCT_REWARDS[receiptInfo.ProductId]
	if not rewardHandler then
		warn(`[Monetization] Unregistered ProductId: {receiptInfo.ProductId}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local grantSuccess, granted = pcall(rewardHandler, player)
	if not grantSuccess or granted ~= true then
		warn(`[Monetization] Failed to apply reward for {player.Name} ({receiptInfo.ProductId})`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local recorded = recordReceipt(receiptKey, receiptInfo)
	if not recorded then
		warn(`[Monetization] Reward granted, but failed to log receipt {receiptKey}`)
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function checkPlayerGamepasses(player: Player)
	for passId, applyPass in pairs(GAMEPASS_HANDLERS) do
		task.spawn(function()
			local success, ownsPass = retryAsync(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
			end)

			if success and ownsPass and player:IsDescendantOf(Players) then
				applyPass(player)
			end
		end)
	end
end

MarketplaceService.ProcessReceipt = processReceipt

MarketplaceService.PromptGamePassPurchaseFinished:Connect(
	function(player: Player, passId: number, wasPurchased: boolean)
		if not wasPurchased then
			return
		end

		local applyPass = GAMEPASS_HANDLERS[passId]
		if applyPass and player:IsDescendantOf(Players) then
			applyPass(player)
		end
	end
)

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function()
		if player:GetAttribute("HasVIP") then
			local applyPass = GAMEPASS_HANDLERS[842910441]
			if applyPass then
				applyPass(player)
			end
		end
	end)

	checkPlayerGamepasses(player)
end)

for _, existingPlayer in ipairs(Players:GetPlayers()) do
	task.spawn(checkPlayerGamepasses, existingPlayer)
end
