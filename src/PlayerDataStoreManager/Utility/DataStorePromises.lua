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
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
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
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
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
				resolve(table.unpack(value))
			end
		end
	end)
end

function DataStorePromises.promiseSet(dataStore: GlobalDataStore, key: string, value: any, userIds: {number}?, options: Instance?)
	local typeSuccess, typeError = promiseSetTuple(dataStore, key, value, userIds, options)
	if not typeSuccess then
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
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
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
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
		return Promise.reject(typeError)
	end

	return Promise.defer(function(resolve, reject)
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
