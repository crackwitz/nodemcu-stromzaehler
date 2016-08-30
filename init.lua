------------------------------------------------------------------------
--[[ howto

./interval (R)
	number of seconds between sensor readings

./devices (R)
	comma-separated list of device IDs
	send empty message to refresh

./devices/<device id>/temperature
	degrees celsius

./devices/<device id>/map (R)
	map of device ID (topic) to name (message) for publishing
	-> /sensors/<name>/temperature


electricity/energy (R) -- will be read once on startup
electricity/energy/set -- to set the value
electricity/power -- average per interval (suitable for graphite)
electricity/power/min -- min per interval
electricity/power/max -- max per interval
electricity/power/raw -- instantaneous data
electricity/pulses-per-kWh (R) -- critical!
electricity/max-kW (R) -- for debouncing, but not really needed
electricity/avg-period (R) -- for synchronisation with graphite, default 5 minutes


--]]
------------------------------------------------------------------------
-- imports

ds18s20 = require "ds18s20"

telnet = require "telnet"

------------------------------------------------------------------------
-- hard config values

nodename = "cracki-nodemcu-stromzaehler" -- mqtt

basetopic = "cracki/nodemcu-stromzaehler" -- mqtt

sensors = ds18s20:new {
	owpin = 5,
	tmr = 6,
	callback = nil, -- set below
}

mapping = {}

intervaltmr = 5 -- timer number

wattmeter = {
	pin = 1, -- GPIO 10 = SD3
	-- ./wattmeter/pulses-per-kWh

	period = 5*60,
	count_2 = nil, -- count at boundary before that
	count_1 = nil, -- count at previous multiple of interval (shifted after half an interval and updated from current value, until post has passed)
	count = 0.0, -- kWh
	-- interval number = floor(now() / period)
	-- intervals shift when round(now() / period) changes

	is_absolute = false, -- becomes true if there's a reference (non-empty message) to go on
	pulses_per_kwh = 1000, -- 1000 pulses per kWh
	max_kw = nil, -- kW, to debounce pulse rate

	lastpulse = nil,
	mean_power = nil,
	--mean_dev = 0.0,
	smoothing = 0.9,
}

--	graphite = {
--		server = "stats.space.aachen.ccc.de",
--		port = 2003,
--		connection = nil,
--		fifo = {},
--		fifo_drained = true
--	}

------------------------------------------------------------------------
-- interesting code

--	function graphite.init()
--		local conn = net.createConnection(net.TCP, 0)
--		conn:connect(graphite.port, graphite.server)
--		graphite.connection = conn
--		graphite.connection:on("sent", graphite.sender)
--	end
--	
--	function graphite.sender()
--		if #graphite.fifo > 0 then
--			graphite.connection:send(table.remove(graphite.fifo, 1))
--		else
--			fifo_drained = true
--		end
--	end
--	
--	function graphite.send(moardata)
--		table.insert(graphite.fifo, moardata)
--		if graphite.fifo_drained then
--			graphite.fifo_drained = false
--			graphite.sender()
--		end
--	end

function sensors.callback(temperature, devindex, devaddr)
	if mqtt_client == nil then
		return
	end

	if temperature == nil then
		return
	end

	local hexaddr = hexstr(devaddr)

	--print(string.format("Sensor %d (%s): %.2f Celsius",
	--	devindex, hexaddr, temperature or 0.0))

	mqtt_client:publish(
		string.format("%s/devices/%s/temperature", basetopic, hexaddr),
		string.format("%.2f", temperature or 0.0),
		0, 0)

	for k,v in pairs(mapping) do
		if k == hexaddr then
			mqtt_client:publish(
				string.format("sensors/%s/temperature", v),
				string.format("%.2f", temperature or 0.0),
				0, 0)
			--	mqtt_client:publish(
			--		string.format("sensors/%s/temperature/_origin", v),
			--		string.format("%s", nodename),
			--		0, 0)
		end
	end
end

function on_interval()
	-- print("starting conv")
	sensors:start()
end

function update_devicelist()
	sensors:enumerate_sensors()
	local devicestr = table.concat(map(hexstr, sensors.devices), ",")

	if devicestr == "" then
		devicestr = "(none)"
	end

	if mqtt_client ~= nil then
		mqtt_client:publish(
			string.format("%s/devices", basetopic),
			devicestr,
			0, 1)
	end
end

function start_sensing(interval)
	tmr.stop(intervaltmr)

	update_devicelist()
	if interval > 0 then
		tmr.alarm(intervaltmr, interval * 1e3, tmr.ALARM_AUTO, on_interval)
	end
end

function set_energy(newcount)
	if (wattmeter.count == nil) or (math.abs(newcount - wattmeter.count) > (2/wattmeter.pulses_per_kwh)) then
		print(string.format("setting wattmeter to %.4f kWh", newcount))
		wattmeter.is_absolute = true
		wattmeter.lastpulse = nil
		wattmeter.count = newcount
	end
end

function mqtt_onmessage(client, topic, message)
	--print("received: " .. topic .. " -> " .. (message or "(nil)"))

	if topic == basetopic .. "/restart" then
		node.restart()

	elseif topic == basetopic .. "/interval" then
		local interval = tonumber(message)
		print("setting interval to " .. interval .. " secs")
		start_sensing(interval)


	elseif topic == "electricity/energy" then
		if not wattmeter.is_absolute and message ~= nil then
			set_energy(tonumber(message))
		end

	elseif topic == "electricity/energy/set" then
		if message ~= nil then
			set_energy(tonumber(message))
		end

	elseif topic == "electricity/pulses-per-kWh" then
		wattmeter.pulses_per_kwh = tonumber(message)

	elseif topic == "electricity/max-kW" then
		if message == nil then
			wattmeter.max_kw = nil
		else
			wattmeter.max_kw = tonumber(message)
		end

	elseif topic == "electricity/smoothing" then
		if message ~= nil then
			local nv = tonumber(message)
			if nv >= 0 and nv < 1 then
				wattmeter.smoothing = nv
			else
				mqtt_client:publish(
					string.format("electricity/smoothing"),
					string.format("%g", wattmeter.smoothing),
					0, 0)
			end
		end

	elseif not startswith(topic, basetopic) then
		return

	elseif topic == basetopic .. "/devices" then
		if message == nil then
			update_devicelist()
		end

	else
		local pattern = string.format("devices/(.*)/map$", basetopic)
		local key = string.match(topic, pattern)
		if key ~= nil then
			mapping[key] = message
			print(string.format("mapping %s -> %s", key, message or "(nil)"))
		end
	end
end

function on_pulse(level)
	local now, unow = rtctime.get()
	now = now + unow * 1e-6

	local increment = 1 / wattmeter.pulses_per_kwh -- [kWh]

	if wattmeter.lastpulse ~= nil then
		local dt = (now - wattmeter.lastpulse) / 3600 -- [h]
		local kilowatts = increment / dt -- [kWh/h = kW]

		if (wattmeter.max_kw ~= nil) and (kilowatts > wattmeter.max_kw) then
			return
		end

		if wattmeter.mean_power == nil then
			if kilowatts > 0.01 then
				wattmeter.mean_power = kilowatts
			end
		else
			local dev = math.abs(kilowatts - wattmeter.mean_power)
			--wattmeter.mean_dev = wattmeter.mean_dev * wattmeter.smoothing + dev * (1-wattmeter.smoothing)
			wattmeter.mean_power = wattmeter.mean_power * wattmeter.smoothing + kilowatts * (1-wattmeter.smoothing)
		end

		--kilowatts = wattmeter.mean_power

		if wattmeter.mean_power ~= nil and mqtt_client ~= nil then
			mqtt_client:publish(
				string.format("electricity/power"),
				string.format("%.3f", wattmeter.mean_power),
				0, 0)
			--	mqtt_client:publish(
			--		string.format("%s/electricity/mdev", basetopic),
			--		string.format("%.3f", wattmeter.mean_dev),
			--		0, 0)
			--	graphite.send(
			--		string.format("electricity.power %.3f %.3f\n", wattmeter.mean_power, now))
		end
	end

	wattmeter.count = wattmeter.count + increment -- [kWh]

	if wattmeter.is_absolute and mqtt_client ~= nil then
		mqtt_client:publish(
			string.format("electricity/energy"),
			string.format("%.4f", wattmeter.count),
			0, 1) -- retain
		--graphite.send(
		--	string.format("electricity.energy %.4f %.3f\n", wattmeter.count, now))
	end

	wattmeter.lastpulse = now
end


function startswith(str, prefix)
	return string.sub(str, 1, string.len(prefix)) == prefix
end

------------------------------------------------------------------------
-- startup

function mqtt_init()
	mqtt_client = mqtt.Client(nodename, 10, nil, nil)
	
	--print("initializing mqtt")
	mqtt_client:lwt(basetopic .. "/status", "offline", 0, 1)
	mqtt_client:on("message", mqtt_onmessage)
	mqtt_client:on("connect", function(client)
		--print("mqtt connected")
		--print("Subscribing")
		--mqtt_client:subscribe(basetopic .. "/#", 0) -- HAS TO COME FIRST, only first subscription receives retained messages
		--mqtt_client:subscribe("runlevel", 0)
		mqtt_client:subscribe {
			["runlevel"] = 0,
			[basetopic .. "/#"] = 0,
			["electricity/#"] = 0,
		}

		mqtt_client:publish(basetopic .. "/status", "online", 0, 1)
		mqtt_client:publish(basetopic .. "/ip", ip, 0, 1)
		if mdns ~= nil then
			mqtt_client:publish(basetopic .. "/mdns", nodename, 0, 1)
		end
	end)
	mqtt_client:close()
	mqtt_client:connect("mqtt.space.aachen.ccc.de", 1883, 0, 1) -- secure 0, autoreconnect 1
end

function wlan_gotip()
	ip, mask, gateway = wifi.sta.getip()
	--print(string.format("IP:      %s", ip))
	--print(string.format("Mask:    %s", mask))
	--print(string.format("Gateway: %s", gateway))

	telnet.start()

	sntp.sync(
		"ptbtime1.ptb.de",
		function(secs, usecs, server)
			--print("Time Sync", secs, usecs, server)
			wattmeter.lastpulse = nil
			wattmeter.mean_power = nil
			if mqtt_client ~= nil then
				mqtt_client:publish(basetopic .. "/started", string.format("%d.%06d", secs, usecs), 0, 1)
			end
		end
	)
	--graphite.init()
	mqtt_init()

	if mdns ~= nil then
		mdns.register(nodename, {
			port=2323,
			service="telnet",
			description="Lua REPL",
			hardware="NodeMCU",
			location="Serverraum"
		})
	end
end

function wlan_init()
	--print("initializing wifi...")
	wifi.setmode(wifi.STATION)
	wifi.sta.config("CCCAC_PSK_2.4GHz", "23cccac42")
	wifi.sta.eventMonReg(wifi.STA_GOTIP, wlan_gotip)
	wifi.sta.eventMonStart()
end

rtctime.set(0, 0)

gpio.mode(wattmeter.pin, gpio.INPUT, gpio.PULLUP)
gpio.trig(wattmeter.pin, "down", on_pulse)

wlan_init()
