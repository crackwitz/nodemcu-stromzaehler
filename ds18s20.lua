-- filter(function, table)
-- e.g: filter(is_even, {1,2,3,4}) -> {2,4}
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

function is_DS18S20(addr)
	-- 64 bit string
	-- check family code (8 bit)
	return (addr:byte(1) == 0x10) -- or (addr:byte(1) == 0x28)
	-- next 48 bit are serial number
	-- upper 8 bit is CRC
end


local ds18s20 = {
	owpin = 1,
	tmr = 6,
	callback = nil,

	convtime = 1.0, -- secs
	devices = {},
	deviceindex = 1 -- wraps around
}
ds18s20.__index = ds18s20

function ds18s20:new(obj)
	obj = obj or {}   -- create object if user does not provide one
	setmetatable(obj, self)
	obj:enumerate_sensors()
	return obj
end

function ds18s20:enumerate_devices()
	ow.setup(self.owpin)
	ow.reset_search(self.owpin)

	local result = {}

	while true do
		local addr = ow.search(self.owpin)
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

function ds18s20:enumerate_sensors()
	local devices = self:enumerate_devices()
	devices = filter(is_DS18S20, devices)
	self.devices = devices
	return devices
end

function ds18s20:start()
	-- print("read next: index " .. deviceindex)

	local deviceindex = self.deviceindex

	if self.deviceindex > #self.devices then
		self.deviceindex = 1
		return
	else
		self.deviceindex = self.deviceindex + 1
	end

	local function conv_done_next(tempval)
		local deviceaddr = self.devices[deviceindex]

		if self.callback ~= nil then
			self.callback(tempval, deviceindex, deviceaddr)
		end

		--	if tempval == nil then
		--		print("Sensor " .. deviceindex .. " (" .. hexstr(deviceaddr) .. ") -> invalid")
		--	else
		--		print("Sensor " .. deviceindex .. " (" .. hexstr(deviceaddr) .. ") -> " .. string.format("%.2f", tempval) .. " Celsius")
		--	end

		self:start()
	end

	self:start_temp_reading(deviceindex, conv_done_next)

end

function ds18s20:start_temp_reading(deviceindex, conv_done_next)
	-- print("Reading from deviceaddr " .. hexstr(deviceaddr))
	ow.reset(self.owpin)
	ow.select(self.owpin, self.devices[deviceindex]) -- rom select
	ow.write(self.owpin, 0x44, 1) -- Convert T command

	-- t_CONV = 0.75s
	-- delay of 1.0s ~ 50% failure
	-- increase to give measurement more time
	tmr.alarm(self.tmr, self.convtime * 1e3, tmr.ALARM_SINGLE, function()
		self:fetch_temp_reading(deviceindex, conv_done_next)
	end)

	-- print("read initialized, waiting...?")
end

function ds18s20:fetch_temp_reading(deviceindex, conv_done_next)
	local deviceaddr = self.devices[deviceindex]

	local present = ow.reset(self.owpin) -- should not return anything
	-- print("present: " .. present) -- returns 1 if a device is there

	ow.select(self.owpin, deviceaddr)
	ow.write(self.owpin, 0xBE, 1) -- Read Scratchpad command (returns 9 bytes)
	
	local data = ow.read_bytes(self.owpin, 9)

	local crc = ow.crc8(string.sub(data, 1, 8))
	-- print("CRC=" .. crc)

	if crc ~= data:byte(9) then
		print("CRC doesn't match!")
		return conv_done_next(nil)
	end

	-- low byte first
	local temp_raw = (data:byte(1) + data:byte(2) * 256)
	if temp_raw >= 0x8000 then -- signed 16 bit integer
		temp_raw = temp_raw - 0x10000
	end
	local temp_read = math.floor(temp_raw / 2) -- round down towards -inf
	local count_remain = data:byte(7)
	local count_per_c = data:byte(8)

	-- 1/2 K resolution
	local t2 = temp_raw * 0.5
	-- 1/16 K resolution
	local t16 = temp_read - 0.25 + (count_per_c - count_remain) / count_per_c

	-- print(string.format("temp: %.1f %.2f", t2, t16))

	--	if temp_raw == 0x00AA then
	--		--print("Temperature reads as power-on default value. Give it more time?")
	--		return conv_done_next(nil)
	--	end
	return conv_done_next(t16)
end

return ds18s20
