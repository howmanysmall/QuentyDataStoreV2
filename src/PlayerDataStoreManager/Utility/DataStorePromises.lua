local Promise = require(script.Parent.Parent.Vendor.Promise)
local t = require(script.Parent.Parent.Vendor.t)

local DataStorePromises = {}

local dataStoreInstance = t.union(t.instanceIsA("GlobalDataStore"), t.table)
local promiseGetTuple = t.tuple(dataStoreInstance, t.string)
local promiseUpdateTuple = t.tuple(dataStoreInstance, t.string, t.callback)
local promiseSetTuple = t.tuple(dataStoreInstance, t.string, t.any, t.optional(t.array(t.integer)), t.optional(t.Instance))
local promiseIncrementTuple = t.tuple(dataStoreInstance, t.string, t.optional(t.integer), t.optional(t.array(t.integer)), t.optional(t.Instance))

function DataStorePromises.promiseGet(dataStore: GlobalDataStore, key: string)
	local typeSuccess, typeError = promiseGetTuple(dataStore, key)
	if not typeSuccess then
		return Promise.Reject(typeError)
	end

	return Promise.Defer(function(resolve, reject)
		local value
		local success, getError = pcall(function()
			value = dataStore:GetAsync(key)
		end)

		if success then
			resolve(value)
		else
			reject(getError)
		end
	end)
end

function DataStorePromises.promiseUpdate(dataStore: GlobalDataStore, key: string, updateFunction: (any) -> any)
	local typeSuccess, typeError = promiseUpdateTuple(dataStore, key, updateFunction)
	if not typeSuccess then
		return Promise.Reject(typeError)
	end

	return Promise.Defer(function(resolve, reject)
		local value
		local success, updateError = pcall(function()
			value = {dataStore:UpdateAsync(key, updateFunction)}
		end)

		if not success then
			reject(updateError)
		else
			if not value then
				reject("Nothing was loaded.")
			else
				resolve(value)
			end
		end
	end)
end

function DataStorePromises.promiseSet(dataStore: GlobalDataStore, key: string, value: any, userIds: {number}?, options: Instance?)
	local typeSuccess, typeError = promiseSetTuple(dataStore, key, value, userIds, options)
	if not typeSuccess then
		return Promise.Reject(typeError)
	end

	return Promise.Defer(function(resolve, reject)
		local returnValues
		local success, setError = pcall(function()
			returnValues = dataStore:SetAsync(key, value, userIds, options)
		end)

		if success then
			resolve(returnValues)
		else
			reject(setError)
		end
	end)
end

function DataStorePromises.promiseIncrement(dataStore: GlobalDataStore, key: string, delta: number?, userIds: {number}?, options: DataStoreSetOptions?)
	local typeSuccess, typeError = promiseIncrementTuple(dataStore, key, delta, userIds, options)
	if not typeSuccess then
		return Promise.Reject(typeError)
	end

	return Promise.Defer(function(resolve, reject)
		local value
		local success, incrementError = pcall(function()
			value = dataStore:IncrementAsync(key, delta, userIds, options)
		end)

		if success then
			resolve(value)
		else
			reject(incrementError)
		end
	end)
end

function DataStorePromises.promiseRemove(dataStore: GlobalDataStore, key: string)
	local typeSuccess, typeError = promiseGetTuple(dataStore, key)
	if not typeSuccess then
		return Promise.Reject(typeError)
	end

	return Promise.Defer(function(resolve, reject)
		local value
		local success, removeError = pcall(function()
			value = dataStore:RemoveAsync(key)
		end)

		if success then
			resolve(value)
		else
			reject(removeError)
		end
	end)
end

return DataStorePromises
