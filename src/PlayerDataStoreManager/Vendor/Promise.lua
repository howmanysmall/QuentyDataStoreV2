--[[
	MIT License

	Copyright (c) 2019 Eryn L. K.

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

--[[
	Changes made:
		- Added PascalCase methods.
		- Made it so the previously private :_resolve and :_reject methods are now public (easier porting from Quenty's library).
		- Added Promise::Spread (like Promise::Then, just doesn't return an array and instead unpacks it).
--]]

--[[
	An implementation of Promises similar to Promise/A+.
]]

local RunService = game:GetService("RunService")

local ERROR_NON_PROMISE_IN_LIST = "Non-promise value passed into %s at index %s"
local ERROR_NON_LIST = "Please pass a list of promises to %s"
local ERROR_NON_FUNCTION = "Please pass a handler function to %s!"
local MODE_KEY_METATABLE = {__mode = "k"}

--[[
	Creates an enum dictionary with some metamethods to prevent common mistakes.
]]
local function makeEnum(enumName, members)
	local enum = {}

	for _, memberName in ipairs(members) do
		enum[memberName] = memberName
	end

	return setmetatable(enum, {
		__index = function(_, k)
			error(string.format("%s is not in %s!", k, enumName), 2)
		end,

		__newindex = function()
			error(string.format("Creating new members in %s is not allowed!", enumName), 2)
		end,
	})
end

--[[
	An object to represent runtime errors that occur during execution.
	Promises that experience an error like this will be rejected with
	an instance of this object.
]]
local Error
do
	Error = {
		Kind = makeEnum("Promise.Error.Kind", {
			"ExecutionError",
			"AlreadyCancelled",
			"NotResolvedInTime",
			"TimedOut",
		}),
	}

	Error.__index = Error

	function Error.new(options, parent)
		options = options or {}
		return setmetatable(
			{
				context = options.context,
				createdTick = os.clock(),
				createdTrace = debug.traceback(),
				error = tostring(options.error) or "[This error has no error text.]",
				kind = options.kind,
				parent = parent,
				trace = options.trace,
			},
			Error
		)
	end

	function Error.is(anything)
		if type(anything) == "table" then
			local metatable = getmetatable(anything)

			if type(metatable) == "table" then
				return rawget(anything, "error") ~= nil and type(rawget(metatable, "extend")) == "function"
			end
		end

		return false
	end

	function Error.isKind(anything, kind)
		assert(kind ~= nil, "Argument #2 to Promise.Error.isKind must not be nil")
		return Error.is(anything) and anything.kind == kind
	end

	function Error:extend(options)
		options = options or {}
		options.kind = options.kind or self.kind
		return Error.new(options, self)
	end

	function Error:getErrorChain()
		local runtimeErrors = {self}

		while runtimeErrors[#runtimeErrors].parent do
			table.insert(runtimeErrors, runtimeErrors[#runtimeErrors].parent)
		end

		return runtimeErrors
	end

	function Error:__tostring()
		local errorStrings = {
			string.format("-- Promise.Error(%s) --", self.kind or "?"),
		}

		for _, runtimeError in ipairs(self:getErrorChain()) do
			table.insert(
				errorStrings,
				table.concat(
					{
						runtimeError.trace or runtimeError.error,
						runtimeError.context,
					},
					"\n"
				)
			)
		end

		return table.concat(errorStrings, "\n")
	end
end

--[[
	Returns first value (success), and packs all following values.
]]
local function packResult(success, ...)
	return success, table.pack(...)
end

local function makeErrorHandler(traceback)
	assert(traceback ~= nil, "need traceback")

	return function(err)
		-- If the error object is already a table, forward it directly.
		-- Should we extend the error here and add our own trace?

		if type(err) == "table" then
			return err
		end

		return Error.new({
			context = "Promise created at:\n\n" .. traceback,
			error = err,
			kind = Error.Kind.ExecutionError,
			trace = debug.traceback(tostring(err), 2),
		})
	end
end

--[[
	Calls a Promise executor with error handling.
]]
local function runExecutor(traceback, callback, ...)
	return packResult(xpcall(callback, makeErrorHandler(traceback), ...))
end

--[[
	Creates a function that invokes a callback with correct error handling and
	resolution mechanisms.
]]
local function createAdvancer(traceback, callback, resolve, reject)
	return function(...)
		local ok, result = runExecutor(traceback, callback, ...)

		if ok then
			resolve(table.unpack(result, 1, result.n))
		else
			reject(result[1])
		end
	end
end

type GenericTable = {[any]: any}
local function isEmpty(t: GenericTable)
	return next(t) == nil
end

local Promise = {
	Error = Error,
	Status = makeEnum("Promise.Status", {"Started", "Resolved", "Rejected", "Cancelled"}),
	_getTime = os.clock,
	_timeEvent = RunService.Heartbeat,
}

Promise.prototype = {}
Promise.__index = Promise.prototype

local NOOP = function()
end

local function ConstructorFunction(self, callback, resolve, reject, onCancel)
	local ok, result = runExecutor(self._source, callback, resolve, reject, onCancel)

	if not ok then
		reject(result[1])
	end
end

--[[
	Constructs a new Promise with the given initializing callback.

	This is generally only called when directly wrapping a non-promise API into
	a promise-based version.

	The callback will receive 'resolve' and 'reject' methods, used to start
	invoking the promise chain.

	Second parameter, parent, is used internally for tracking the "parent" in a
	promise chain. External code shouldn't need to worry about this.
]]
function Promise._new(traceback, callback, parent)
	if parent ~= nil and not Promise.is(parent) then
		error("Argument #2 to Promise.new must be a promise or nil", 2)
	end

	local self = {
		-- Used to locate where a promise was created
		_source = traceback,

		_status = Promise.Status.Started,

		-- A table containing a list of all results, whether success or failure.
		-- Only valid if _status is set to something besides Started
		_values = nil,

		-- Lua doesn't like sparse arrays very much, so we explicitly store the
		-- length of _values to handle middle nils.
		_valuesLength = -1,

		-- Tracks if this Promise has no error observers..
		_unhandledRejection = true,

		-- Queues representing functions we should invoke when we update!
		_queuedResolve = {},
		_queuedReject = {},
		_queuedFinally = {},

		-- The function to run when/if this promise is cancelled.
		_cancellationHook = nil,

		-- The "parent" of this promise in a promise chain. Required for
		-- cancellation propagation upstream.
		_parent = parent,

		-- Consumers are Promises that have chained onto this one.
		-- We track them for cancellation propagation downstream.
		_consumers = setmetatable({}, MODE_KEY_METATABLE),
	}

	if parent and parent._status == Promise.Status.Started then
		parent._consumers[self] = true
	end

	setmetatable(self, Promise)

	local function resolve(...)
		self:_resolve(...)
	end

	local function reject(...)
		self:_reject(...)
	end

	local function onCancel(cancellationHook)
		if cancellationHook then
			if self._status == Promise.Status.Cancelled then
				cancellationHook()
			else
				self._cancellationHook = cancellationHook
			end
		end

		return self._status == Promise.Status.Cancelled
	end

	local thread = coroutine.create(ConstructorFunction)
	coroutine.resume(thread, self, callback, resolve, reject, onCancel)
	return self
end

function Promise.new(executor)
	return Promise._new(debug.traceback(nil, 2), executor or NOOP)
end

function Promise:__tostring()
	return string.format("Promise(%s)", self._status)
end

--[[
	Promise.new, except pcall on a new thread is automatic.
]]
function Promise.defer(callback)
	local traceback = debug.traceback(nil, 2)
	local promise
	promise = Promise._new(traceback, function(resolve, reject, onCancel)
		local connection
		connection = Promise._timeEvent:Connect(function()
			connection:Disconnect()
			local ok, result = runExecutor(traceback, callback, resolve, reject, onCancel)

			if not ok then
				reject(result[1])
			end
		end)
	end)

	return promise
end

-- Backwards compatibility
Promise.async = Promise.defer

--[[
	Create a promise that represents the immediately resolved value.
]]
function Promise.resolve(...)
	local values = table.pack(...)
	return Promise._new(debug.traceback(nil, 2), function(resolve)
		resolve(table.unpack(values, 1, values.n))
	end)
end

--[[
	Create a promise that represents the immediately rejected value.
]]
function Promise.reject(...)
	local values = table.pack(...)
	return Promise._new(debug.traceback(nil, 2), function(_, reject)
		reject(table.unpack(values, 1, values.n))
	end)
end

--[[
	Runs a non-promise-returning function as a Promise with the
  given arguments.
]]
function Promise._try(traceback, callback, ...)
	local values = table.pack(...)
	return Promise._new(traceback, function(resolve)
		resolve(callback(table.unpack(values, 1, values.n)))
	end)
end

--[[
	Begins a Promise chain, turning synchronous errors into rejections.
]]
function Promise.try(...)
	return Promise._try(debug.traceback(nil, 2), ...)
end

--[[
	Returns a new promise that:
		* is resolved when all input promises resolve
		* is rejected if ANY input promises reject
]]
function Promise._all(traceback, promises, amount)
	if type(promises) ~= "table" then
		error(string.format(ERROR_NON_LIST, "Promise.all"), 3)
	end

	-- We need to check that each value is a promise here so that we can produce
	-- a proper error rather than a rejected promise with our error.
	for i, promise in ipairs(promises) do
		if not Promise.is(promise) then
			error(string.format(ERROR_NON_PROMISE_IN_LIST, "Promise.all", tostring(i)), 3)
		end
	end

	-- If there are no values then return an already resolved promise.
	if #promises == 0 or amount == 0 then
		return Promise.resolve({})
	end

	return Promise._new(traceback, function(resolve, reject, onCancel)
		-- An array to contain our resolved values from the given promises.
		local resolvedValues = {_fromAll = true}
		local newPromises = table.create(#promises)

		-- Keep a count of resolved promises because just checking the resolved
		-- values length wouldn't account for promises that resolve with nil.
		local resolvedCount = 0
		local rejectedCount = 0
		local done = false

		local function cancel()
			for _, promise in ipairs(newPromises) do
				promise:cancel()
			end
		end

		-- Called when a single value is resolved and resolves if all are done.
		local function resolveOne(i, ...)
			if done then
				return
			end

			resolvedCount += 1
			if amount == nil then
				resolvedValues[i] = ...
			else
				resolvedValues[resolvedCount] = ...
			end

			if resolvedCount >= (amount or #promises) then
				done = true
				resolve(resolvedValues)
				cancel()
			end
		end

		onCancel(cancel)

		-- We can assume the values inside `promises` are all promises since we
		-- checked above.
		for i, promise in ipairs(promises) do
			newPromises[i] = promise:andThen(function(...)
				resolveOne(i, ...)
			end, function(...)
				rejectedCount += 1

				if amount == nil or #promises - rejectedCount < amount then
					cancel()
					done = true

					reject(...)
				end
			end)
		end

		if done then
			cancel()
		end
	end)
end

function Promise.all(promises)
	return Promise._all(debug.traceback(nil, 2), promises)
end

function Promise.fold(list, callback, initialValue)
	assert(type(list) == "table", "Bad argument #1 to Promise.fold: must be a table")
	assert(
		type(callback) == "function",
		"Bad argument #2 to Promise.fold: must be a function"
	)

	local previousValue = initialValue
	for index, element in ipairs(list) do
		if Promise.is(previousValue) then
			previousValue = previousValue:andThen(function(previousValueResolved)
				return callback(previousValueResolved, element, index)
			end)
		else
			previousValue = callback(previousValue, element, index)
		end
	end

	return previousValue
end

function Promise.some(promises, amount)
	assert(type(amount) == "number", "Bad argument #2 to Promise.some: must be a number")
	return Promise._all(debug.traceback(nil, 2), promises, amount)
end

function Promise.any(promises)
	return Promise._all(debug.traceback(nil, 2), promises, 1):andThen(function(values)
		return values[1]
	end)
end

function Promise.allSettled(promises)
	if type(promises) ~= "table" then
		error(string.format(ERROR_NON_LIST, "Promise.allSettled"), 2)
	end

	-- We need to check that each value is a promise here so that we can produce
	-- a proper error rather than a rejected promise with our error.
	for i, promise in ipairs(promises) do
		if not Promise.is(promise) then
			error(string.format(ERROR_NON_PROMISE_IN_LIST, "Promise.allSettled", tostring(i)), 2)
		end
	end

	-- If there are no values then return an already resolved promise.
	if #promises == 0 then
		return Promise.resolve({})
	end

	return Promise._new(debug.traceback(nil, 2), function(resolve, _, onCancel)
		-- An array to contain our resolved values from the given promises.
		local fates = {_fromAll = true}
		local newPromises = table.create(#promises)

		-- Keep a count of resolved promises because just checking the resolved
		-- values length wouldn't account for promises that resolve with nil.
		local finishedCount = 0

		-- Called when a single value is resolved and resolves if all are done.
		local function resolveOne(i, ...)
			finishedCount += 1
			fates[i] = ...
			if finishedCount >= #promises then
				resolve(fates)
			end
		end

		onCancel(function()
			for _, promise in ipairs(newPromises) do
				promise:cancel()
			end
		end)

		-- We can assume the values inside `promises` are all promises since we
		-- checked above.
		for i, promise in ipairs(promises) do
			newPromises[i] = promise:finally(function(...)
				resolveOne(i, ...)
			end)
		end
	end)
end

--[[
	Races a set of Promises and returns the first one that resolves,
	cancelling the others.
]]
function Promise.race(promises)
	assert(type(promises) == "table", string.format(ERROR_NON_LIST, "Promise.race"))

	for i, promise in ipairs(promises) do
		assert(
			Promise.is(promise),
			string.format(ERROR_NON_PROMISE_IN_LIST, "Promise.race", tostring(i))
		)
	end

	return Promise._new(debug.traceback(nil, 2), function(resolve, reject, onCancel)
		local newPromises = table.create(#promises)
		local finished = false

		local function cancel()
			for _, promise in ipairs(newPromises) do
				promise:cancel()
			end
		end

		local function finalize(callback)
			return function(...)
				cancel()
				finished = true
				return callback(...)
			end
		end

		if onCancel(finalize(reject)) then
			return
		end

		for i, promise in ipairs(promises) do
			newPromises[i] = promise:andThen(finalize(resolve), finalize(reject))
		end

		if finished then
			cancel()
		end
	end)
end

--[[
	Iterates serially over the given an array of values, calling the predicate callback on each before continuing.
	If the predicate returns a Promise, we wait for that Promise to resolve before continuing to the next item
	in the array. If the Promise the predicate returns rejects, the Promise from Promise.each is also rejected with
	the same value.

	Returns a Promise containing an array of the return values from the predicate for each item in the original list.
]]
function Promise.each(list, predicate)
	assert(type(list) == "table", string.format(ERROR_NON_LIST, "Promise.each"))
	assert(type(predicate) == "function", string.format(ERROR_NON_FUNCTION, "Promise.each"))

	return Promise._new(debug.traceback(nil, 2), function(resolve, reject, onCancel)
		local results = {}
		local promisesToCancel = {}

		local cancelled = false

		local function cancel()
			for _, promiseToCancel in ipairs(promisesToCancel) do
				promiseToCancel:cancel()
			end
		end

		onCancel(function()
			cancelled = true
			cancel()
		end)

		-- We need to preprocess the list of values and look for Promises.
		-- If we find some, we must register our andThen calls now, so that those Promises have a consumer
		-- from us registered. If we don't do this, those Promises might get cancelled by something else
		-- before we get to them in the series because it's not possible to tell that we plan to use it
		-- unless we indicate it here.

		local preprocessedList = {}

		for index, value in ipairs(list) do
			if Promise.is(value) then
				if value._status == Promise.Status.Cancelled then
					cancel()
					return reject(Error.new({
						context = string.format(
							"The Promise that was part of the array at index %d passed into Promise.each was already cancelled when Promise.each began.\n\nThat Promise was created at:\n\n%s",
							index,
							value._source
						),

						error = "Promise is cancelled",
						kind = Error.Kind.AlreadyCancelled,
					}))
				elseif value._status == Promise.Status.Rejected then
					cancel()
					return reject(select(2, value:await()))
				end

				-- Chain a new Promise from this one so we only cancel ours
				local ourPromise = value:andThen(function(...)
					return ...
				end)

				table.insert(promisesToCancel, ourPromise)
				preprocessedList[index] = ourPromise
			else
				preprocessedList[index] = value
			end
		end

		for index, value in ipairs(preprocessedList) do
			if Promise.is(value) then
				local success
				success, value = value:await()

				if not success then
					cancel()
					return reject(value)
				end
			end

			if cancelled then
				return
			end

			local predicatePromise = Promise.resolve(predicate(value, index))
			table.insert(promisesToCancel, predicatePromise)
			local success, result = predicatePromise:await()

			if not success then
				cancel()
				return reject(result)
			end

			results[index] = result
		end

		resolve(results)
	end)
end

--[[
	Is the given object a Promise instance?
]]
function Promise.is(object)
	if type(object) ~= "table" then
		return false
	end

	local objectMetatable = getmetatable(object)

	if objectMetatable == Promise then
		-- The Promise came from this library.
		return true
	elseif objectMetatable == nil then
		-- No metatable, but we should still chain onto tables with andThen methods
		return type(object.andThen) == "function"
	elseif
		type(objectMetatable) == "table"
		and type(rawget(objectMetatable, "__index")) == "table"
		and type(rawget(rawget(objectMetatable, "__index"), "andThen")) == "function"
	then
		-- Maybe this came from a different or older Promise library.
		return true
	end

	return false
end

--[[
	Converts a yielding function into a Promise-returning one.
]]
function Promise.promisify(callback)
	return function(...)
		return Promise._try(debug.traceback(nil, 2), callback, ...)
	end
end

--[[
	Creates a Promise that resolves after given number of seconds.
]]
do
	-- uses a sorted doubly linked list (queue) to achieve O(1) remove operations and O(n) for insert

	-- the initial node in the linked list
	local first
	local connection

	function Promise.delay(seconds)
		assert(type(seconds) == "number", "Bad argument #1 to Promise.delay, must be a number.")
		-- If seconds is -INF, INF, NaN, or less than 1 / 60, assume seconds is 1 / 60.
		-- This mirrors the behavior of wait()
		if not (seconds >= 1 / 60) or seconds == math.huge then
			seconds = 1 / 60
		end

		return Promise._new(debug.traceback(nil, 2), function(resolve, _, onCancel)
			local startTime = Promise._getTime()
			local endTime = startTime + seconds

			local node = {
				endTime = endTime,
				resolve = resolve,
				startTime = startTime,
			}

			if connection == nil then -- first is nil when connection is nil
				first = node
				connection = Promise._timeEvent:Connect(function()
					local threadStart = Promise._getTime()

					while first ~= nil and first.endTime < threadStart do
						local current = first
						first = current.next

						if first == nil then
							connection:Disconnect()
							connection = nil
						else
							first.previous = nil
						end

						current.resolve(Promise._getTime() - current.startTime)
					end
				end)
			else -- first is non-nil
				if first.endTime < endTime then -- if `node` should be placed after `first`
					-- we will insert `node` between `current` and `next`
					-- (i.e. after `current` if `next` is nil)
					local current = first
					local next2 = current.next

					while next2 ~= nil and next2.endTime < endTime do
						current = next2
						next2 = current.next
					end

					-- `current` must be non-nil, but `next` could be `nil` (i.e. last item in list)
					current.next = node
					node.previous = current

					if next2 ~= nil then
						node.next = next2
						next2.previous = node
					end
				else
					-- set `node` to `first`
					node.next = first
					first.previous = node
					first = node
				end
			end

			onCancel(function()
				-- remove node from queue
				local next2 = node.next

				if first == node then
					if next2 == nil then -- if `node` is the first and last
						connection:Disconnect()
						connection = nil
					else -- if `node` is `first` and not the last
						next2.previous = nil
					end

					first = next2
				else
					local previous = node.previous
					-- since `node` is not `first`, then we know `previous` is non-nil
					previous.next = next2

					if next2 ~= nil then
						next2.previous = previous
					end
				end
			end)
		end)
	end
end

--[[
	Rejects the promise after `seconds` seconds.
]]
function Promise.prototype:timeout(seconds, rejectionValue)
	local traceback = debug.traceback(nil, 2)

	local array = table.create(2)
	array[1], array[2] = Promise.delay(seconds):andThen(function()
		return Promise.reject(rejectionValue == nil and Error.new({
			context = string.format(
				"Timeout of %d seconds exceeded.\n:timeout() called at:\n\n%s",
				seconds,
				traceback
			),

			error = "Timed out",
			kind = Error.Kind.TimedOut,
		}) or rejectionValue)
	end), self

	return Promise.race(array)
end

function Promise.prototype:getStatus()
	return self._status
end

--[[
	Creates a new promise that receives the result of this promise.

	The given callbacks are invoked depending on that result.
]]
function Promise.prototype:_andThen(traceback, successHandler, failureHandler, useSpread)
	self._unhandledRejection = false

	if useSpread then
		if successHandler then
			local oldSuccessHandler = successHandler
			function successHandler(data)
				if type(data) == "table" then
					if data._fromAll then
						return oldSuccessHandler(table.unpack(data))
					else
						return oldSuccessHandler(data)
					end
				else
					return oldSuccessHandler(data)
				end
			end
		end

		if failureHandler then
			local oldFailureHandler = failureHandler
			function failureHandler(data)
				if type(data) == "table" then
					if data._fromAll then
						return oldFailureHandler(table.unpack(data))
					else
						return oldFailureHandler(data)
					end
				else
					return oldFailureHandler(data)
				end
			end
		end
	end

	-- Create a new promise to follow this part of the chain
	return Promise._new(
		traceback,
		function(resolve, reject)
			-- Our default callbacks just pass values onto the next promise.
			-- This lets success and failure cascade correctly!

			local successCallback = resolve
			if successHandler then
				successCallback = createAdvancer(traceback, successHandler, resolve, reject)
			end

			local failureCallback = reject
			if failureHandler then
				failureCallback = createAdvancer(traceback, failureHandler, resolve, reject)
			end

			local status = self._status
			if status == Promise.Status.Started then
				-- If we haven't resolved yet, put ourselves into the queue
				table.insert(self._queuedResolve, successCallback)
				table.insert(self._queuedReject, failureCallback)
			elseif status == Promise.Status.Resolved then
				-- This promise has already resolved! Trigger success immediately.
				local values = self._values
				successCallback(table.unpack(values, 1, values.n))
			elseif status == Promise.Status.Rejected then
				-- This promise died a terrible death! Trigger failure immediately.
				local values = self._values
				failureCallback(table.unpack(values, 1, values.n))
			elseif status == Promise.Status.Cancelled then
				-- We don't want to call the success handler or the failure handler,
				-- we just reject this promise outright.
				reject(Error.new({
					context = "Promise created at\n\n" .. traceback,
					error = "Promise is cancelled",
					kind = Error.Kind.AlreadyCancelled,
				}))
			end
		end,
		self
	)
end

function Promise.prototype:spread(successHandler)
	assert(
		successHandler == nil or type(successHandler) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:spread")
	)

	return self:_andThen(debug.traceback(nil, 2), successHandler, nil, true)
end

function Promise.prototype:andThen(successHandler, failureHandler)
	assert(
		successHandler == nil or type(successHandler) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:andThen")
	)

	assert(
		failureHandler == nil or type(failureHandler) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:andThen")
	)

	return self:_andThen(debug.traceback(nil, 2), successHandler, failureHandler, false)
end

--[[
	Used to catch any errors that may have occurred in the promise.
]]
function Promise.prototype:catch(failureCallback)
	assert(
		failureCallback == nil or type(failureCallback) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:catch")
	)

	return self:_andThen(debug.traceback(nil, 2), nil, failureCallback, false)
end

local function createTapper(callback)
	return function(...)
		local callbackReturn = callback(...)

		if Promise.is(callbackReturn) then
			local values = table.pack(...)
			return callbackReturn:andThen(function()
				return table.unpack(values, 1, values.n)
			end)
		end

		return ...
	end
end

--[[
	Like andThen, but the value passed into the handler is also the
	value returned from the handler.
]]
function Promise.prototype:tap(tapCallback, tapCatch)
	assert(
		type(tapCallback) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:tap")
	)

	assert(
		tapCatch == nil or type(tapCatch) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:tap")
	)

	tapCallback = createTapper(tapCallback)
	if tapCatch then
		tapCatch = createTapper(tapCatch)
		return self:_andThen(debug.traceback(nil, 2), tapCallback, tapCatch, false)
	else
		return self:_andThen(debug.traceback(nil, 2), tapCallback, nil, false)
	end
end

--[[
	Calls a callback on `andThen` with specific arguments.
]]
function Promise.prototype:andThenCall(callback, ...)
	assert(
		type(callback) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:andThenCall")
	)

	local values = table.pack(...)
	return self:_andThen(
		debug.traceback(nil, 2),
		function()
			return callback(table.unpack(values, 1, values.n))
		end,
		nil,
		false
	)
end

--[[
	Shorthand for an andThen handler that returns the given value.
]]
function Promise.prototype:andThenReturn(...)
	local values = table.pack(...)
	return self:_andThen(
		debug.traceback(nil, 2),
		function()
			return table.unpack(values, 1, values.n)
		end,
		nil,
		false
	)
end

-- function Promise.prototype:spread(values)
-- end

--[[
	Cancels the promise, disallowing it from rejecting or resolving, and calls
	the cancellation hook if provided.
]]
function Promise.prototype:cancel()
	if self._status ~= Promise.Status.Started then
		return
	end

	self._status = Promise.Status.Cancelled
	if self._cancellationHook then
		self._cancellationHook()
	end

	if self._parent then
		self._parent:_consumerCancelled(self)
	end

	for child in next, self._consumers do
		child:cancel()
	end

	self:_finalize()
end

--[[
	Used to decrease the number of consumers by 1, and if there are no more,
	cancel this promise.
]]
function Promise.prototype:_consumerCancelled(consumer)
	if self._status ~= Promise.Status.Started then
		return
	end

	self._consumers[consumer] = nil
	if next(self._consumers) == nil then
		self:cancel()
	end
end

--[[
	Used to set a handler for when the promise resolves, rejects, or is
	cancelled. Returns a new promise chained from this promise.
]]
function Promise.prototype:_finally(traceback, finallyHandler, onlyOk)
	if not onlyOk then
		self._unhandledRejection = false
	end

	-- Return a promise chained off of this promise
	return Promise._new(
		traceback,
		function(resolve, reject)
			local finallyCallback = resolve
			if finallyHandler then
				finallyCallback = createAdvancer(traceback, finallyHandler, resolve, reject)
			end

			if onlyOk then
				local callback = finallyCallback
				finallyCallback = function(...)
					if self._status == Promise.Status.Rejected then
						return resolve(self)
					end

					return callback(...)
				end
			end

			if self._status == Promise.Status.Started then
				-- The promise is not settled, so queue this.
				table.insert(self._queuedFinally, finallyCallback)
			else
				-- The promise already settled or was cancelled, run the callback now.
				finallyCallback(self._status)
			end
		end,
		self
	)
end

function Promise.prototype:finally(finallyHandler)
	assert(
		finallyHandler == nil or type(finallyHandler) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:finally")
	)

	return self:_finally(debug.traceback(nil, 2), finallyHandler)
end

--[[
	Calls a callback on `finally` with specific arguments.
]]
function Promise.prototype:finallyCall(callback, ...)
	assert(
		type(callback) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:finallyCall")
	)

	local values = table.pack(...)
	return self:_finally(debug.traceback(nil, 2), function()
		return callback(table.unpack(values, 1, values.n))
	end)
end

--[[
	Shorthand for a finally handler that returns the given value.
]]
function Promise.prototype:finallyReturn(...)
	local values = table.pack(...)
	return self:_finally(debug.traceback(nil, 2), function()
		return table.unpack(values, 1, values.n)
	end)
end

--[[
	Similar to finally, except rejections are propagated through it.
]]
function Promise.prototype:done(finallyHandler)
	assert(
		finallyHandler == nil or type(finallyHandler) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:done")
	)

	return self:_finally(debug.traceback(nil, 2), finallyHandler, true)
end

--[[
	Calls a callback on `done` with specific arguments.
]]
function Promise.prototype:doneCall(callback, ...)
	assert(
		type(callback) == "function",
		string.format(ERROR_NON_FUNCTION, "Promise:doneCall")
	)

	local values = table.pack(...)
	return self:_finally(
		debug.traceback(nil, 2),
		function()
			return callback(table.unpack(values, 1, values.n))
		end,
		true
	)
end

--[[
	Shorthand for a done handler that returns the given value.
]]
function Promise.prototype:doneReturn(...)
	local values = table.pack(...)
	return self:_finally(
		debug.traceback(nil, 2),
		function()
			return table.unpack(values, 1, values.n)
		end,
		true
	)
end

--[[
	Yield until the promise is completed.

	This matches the execution model of normal Roblox functions.
]]
function Promise.prototype:awaitStatus()
	self._unhandledRejection = false

	if self._status == Promise.Status.Started then
		local bindable = Instance.new("BindableEvent")

		self:finally(function()
			bindable:Fire()
		end)

		bindable.Event:Wait()
		bindable:Destroy()
	end

	local status = self._status
	if status == Promise.Status.Resolved or status == Promise.Status.Rejected then
		local values = self._values
		return status, table.unpack(values, 1, values.n)
	end

	-- if status == Promise.Status.Resolved then
	-- 	return status, table.unpack(self._values, 1, self._valuesLength)
	-- elseif status == Promise.Status.Rejected then
	-- 	return status, table.unpack(self._values, 1, self._valuesLength)
	-- end

	return status
end

local function awaitHelper(status, ...)
	return status == Promise.Status.Resolved, ...
end

--[[
	Calls awaitStatus internally, returns (isResolved, values...)
]]
function Promise.prototype:await()
	return awaitHelper(self:awaitStatus())
end

local function expectHelper(status, ...)
	if status ~= Promise.Status.Resolved then
		error((...) == nil and "Expected Promise rejected with no value." or (...), 3)
	end

	return ...
end

--[[
	Calls await and only returns if the Promise resolves.
	Throws if the Promise rejects or gets cancelled.
]]
function Promise.prototype:expect()
	return expectHelper(self:awaitStatus())
end

-- Backwards compatibility
Promise.prototype.awaitValue = Promise.prototype.expect

--[[
	Intended for use in tests.

	Similar to await(), but instead of yielding if the promise is unresolved,
	_unwrap will throw. This indicates an assumption that a promise has
	resolved.
]]
function Promise.prototype:_unwrap()
	if self._status == Promise.Status.Started then
		error("Promise has not resolved or rejected.", 2)
	end

	local success = self._status == Promise.Status.Resolved
	local values = self._values
	return success, table.unpack(values, 1, values.n)
end

function Promise.prototype:_resolve(...)
	if self._status ~= Promise.Status.Started then
		if Promise.is((...)) then
			(...):_consumerCancelled(self)
		end

		return
	end

	-- If the resolved value was a Promise, we chain onto it!
	if Promise.is((...)) then
		-- Without this warning, arguments sometimes mysteriously disappear
		if select("#", ...) > 1 then
			warn(string.format(
				"When returning a Promise from andThen, extra arguments are " .. "discarded! See:\n\n%s",
				self._source
			))
		end

		local chainedPromise = ...

		local promise = chainedPromise:andThen(function(...)
			self:_resolve(...)
		end, function(...)
			local maybeRuntimeError = chainedPromise._values[1]

			-- Backwards compatibility < v2
			if chainedPromise._error then
				maybeRuntimeError = Error.new({
					context = "[No stack trace available as this Promise originated from an older version of the Promise library (< v2)]",
					error = chainedPromise._error,
					kind = Error.Kind.ExecutionError,
				})
			end

			if Error.isKind(maybeRuntimeError, Error.Kind.ExecutionError) then
				return self:_reject(maybeRuntimeError:extend({
					context = string.format(
						"The Promise at:\n\n%s\n...Rejected because it was chained to the following Promise, which encountered an error:\n",
						self._source
					),

					error = "This Promise was chained to a Promise that errored.",
					trace = "",
				}))
			end

			self:_reject(...)
		end)

		if promise._status == Promise.Status.Cancelled then
			self:cancel()
		elseif promise._status == Promise.Status.Started then
			-- Adopt ourselves into promise for cancellation propagation.
			self._parent = promise
			promise._consumers[self] = true
		end

		return
	end

	self._status = Promise.Status.Resolved
	self._values = table.pack(...)

	-- We assume that these callbacks will not throw errors.
	for _, callback in ipairs(self._queuedResolve) do
		local thread = coroutine.create(callback)
		coroutine.resume(thread, ...)
	end

	self:_finalize()
end

local function RejectFunction(self, err)
	Promise._timeEvent:Wait()

	-- Someone observed the error, hooray!
	if not self._unhandledRejection then
		return
	end

	-- Build a reasonable message
	warn(string.format("Unhandled Promise rejection:\n\n%s\n\n%s", err, self._source))
end

function Promise.prototype:_reject(...)
	if self._status ~= Promise.Status.Started then
		return
	end

	self._status = Promise.Status.Rejected
	self._values = table.pack(...)

	-- If there are any rejection handlers, call those!
	if not isEmpty(self._queuedReject) then
		-- We assume that these callbacks will not throw errors.
		for _, callback in ipairs(self._queuedReject) do
			local thread = coroutine.create(callback)
			coroutine.resume(thread, ...)
		end
	else
		-- At this point, no one was able to observe the error.
		-- An error handler might still be attached if the error occurred
		-- synchronously. We'll wait one tick, and if there are still no
		-- observers, then we should put a message in the console.

		local err = tostring((...))
		local thread = coroutine.create(RejectFunction)
		coroutine.resume(thread, self, err)
	end

	self:_finalize()
end

--[[
	Calls any :finally handlers. We need this to be a separate method and
	queue because we must call all of the finally callbacks upon a success,
	failure, *and* cancellation.
]]
function Promise.prototype:_finalize()
	local status = self._status

	for _, callback in ipairs(self._queuedFinally) do
		-- Purposefully not passing values to callbacks here, as it could be the
		-- resolved values, or rejected errors. If the developer needs the values,
		-- they should use :andThen or :catch explicitly.
		local thread = coroutine.create(callback)
		coroutine.resume(thread, status)
	end

	self._queuedFinally = nil
	self._queuedReject = nil
	self._queuedResolve = nil

	-- Clear references to other Promises to allow gc
	self._parent = nil
	self._consumers = nil
end

--[[
	Chains a Promise from this one that is resolved if this Promise is
	resolved, and rejected if it is not resolved.
]]
function Promise.prototype:now(rejectionValue)
	local traceback = debug.traceback(nil, 2)
	if self._status == Promise.Status.Resolved then
		return self:_andThen(traceback, function(...)
			return ...
		end, nil, false)
	else
		return Promise.reject(rejectionValue == nil and Error.new({
			context = ":now() was called at:\n\n" .. traceback,
			error = "This Promise was not resolved in time for :now()",
			kind = Error.Kind.NotResolvedInTime,
		}) or rejectionValue)
	end
end

--[[
	Retries a Promise-returning callback N times until it succeeds.
]]
function Promise.retry(callback, times, ...)
	assert(type(callback) == "function", "Parameter #1 to Promise.retry must be a function")
	assert(type(times) == "number", "Parameter #2 to Promise.retry must be a number")

	local args = table.pack(...)

	return Promise.resolve(callback(...)):catch(function(...)
		if times > 0 then
			return Promise.retry(callback, times - 1, table.unpack(args, 1, args.n))
		else
			return Promise.reject(...)
		end
	end)
end

--[[
	Converts an event into a Promise with an optional predicate
]]
function Promise.fromEvent(event, predicate)
	predicate = predicate or function()
		return true
	end

	return Promise._new(debug.traceback(nil, 2), function(resolve, _, onCancel)
		local connection
		local shouldDisconnect = false

		local function disconnect()
			connection = connection:Disconnect()
		end

		-- We use shouldDisconnect because if the callback given to Connect is called before
		-- Connect returns, connection will still be nil. This happens with events that queue up
		-- events when there's nothing connected, such as RemoteEvents

		connection = event:Connect(function(...)
			local callbackValue = predicate(...)

			if callbackValue == true then
				resolve(...)

				if connection then
					disconnect()
				else
					shouldDisconnect = true
				end
			elseif type(callbackValue) ~= "boolean" then
				error("Promise.fromEvent predicate should always return a boolean")
			end
		end)

		if shouldDisconnect and connection then
			return disconnect()
		end

		onCancel(disconnect)
	end)
end

Promise.prototype.wait = Promise.prototype.await
Promise.prototype.waitStatus = Promise.prototype.awaitStatus
Promise.prototype.waitValue = Promise.prototype.awaitValue

Promise.prototype.resolve = Promise.prototype._resolve
Promise.prototype.reject = Promise.prototype._reject

for FunctionName, Function in next, Promise do
	if type(Function) == "function" and string.sub(FunctionName, 1, 1) ~= "_" and FunctionName ~= "new" then
		Promise[string.gsub(FunctionName, "^%a", string.upper)] = Function
	end
end

for FunctionName, Function in next, Promise.prototype do
	if type(Function) == "function" and string.sub(FunctionName, 1, 1) ~= "_" then
		Promise.prototype[string.gsub(FunctionName, "^%a", string.upper)] = Function
		if string.sub(FunctionName, 1, 3) == "and" then
			Promise.prototype[string.gsub(FunctionName, "^and", "")] = Function
		end
	end
end

return Promise