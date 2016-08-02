-- filter(function, table)
-- e.g: filter(is_even, {1,2,3,4}) -> {2,4}
function filter(tbl, func)
    local newtbl= {}
    for i,v in pairs(tbl) do
        if func(v) then
            newtbl[i]=v
        end
    end
    return newtbl
end


local owpin = 5
local owtmr = 5
local addresses = {}
local next_address = 1

function hexstr(str)
	local result = ""
	for i = 1, #str do
		result = result .. string.format("%02X", str:byte(i))
	end
	return result
end

function search_addresses()
	ow.setup(owpin)
	ow.reset_search(owpin)

	local result = {}

	while true do
		local addr = ow.search(owpin)
		if addr == nil then
			-- nothing more to find
			break
		end

		local crc = ow.crc8(string.sub(addr, 1, 7))

		if crc == addr:byte(8) then
			table.insert(result, addr)
		else
			print("Invalid CRC: " .. hexstr(addr))
		end
	end

	return result
end

function is_DS18S20(addr)
	-- 64 bit string
	-- check family code (8 bit)
	return (addr:byte(1) == 0x10) -- or (addr:byte(1) == 0x28)
	-- next 48 bit are serial number
	-- upper 8 bit is CRC
end

function fetch_temp_reading(addr, callback)
	local present = ow.reset(owpin) -- should not return anything
	-- print("present: " .. present) -- returns 1 if a device is there

	ow.select(owpin, addr)
	ow.write(owpin, 0xBE, 1) -- Read Scratchpad command (returns 9 bytes)
	
	local data = ow.read_bytes(owpin, 9)

	local crc = ow.crc8(string.sub(data, 1, 8))
	-- print("CRC=" .. crc)

	if crc ~= data:byte(9) then
		print("CRC doesn't match!")
		return callback(nil)
	end

	-- low byte first
	local temp_raw = (data:byte(1) + data:byte(2) * 256)
	local temp_read = math.floor(temp_raw / 2) -- truncate
	local count_remain = data:byte(7)
	local count_per_c = data:byte(8)

	-- 1/2 K resolution
	local t2 = temp_raw * 0.5
	-- 1/16 K resolution
	local t16 = temp_read - 0.25 + (count_per_c - count_remain) / count_per_c

	-- print(string.format("temp: %.1f %.2f", t2, t16))

	if temp_raw == 0x00AA then
		print("Temperature reads as power-on default value. Give it more time?")
		return callback(nil)
	else
		return callback(t16)
	end
end


function start_temp_reading(addr, callback)
	-- print("Reading from addr " .. hexstr(addr))
	ow.reset(owpin)
	ow.select(owpin, addr) -- rom select
	ow.write(owpin, 0x44, 1) -- Convert T command

	-- t_CONV = 0.75s
	-- delay of 1.0s ~ 50% failure
	-- increase to give measurement more time
	tmr.alarm(owtmr, 1.5e3, tmr.ALARM_SINGLE, function()
		fetch_temp_reading(addr, callback)
	end)

	-- print("read initialized, waiting...?")
end

-- read_next = nil

function read_next()
	-- print("read next: index " .. next_address)

	local addr = addresses[next_address]

	start_temp_reading(addr, function(tempval)
		if tempval == nil then
			print("Addr " .. hexstr(addr) .. " -> invalid")
		else
			print("Addr " .. hexstr(addr) .. " -> " .. string.format("%.2f", tempval) .. " Celsius")
		end

		tmr.alarm(owtmr, 2e3, tmr.ALARM_SINGLE, read_next)
	end)

	if next_address+1 <= #addresses then
		next_address = next_address + 1
	else
		next_address = 1
	end
end

tmr.alarm(0, 5e3, tmr.ALARM_SINGLE, function()

	addresses = search_addresses()

	print("Found Addresses:")
	for i,addr in pairs(addresses) do
		print("  " .. hexstr(addr))
	end

	addresses = filter(addresses, is_DS18S20)

	print("Is DS18S20:")
	for i,addr in pairs(addresses) do
		print("  " .. hexstr(addr))
	end

	read_next()
end)
