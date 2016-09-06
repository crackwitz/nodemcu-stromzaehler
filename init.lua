------------------------------------------------------------------------
--[[ howto

electricity/energy (R) -- start from here; will be ignored after startup
electricity/energy/set -- to set the value after startup
electricity/avg-period (R) -- for synchronisation with graphite, default 5 minutes
electricity/power -- dE/dt between pulses
electricity/power/10 -- average over 10 pulses
electricity/power/min -- min per interval
electricity/power/max -- max per interval
electricity/power/mean -- average per interval
electricity/pulses-per-kWh (R) -- critical!
electricity/max-kW (R) -- for debouncing, but not really needed

--]]
------------------------------------------------------------------------
-- imports

require 'id'

require 'funcs'

require "wattmeter"
require "telnet"
require "graphite"

------------------------------------------------------------------------
-- hard config values

wattmeter = Wattmeter:new {
	pin = 1,
	window = 10,
	pulses_per_kwh = 1000,
	period_interval = 300,
	-- pulse_cb and period_cb defined below
}

graphite = Graphite:new {
	server = "stats.space.aachen.ccc.de",
}

mqtt_client = nil -- init below, after wifi

------------------------------------------------------------------------
-- interesting code (callbacks)

function mqtt_onmessage(client, topic, message)
	--print("received: " .. topic .. " -> " .. (message or "(nil)"))

	if topic == basetopic .. "/restart" then
		node.restart()

	elseif topic == "electricity/energy" then
		if not wattmeter.is_absolute and message ~= nil then
			wattmeter:set_energy(tonumber(message))
		end

	elseif topic == "electricity/energy/set" then
		if message ~= nil then
			wattmeter:set_energy(tonumber(message))
		end

	elseif topic == "electricity/pulses-per-kWh" then
		if message ~= nil then
			wattmeter.pulses_per_kwh = tonumber(message)
		end

	elseif topic == "electricity/max-kW" then
		if message == nil then
			wattmeter.max_kw = nil
		else
			wattmeter.max_kw = tonumber(message)
		end

	elseif not startswith(topic, basetopic) then
		return

	end
end

function wattmeter.pulse_cb(dt, energy, power, power_windowed)
	if mqtt_client ~= nil then
		if dt ~= nil then
			mqtt_client:publish(
				string.format("electricity/pulse_dt"),
				string.format("%.6f", dt),
				0, 0)
		end
		if energy ~= nil then
			mqtt_client:publish(
				string.format("electricity/energy"),
				string.format("%.3f", energy),
				0, 1) -- retain
		end

		if power ~= nil then
			mqtt_client:publish(
				string.format("electricity/power"),
				string.format("%.3f", power),
				0, 0)
		end
		if power_windowed ~= nil then
			mqtt_client:publish(
				string.format("electricity/power/%skWh", wattmeter:get_increment() * wattmeter.window),
				string.format("%.4f", power_windowed),
				0, 0)
		end
	end
end

function wattmeter.period_cb(period, energy_max, power_min, power_max, power_mean)
	print(string.format("period: min %.3f, max %.3f, mean %.3f [W]", 
		power_min, power_max, power_mean
	))

	if graphite ~= nil then
		if energy_max ~= nil then
			graphite:send("electricity.energy", energy_max, period)
		end
		graphite:send("electricity.power.min", power_min, period)
		graphite:send("electricity.power.max", power_max, period)
		graphite:send("electricity.power", power_mean, period)
	end

	if mqtt_client ~= nil then
		mqtt_client:publish(
			"electricity/power/min",
			string.format("%.3f", power_min),
			0, 0)
		mqtt_client:publish(
			"electricity/power/max",
			string.format("%.3f", power_max),
			0, 0)
		mqtt_client:publish(
			"electricity/power/mean",
			string.format("%.3f", power_mean),
			0, 0)
	end
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

	Telnet.start()

	sntp.sync(
		"ptbtime1.ptb.de",
		function(secs, usecs, server)
			--print("Time Sync", secs, usecs, server)
			wattmeter:time_changed()
			if mqtt_client ~= nil then
				mqtt_client:publish(basetopic .. "/started", string.format("%d.%06d", secs, usecs), 0, 1)
			end
		end
	)
	graphite:connect()
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

wlan_init()
