

ds18s20 = require "ds18s20"

function hexstr(str)
	local result = ""
	for i = 1, #str do
		result = result .. string.format("%02X", str:byte(i))
	end
	return result
end

sensors = ds18s20:new {
	owpin = 5,
	owtmr = 5,
	callback = function(temperature, devindex, devaddr)
		print(string.format("Sensor %d (%s): %.2f Celsius",
			devindex, hexstr(devaddr), temperature or "0"))
	end,
}

tmr.alarm(0, 5e3, tmr.ALARM_SINGLE, function()
	print("starting timer")
	tmr.alarm(0, 5e3, tmr.ALARM_AUTO, function()
		print("starting conv")
		sensors:start()
	end)
end)
