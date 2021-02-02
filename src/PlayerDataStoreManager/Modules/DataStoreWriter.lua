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
local Table = require(script.Parent.Parent.Vendor.Table)
local t = require(script.Parent.Parent.Vendor.t)

local DataStoreWriter = {ClassName = "DataStoreWriter"}
DataStoreWriter.__index = DataStoreWriter

local assertNonNil = t.strict(t.any)
local assertAddWriterTuple = t.strict(t.tuple(t.string, t.any))

function DataStoreWriter.new()
	return setmetatable({
		_rawSetData = {};
		_writers = {};
	}, DataStoreWriter)
end

function DataStoreWriter:SetRawData(data: any)
	assertNonNil(data)
	self._rawSetData = Table.deepCopy(data)
end

function DataStoreWriter:AddWriter(name: string, value: any)
	assertAddWriterTuple(name, value)
	assert(not self._writers[name], string.format("Writer %s already exists.", name))
	self._writers[name] = value
end

-- Do merge here
function DataStoreWriter:WriteMerge(original)
	original = original or {}

	for key, value in pairs(self._rawSetData) do
		if value == DataStoreDeleteToken then
			original[key] = nil
		else
			original[key] = value
		end
	end

	for key, writer in pairs(self._writers) do
		if self._rawSetData[key] ~= nil then
			warn(string.format(
				"[DataStoreWriter.WriteMerge] - Overwritting key %q already saved as rawData with a writer",
				tostring(key)
			))
		end

		local result = writer:WriteMerge(original[key])
		if result == DataStoreDeleteToken then
			original[key] = nil
		else
			original[key] = result
		end
	end

	return original
end

return DataStoreWriter
