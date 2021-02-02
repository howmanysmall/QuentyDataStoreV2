--[[
	MIT License

	Copyright (c) 2014 Quenty

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local DataStore = require(script.Parent.DataStore)
local Janitor = require(script.Parent.Vendor.Janitor)
local PendingPromiseTracker = require(script.Parent.Vendor.PendingPromiseTracker)
local Promise = require(script.Parent.Vendor.Promise)
local t = require(script.Parent.Vendor.t)

local PlayerDataStoreManager = {ClassName = "PlayerDataStoreManager"}
PlayerDataStoreManager.__index = PlayerDataStoreManager

local AssertConstructorTuple = t.strict(t.tuple(t.union(t.instanceIsA("GlobalDataStore"), t.table), t.callback))
local AssertPlayer = t.strict(t.instanceIsA("Player"))

function PlayerDataStoreManager.new(robloxDataStore: GlobalDataStore, keyGenerator: (Player) -> string)
	AssertConstructorTuple(robloxDataStore, keyGenerator)

	local self = setmetatable(
		{
			_robloxDataStore = robloxDataStore;
			_keyGenerator = keyGenerator;
			_janitor = Janitor.new();

			_datastores = {}; -- [player] = datastore
			_removing = {}; -- [player] = true
			_pendingSaves = PendingPromiseTracker.new();
			_removingCallbacks = {}; -- [func, ...]
			_disableSavingInStudio = false;
		},
		PlayerDataStoreManager
	)

	self._janitor:Add(Janitor.new(), "Destroy", "SavingConnections")
	self._janitor:Add(
		Players.PlayerRemoving:Connect(function(player)
			if self._disableSavingInStudio then
				return
			end

			self:RemovePlayerDataStore(player)
		end),
		"Disconnect"
	)

	game:BindToClose(function()
		if self._disableSavingInStudio then
			return
		end

		self:PromiseAllSaves():await()
	end)

	return self
end

--- For if you want to disable saving in studio for faster close time!
function PlayerDataStoreManager:DisableSaveOnCloseStudio()
	assert(RunService:IsStudio())
	self._disableSavingInStudio = true
end

--- Adds a callback to be called before save on removal
function PlayerDataStoreManager:AddRemovingCallback(callback: (Player) -> nil)
	assert(t.callback(callback))
	table.insert(self._removingCallbacks, callback)
end

--- Callable to allow manual GC so things can properly clean up.
-- This can be used to pre-emptively cleanup players.
function PlayerDataStoreManager:RemovePlayerDataStore(player: Player)
	AssertPlayer(player)
	local datastore = self._datastores[player]
	if not datastore then
		return
	end

	self._removing[player] = true

	for _, func in ipairs(self._removingCallbacks) do
		func(player)
	end

	datastore:Save():finally(function()
		datastore:Destroy()
		self._removing[player] = nil
	end)

	-- Prevent double removal or additional issues
	self._datastores[player] = nil
	self._janitor:Get("SavingConnections"):Remove(player)
end

function PlayerDataStoreManager:GetDataStore(player: Player)
	AssertPlayer(player)
	if self._removing[player] then
		warn("[PlayerDataStoreManager.GetDataStore] - Called GetDataStore while player is removing, cannot retrieve")
		return nil
	end

	if self._datastores[player] then
		return self._datastores[player]
	end

	return self:_createDataStore(player)
end

function PlayerDataStoreManager:PromiseAllSaves()
	for player in pairs(self._datastores) do
		self:RemovePlayerDataStore(player)
	end

	return self._janitor:AddPromise(Promise.all(self._pendingSaves:GetAll()))
end

function PlayerDataStoreManager:Destroy()
	self._janitor:Destroy()
	setmetatable(self, nil)
end

function PlayerDataStoreManager:_createDataStore(player: Player)
	assert(not self._datastores[player], "Player already has a DataStore.")

	local datastore = DataStore.new(self._robloxDataStore, self:_getKey(player))
	self._janitor:Get("SavingConnections"):Add( -- i have no idea why this was done the way it was
		datastore.Saving:Connect(function(promise)
			self._pendingSaves:Add(promise)
		end),
		"Disconnect",
		player
	)

	self._datastores[player] = datastore
	return datastore
end

function PlayerDataStoreManager:_getKey(player: Player)
	return self._keyGenerator(player)
end

return PlayerDataStoreManager
