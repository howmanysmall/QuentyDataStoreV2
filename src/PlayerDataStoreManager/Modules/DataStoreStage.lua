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

local DataStoreDeleteToken = require(script.Parent.DataStoreDeleteToken)
local DataStoreWriter = require(script.Parent.DataStoreWriter)
local Janitor = require(script.Parent.Parent.Vendor.Janitor)
local Promise = require(script.Parent.Parent.Vendor.Promise)
local Signal = require(script.Parent.Parent.Vendor.Signal)
local Table = require(script.Parent.Parent.Vendor.Table)
local t = require(script.Parent.Parent.Vendor.t)

local DataStoreStage = {ClassName = "DataStoreStage"}
DataStoreStage.__index = DataStoreStage

local assertDoStoreTuple = t.strict(t.tuple(t.union(t.string, t.number), t.any))
local assertLoadTuple = t.strict(t.tuple(t.string, t.optional(t.any)))
local assertStoreOnValueChangeTuple = t.strict(t.tuple(t.string, t.instanceIsA("ValueBase")))
local assertString = t.strict(t.string)
local assertOptionalString = t.strict(t.optional(t.string))

function DataStoreStage.new(loadName: string?, loadParent: any?)
	assertOptionalString(loadName)
	return setmetatable(
		{
			-- LoadParent is optional, used for loading
			_loadName = loadName;
			_loadParent = loadParent;

			_janitor = Janitor.new();
			_takenKeys = {}; -- [name] = true
			_stores = {}; -- [name] = dataSubStore
		},
		DataStoreStage
	)
end

function DataStoreStage:GetTopLevelDataStoredSignal()
	if self._topLevelStoreSignal then
		return self._topLevelStoreSignal
	end

	self._topLevelStoreSignal = self._janitor:Add(Signal.new(), "Destroy")
	return self._topLevelStoreSignal
end

function DataStoreStage:GetFullPath(): string
	if self._loadParent then
		return self._loadParent:GetFullPath() .. "." .. tostring(self._loadName)
	else
		return tostring(self._loadName)
	end
end

function DataStoreStage:Load(name: string, defaultValue: any)
	assertLoadTuple(name, defaultValue)
	if not self._loadParent then
		error("[DataStoreStage.Load] - Failed to load, no loadParent!")
	end

	if not self._loadName then
		error("[DataStoreStage.Load] - Failed to load, no loadName!")
	end

	if self._dataToSave and self._dataToSave[name] ~= nil then
		if self._dataToSave[name] == DataStoreDeleteToken then
			return Promise.resolve(defaultValue)
		else
			return Promise.resolve(self._dataToSave[name])
		end
	end

	return self._loadParent:Load(self._loadName, {}):andThen(function(data)
		return self:_afterLoadGetAndApplyStagedData(name, data, defaultValue)
	end)
end

-- Protected!
function DataStoreStage:_afterLoadGetAndApplyStagedData(name, data, defaultValue)
	if self._dataToSave and self._dataToSave[name] ~= nil then
		if self._dataToSave[name] == DataStoreDeleteToken then
			return defaultValue
		else
			return self._dataToSave[name]
		end
	elseif self._stores[name] then
		if self._stores[name]:HasWritableData() then
			local writer = self._stores[name]:GetNewWriter()
			local original = Table.deepCopy(data[name] or {})
			writer:WriteMerge(original)
			return original
		end
	end

	if data[name] == nil then
		return defaultValue
	else
		return data[name]
	end
end

function DataStoreStage:Delete(name: string)
	assertString(name)
	if self._takenKeys[name] then
		error(string.format("[DataStoreStage.Delete] - Already have a writer for %q", name))
	end

	self:_doStore(name, DataStoreDeleteToken)
end

function DataStoreStage:Wipe()
	return self._loadParent:Load(self._loadName, {}):andThen(function(data)
		for key in pairs(data) do
			if self._stores[key] then
				self._stores[key]:Wipe()
			else
				self:_doStore(key, DataStoreDeleteToken)
			end
		end
	end)
end

function DataStoreStage:Store(name: string, value: any)
	assertLoadTuple(name, value)
	if self._takenKeys[name] then
		error(string.format("[DataStoreStage.Store] - Already have a writer for %q", name))
	end

	if value == nil then
		value = DataStoreDeleteToken
	end

	self:_doStore(name, value)
end

function DataStoreStage:GetSubStore(name: string)
	assertString(name)
	if self._stores[name] then
		return self._stores[name]
	end

	if self._takenKeys[name] then
		error(string.format("[DataStoreStage.GetSubStore] - Already have a writer for %q", name))
	end

	local newStore = self._janitor:Add(DataStoreStage.new(name, self), "Destroy")
	self._takenKeys[name] = true
	self._stores[name] = newStore

	return newStore
end

type ValueObject = Instance & (BoolValue | BrickColorValue | CFrameValue | Color3Value | DoubleConstrainedValue | IntConstrainedValue | IntValue | NumberValue | ObjectValue | RayValue | StringValue | Vector3Value)

function DataStoreStage:StoreOnValueChange(name: string, valueObj: ValueObject): RBXScriptConnection
	assertStoreOnValueChangeTuple(name, valueObj)
	if self._takenKeys[name] then
		error(string.format("[DataStoreStage.StoreOnValueChange] - Already have a writer for %q", name))
	end

	self._takenKeys[name] = true
	return self._janitor:Add(
		valueObj.Changed:Connect(function()
			self:_doStore(name, valueObj.Value)
		end),
		"Disconnect"
	)
end

function DataStoreStage:HasWritableData(): boolean
	if self._dataToSave then
		return true
	end

	for _, value in pairs(self._stores) do
		if value:HasWritableData() then
			return true
		end
	end

	return false
end

--- Constructs a writer which provides a snapshot of the current data state to write
function DataStoreStage:GetNewWriter()
	local writer = DataStoreWriter.new()
	if self._dataToSave then
		writer:SetRawData(self._dataToSave)
	end

	for name, store in pairs(self._stores) do
		if store:HasWritableData() then
			writer:AddWriter(name, store:GetNewWriter())
		end
	end

	return writer
end

-- Stores the data for overwrite.
function DataStoreStage:_doStore(name: string | number, value: any)
	assertDoStoreTuple(name, value)

	local newValue
	if value == DataStoreDeleteToken then
		newValue = DataStoreDeleteToken
	elseif type(value) == "table" then
		newValue = Table.deepCopy(value)
	else
		newValue = value
	end

	if not self._dataToSave then
		self._dataToSave = {}
	end

	self._dataToSave[name] = newValue
	if self._topLevelStoreSignal then
		self._topLevelStoreSignal:Fire()
	end
end

function DataStoreStage:Destroy()
	self._janitor:Destroy()
	setmetatable(self, nil)
end

return DataStoreStage
