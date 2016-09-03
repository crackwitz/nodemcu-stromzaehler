Wattmeter = {
	pin = nil, -- for gpio.trig() on falling edge

	window = 10,
	is_absolute = false, -- becomes true if energy was set to something absolute
	pulses_per_kwh = 1000, -- 1000 pulses per kWh
	lastpulse = nil, -- tmr.now() in microsecs [0..2^31), wraps around every 2^31 microsecs (36 minutes)
	energy = 0.0, -- kWh
	pulse_history = {}, -- window+1 values of microsecond timestamps

	max_kw = nil, -- kW, to debounce pulse rate, optional

	-- uses rtctime for absolute periods (identified by centered timestamp)
	period_interval = nil,
	period_index = nil, -- index, absolute time % period
	-- period indices are math.floor(timestamp / period_interval)
	-- average power calculated from first pulse of new period (and dt)
	period_power_max = nil, -- updated continuously
	period_power_min = nil, -- updated continuously
	period_energy_max = nil, -- updated continuously, refers to last pulse of previous period
	period_energy_min = nil, -- updated at rollover, refers to first pulse of previous period

	-- callbacks per pulse and per period
	pulse_cb = nil, -- energy, power, power_decimated
	period_cb = nil, -- period, emax, pmin, pmax, pmean
}
Wattmeter.__index = Wattmeter

function Wattmeter:new(obj)
	obj = obj or {}   -- create object if user does not provide one
	setmetatable(obj, self)

	obj:install_gpio_trigger()

	return obj
end

function Wattmeter:install_gpio_trigger(newpin)
	if newpin ~= nil then
		if self.pin ~= nil then
			gpio.trig(self.pin, "none")
		end
		self.pin = newpin
	end

	if self.pin ~= nil then
		gpio.mode(self.pin, gpio.INPUT, gpio.PULLUP)
		gpio.trig(self.pin, "down",
			function(level)
				self:on_pulse()
			end)
	end
end


function Wattmeter:get_increment() -- [kWh]
	return 1 / self.pulses_per_kwh
end

function Wattmeter:set_energy(energy)
	self.energy = energy
	self.is_absolute = true
end

function Wattmeter:get_period_index()
	if self.period_interval == nil then
		return nil
	end

	local now, unow = rtctime.get()
	if now == 0 then -- rtctime was not set?
		return nil
	end
	now = now + unow * 1e-6
	return math.floor(now / self.period_interval)
end

function Wattmeter:time_changed()
	-- reset period
	self.period_index = self:get_period_index()

	-- invalidate period, so nothing takes this as a reference
	self.period_energy_min = nil -- this is important, will be set on next rollover
end

function Wattmeter:period_rollover(newindex)
	-- period is valid?
	if self.period_energy_min ~= nil then

		if newindex ~= nil and self.period_index ~= nil and newindex - self.period_index ~= 1 then
			print(string.format("WARNING: period rollover from %d to %d (delta %+d)", self.periodindex, newindex, newindex - self.periodindex))
		end

		local dE = self.energy - self.period_energy_min
		-- self.energy will become period_energy_min of current period (see below)

		local period_center = nil
		if self.period_index ~= nil and self.period_interval ~= nil then
			period_center = (self.period_index + 0.5) * self.period_interval
		end

		if period_center ~= nil then
			self.period_cb(
				period_center, -- [seconds]
				self.is_absolute and self.period_energy_max or nil, -- [kWh]
				self.period_power_min, -- [kW]
				self.period_power_max, -- [kW]
				dE * 3600 / self.period_interval -- [kW]
			)
		end
	end

	self.period_index = newindex
	self.period_energy_min = self.energy
	self.period_power_min = nil
	self.period_power_max = nil
end

local function nonnil_binop(binop, a, b)
	if a == nil then
		return b
	elseif b == nil then
		return a
	else
		return binop(a, b)
	end
end

function Wattmeter:on_pulse()
	local tmrnow = tmr.now() -- [us]

	local increment = self:get_increment() -- [kWh]

	-- estimate power using dt
	-- use dt to last pulse (if any)
	local dt = nil
	local power = nil
	if self.lastpulse ~= nil then
		dt = (tmrnow - self.lastpulse) % 2^31 -- [us]
		dt = dt * 1e-6 -- [seconds]
		power = increment * 3600 / dt

		if self.max_kw ~= nil and power > self.max_kw then
			-- ignore pulse
			return
		end
	end

	-- add current pulse to accumulator
	self.energy = self.energy + increment
	self.lastpulse = tmrnow

	-- update moving window
	table.insert(self.pulse_history, tmrnow)
	--while #self.pulse_history > self.window+1 do
	--	table.remove(self.pulse_history, 1)
	--end

	-- update stats for period
	self.period_energy_max = self.energy
	self.period_power_min = nonnil_binop(math.min, self.period_power_min, power)
	self.period_power_max = nonnil_binop(math.max, self.period_power_max, power)

	-- rollover of period?
	local new_period_index = self:get_period_index()
	if new_period_index ~= self.period_index then
		self:period_rollover(new_period_index)
	end

	-- invoke per-pulse callback
	if self.pulse_cb ~= nil then
		-- compute power over window
		local power_windowed = nil
		local windowlen = #self.pulse_history
		if windowlen >= self.window+1 then
			local dE = (windowlen - 1) * increment
			local dt = (self.pulse_history[windowlen] - self.pulse_history[1]) * 1e-6
			power_windowed = dE * 3600 / dt
			self.pulse_history = { self.pulse_history[windowlen] }
		end

		-- per-pulse callback
		self.pulse_cb(
			self.is_absolute and self.energy or nil, -- only report if we have a reference
			power,
			power_windowed
		)
	end

end

return Wattmeter
