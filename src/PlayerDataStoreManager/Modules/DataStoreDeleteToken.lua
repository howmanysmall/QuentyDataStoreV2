local DataStoreDeleteToken = newproxy(true)
getmetatable(DataStoreDeleteToken).__tostring = function()
	return "DataStoreDeleteToken"
end

return DataStoreDeleteToken
