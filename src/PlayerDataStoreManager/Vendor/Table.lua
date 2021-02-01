local Table = {}

local function deepCopy(target, context)
	context = context or {}
	if context[target] then
		return context[target]
	end

	if type(target) == "table" then
		local new = {}
		context[target] = new
		for index, value in pairs(target) do
			new[deepCopy(index, context)] = deepCopy(value, context)
		end

		return setmetatable(new, deepCopy(getmetatable(target), context))
	else
		return target
	end
end

Table.deepCopy = deepCopy
return Table
