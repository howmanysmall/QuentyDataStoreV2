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

--- Tracks pending promises
-- @classmod PendingPromiseTracker

local Promise = require(script.Parent.Parent.Vendor.Promise)

local PendingPromiseTracker = {ClassName = "PendingPromiseTracker"}
PendingPromiseTracker.__index = PendingPromiseTracker

function PendingPromiseTracker.new()
	return setmetatable({
		_pendingPromises = {};
	}, PendingPromiseTracker)
end

function PendingPromiseTracker:Add(promise)
	if promise:getStatus() == Promise.Status.Started then
		self._pendingPromises[promise] = true
		promise:finally(function()
			self._pendingPromises[promise] = nil
		end)
	end
end

function PendingPromiseTracker:GetAll()
	local promises = {}
	for promise in pairs(self._pendingPromises) do
		table.insert(promises, promise)
	end

	return promises
end

return PendingPromiseTracker
