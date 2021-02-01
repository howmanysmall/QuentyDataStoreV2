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
