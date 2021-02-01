local Signal = {ClassName = "Signal"}
Signal.__index = Signal

local ENABLE_TRACEBACK = true

--[[**
	Creates a new Signal object.
	@returns [Signal]
**--]]
function Signal.new()
	return setmetatable(
		{
			Arguments = nil;
			BindableEvent = Instance.new("BindableEvent");
			Source = ENABLE_TRACEBACK and debug.traceback() or "";
		},
		Signal
	)
end

--[[**
	Fire the event with the given arguments. All handlers will be invoked. Handlers follow Roblox signal conventions.
	@param [...Arguments] ... The arguments that will be passed to the connected functions.
	@returns [void]
**--]]
function Signal:Fire(...)
	if not self.BindableEvent then
		return warn(string.format("Signal is already destroyed - traceback: %s", self.Source))
	end

	self.Arguments = table.pack(...)
	self.BindableEvent:Fire()
end

--[[**
	Connect a new handler to the event. Returns a connection object that can be disconnected.
	@param [t:callback] Function The function called with arguments passed when `:Fire(...)` is called.
	@returns [t:RBXScriptConnection] A RBXScriptConnection object that can be disconnected.
**--]]
function Signal:Connect(Function): RBXScriptConnection
	return self.BindableEvent.Event:Connect(function()
		local Arguments = self.Arguments
		Function(table.unpack(Arguments, 1, Arguments.n))
	end)
end

--[[**
	Wait for fire to be called, and return the arguments it was given.
	@returns [...Arguments] ... Variable arguments from connection.
**--]]
function Signal:Wait()
	self.BindableEvent.Event:Wait()
	local Arguments = self.Arguments
	if not Arguments then
		error("Missing arg data, likely due to :TweenSize/Position corrupting threadrefs.", 2)
	end

	return table.unpack(Arguments, 1, Arguments.n)
end

--[[**
	Disconnects all connected events to the signal. Voids the signal as unusable.
	@returns [void]
**--]]
function Signal:Destroy()
	self.BindableEvent:Destroy()
	setmetatable(self, nil)
end

return Signal
