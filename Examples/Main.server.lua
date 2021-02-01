-- For a full example, see the original library's readme.
-- https://github.com/Quenty/NevermoreEngine/tree/version2/Modules/Server/DataStore

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DataStoreService = require(ServerStorage.DataStoreService)
local Janitor = require(ReplicatedStorage.Janitor)
local PlayerDataStoreManager = require(ServerStorage.PlayerDataStoreManager)

local dataStoreManager = PlayerDataStoreManager.new(
	DataStoreService:GetDataStore("PlayerData"), --  Load the base Roblox store however you want
	function(player: Player)
		return tostring(player.UserId)
	end
)

local playerJanitors: {[Player]: any} = {}

local function loadStats(playerJanitor, mainStore)
	local leaderboard = Instance.new("Folder")
	leaderboard.Name = "leaderstats"

	local moneyValue = Instance.new("IntValue")
	moneyValue.Name = "Money"
	moneyValue.Parent = leaderboard

	playerJanitor:AddPromise(mainStore:Load("money", 0)):Then(function(money)
		moneyValue.Value = money
		playerJanitor:Add(mainStore:StoreOnValueChange("money", moneyValue), "Disconnect")
	end):Catch(function(problem)
		warn("Failed to load", tostring(problem))
	end):Finally(function()
		moneyValue.Value += 10
	end)

	return leaderboard
end

local function playerAdded(player: Player)
	local playerJanitor = Janitor.new()
	playerJanitors[player] = playerJanitor

	local dataStore = dataStoreManager:GetDataStore(player)
	local mainStore = dataStore:GetSubStore("MainStore")

	local leaderboard = loadStats(playerJanitor, mainStore)
	leaderboard.Parent = player
end

local function playerRemoving(player: Player)
	local playerJanitor = playerJanitors[player]
	if playerJanitor then
		playerJanitors[player] = playerJanitor:Destroy()
	end
end

Players.PlayerAdded:Connect(playerAdded)
Players.PlayerRemoving:Connect(playerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	if playerJanitors[player] then
		continue
	end

	playerAdded(player)
end
