local HttpService = game:GetService("HttpService")

local DataStoreDeleteToken = require(script.Parent.Modules.DataStoreDeleteToken)
local DataStorePromises = require(script.Parent.Utility.DataStorePromises)
local DataStoreStage = require(script.Parent.Modules.DataStoreStage)
local Janitor = require(script.Parent.Vendor.Janitor)
local Promise = require(script.Parent.Vendor.Promise)
local Scheduler = require(script.Parent.Vendor.Scheduler)
local Signal = require(script.Parent.Vendor.Signal)
local t = require(script.Parent.Vendor.t)

local DEBUG_WRITING = false

local AUTO_SAVE_TIME = 60 * 5
local CHECK_DIVISION = 15
local JITTER = 20 -- Randomly assign jitter so if a ton of players join at once we don't hit the datastore at once

local DataStore = setmetatable({ClassName = "DataStore"}, DataStoreStage)
DataStore.__index = DataStore

local assertConstructorTuple = t.strict(t.tuple(t.union(t.instanceIsA("GlobalDataStore"), t.table), t.string))

function DataStore.new(robloxDataStore, key)
	assertConstructorTuple(robloxDataStore, key)
	local self = setmetatable(DataStoreStage.new(), DataStore)

	self._key = key
	self._robloxDataStore = robloxDataStore

	self.Saving = self._janitor:Add(Signal.new(), "Destroy") -- :Fire(promise)

	Scheduler.Spawn(function()
		while self.Destroy do
			for _ = 1, CHECK_DIVISION do
				Scheduler.Wait(AUTO_SAVE_TIME / CHECK_DIVISION)
				if not self.Destroy then
					break
				end
			end

			if not self.Destroy then
				break
			end

			-- Apply additional jitter on auto-save
			Scheduler.Wait(math.random(1, JITTER))

			if not self.Destroy then
				break
			end

			self:Save()
		end
	end)

	return self
end

function DataStore:GetFullPath(): string
	return string.format("RobloxDataStore@%s", self._key)
end

function DataStore:DidLoadFail(): boolean
	if not self._loadPromise then
		return false
	end

	if self._loadPromise:GetStatus() == Promise.Status.Rejected then
		return true
	end

	return false
end

function DataStore:PromiseLoadSuccessful()
	return self._janitor:AddPromise(self:_promiseLoad()):Then(function()
		return true
	end, function()
		return false
	end)
end

-- Saves all stored data
function DataStore:Save()
	if self:DidLoadFail() then
		warn("[DataStore.Save] - Not saving, failed to load")
		return Promise.Reject("Load not successful, not saving")
	end

	if not self:HasWritableData() then
		-- Nothing to save, don't update anything
		if DEBUG_WRITING then
			print("[DataStore.Save] - Not saving, nothing staged")
		end

		return Promise.Resolve(nil)
	end

	return self:_saveData(self:GetNewWriter())
end

-- Loads data. This returns the originally loaded data.
function DataStore:Load(keyName: string, defaultValue: any)
	return self:_promiseLoad():Then(function(data)
		return self:_afterLoadGetAndApplyStagedData(keyName, data, defaultValue)
	end)
end

function DataStore:_saveData(writer)
	local janitor = self._janitor:Add(Janitor.new(), "Destroy", "SaveJanitor")
	local promise
	promise = Promise.new(function(resolve)
		resolve(janitor:AddPromise(DataStorePromises.promiseUpdate(self._robloxDataStore, self._key, function(data)
			if promise:GetStatus() == Promise.Status.Rejected then
				-- Cancel if we have another request
				return nil
			end

			data = writer:WriteMerge(data or {})
			assert(data ~= DataStoreDeleteToken, "Cannot delete from UpdateAsync")

			if DEBUG_WRITING then
				print("[DataStore] - Writing", HttpService:JSONEncode(data))
			end

			return data
		end)))
	end)

	if self.Saving.Destroy then
		self.Saving:Fire(promise)
	end

	return promise
end

function DataStore:_promiseLoad()
	if self._loadPromise then
		return self._loadPromise
	end

	self._loadPromise = self._janitor:AddPromise(DataStorePromises.promiseGet(self._robloxDataStore, self._key):Then(function(data)
		if data == nil then
			return {}
		elseif type(data) == "table" then
			return data
		else
			return Promise.Reject("Failed to load data. Wrong type '" .. type(data) .. "'")
		end
	end, function(err)
		-- Log:
		warn("[DataStore] - Failed to GetAsync data", err)
		return Promise.Reject(err)
	end))

	return self._loadPromise
end

return DataStore
