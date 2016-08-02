--tmr.alarm(0, 5e3, tmr.ALARM_SINGLE, search_sensors)


tmr.alarm(0, 5e3, tmr.ALARM_SINGLE, function() 

	pin = 5
	ow.setup(pin)
	count = 0
	repeat
		count = count + 1
		addr = ow.reset_search(pin)
		addr = ow.search(pin)
		tmr.wdclr()
	until (addr ~= nil) or (count > 100)

	if addr == nil then
		print("no more addresses.")
	else
		print(addr:byte(1,8))
		crc = ow.crc8(string.sub(addr,1,7))
		if crc == addr:byte(8) then
			if (addr:byte(1) == 0x10) or (addr:byte(1) == 0x28) then
				print("device is a ds18S20 family device.")
				repeat
					ow.reset(pin)

					ow.select(pin, addr)
					ow.write(pin, 0x44, 1)
					
					-- t_CONV = 0.75s
					-- delay of 1.0s ~ 50% failure
					tmr.delay(1.5e6) -- increase to give measurement more time

					present = ow.reset(pin)

					ow.select(pin, addr)
					ow.write(pin, 0xBE, 1)
					
					-- print("P="..present)

					data = nil

					data = string.char(ow.read(pin))
					for i = 1,8 do
						data = data .. string.char(ow.read(pin))
					end

					-- print(data:byte(1,9))

					crc = ow.crc8(string.sub(data, 1, 8))
					-- print("CRC=" .. crc)

					if crc == data:byte(9) then
						-- low byte first
						local raw = (data:byte(1) + data:byte(2) * 256)
						-- print(data:byte(1,2))
						if raw == 0x00AA then
							print("Temperature reads as power-on default value. Give it more time?")
						else
							-- 0x000 ~ 0 degrees celsius
							local t = raw * 0.5
							print("Temperature=" .. string.format("%.1f", t) .. " Centigrade")
						end
					end

					tmr.wdclr()
				until false
			else
				print("Device family is not recognized.")
			end
		else
			print("CRC is not valid!")
		end
	end
end)

