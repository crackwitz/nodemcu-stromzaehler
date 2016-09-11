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
	pulses_per_kwh = 1000, -- fixed config for this installation
	period_interval = 300, -- matches the installed graphite
	-- pulse_cb and period_cb defined below
}

graphite = Graphite:new {
	server = "stats.space.aachen.ccc.de",
}

mqtt_client = nil -- init below, after wifi

------------------------------------------------------------------------
-- interesting code (callbacks)

require "defs"

------------------------------------------------------------------------
-- startup

wlan_init()
