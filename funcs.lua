function startswith(str, prefix)
	return string.sub(str, 1, string.len(prefix)) == prefix
end

function filter(func, tbl)
    local newtbl= {}
    for i,v in pairs(tbl) do
        if func(v) then
            newtbl[i]=v
        end
    end
    return newtbl
end

function map(func, tbl)
    local newtbl= {}
    for i,v in pairs(tbl) do
    	newtbl[i]=func(v,i)
    end
    return newtbl
end

function hexstr(str)
	local result = ""
	for i = 1, #str do
		result = result .. string.format("%02X", str:byte(i))
	end
	return result
end

