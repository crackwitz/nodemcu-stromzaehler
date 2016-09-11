require 'funcs'

-- TODO: maintain pulse count, which has no absolute reference, to not have to drop periods on set, etc

Wattmeter = {
	pin = nil, -- for gpio.trig() on falling edge

	lastpulse = nil, -- tmr.now() in microsecs [0..2^31), wraps around every 2^31 microsecs (36 minutes)
	pulsecount = 0, -- always increasing by 1, never reset
	pulsebase = nil, -- energy = count * increment + base
	pulses_per_kwh = 1000 / 1.0, -- 1000 pulses per kWh
	kwh_per_pulse = 1.0 / 1000, -- inverse of above, assuming that multiplication is easier to softfloat lib
	is_absolute = false, -- becomes true if energy was set to something absolute (base not nil)
	last_round = { -- index = pulsecount
		  [10] = 0, -- value is unix timestamp
		 [100] = 0,
		[1000] = 0,
	},

	max_kw = nil, -- kW, to debounce pulse rate, optional

	-- uses rtctime for absolute periods (identified by centered timestamp)
	-- evaluated on first pulse of new period (pulse belongs to new period)
	-- only evaluate if all pulses during period were caught
	period_interval = nil, -- config value

	period_index = nil, -- index, math.floor(timestamp / period_interval)
	-- on evaluation, if this is nil or not exactly 1 less than the new index, something's wrong and we don't report

	period_firstcount = nil, -- set on proper rollover, refers to first pulse of previous period

	period_power_max = nil, -- updated continuously
	period_power_min = nil, -- updated continuously

	-- callbacks per pulse and per period
	pulse_cb = nil, -- dt, energy, power, power_decimated
	period_cb = nil, -- period, emax, pmin, pmax, pmean
}
Wattmeter.__index = Wattmeter

local function nonnil_binop(binop, a, b)
	if a == nil then
		return b
	elseif b == nil then
		return a
	else
		return binop(a, b)
	end
end

local function tmrdiff(t0, t1)
	local delta = (t1 - t0) % 2^31
	return delta * 1e-6
end

function Wattmeter:new(obj)
	obj = obj or {}   -- create object if user does not provide one
	setmetatable(obj, self)

	obj:set_pulses_per_kwh(obj.pulses_per_kwh) -- reinit kwh_per_pulse
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

function Wattmeter:set_pulses_per_kwh(pulserate)
	self.pulses_per_kwh = pulserate
	self.kwh_per_pulse = 1 / pulserate
end

function Wattmeter:get_energy()
	if self.is_absolute then
		return self.pulsecount * self.kwh_per_pulse + self.pulsebase
	else
		return nil
	end
end

function Wattmeter:set_energy(energy)
	self.pulsebase = energy - self.pulsecount * self.kwh_per_pulse
	self.is_absolute = true
end

local function rtc_now()
	local now, unow = rtctime.get()
	return now + unow * 1e-6
end

function Wattmeter:time_changed()
	-- reset period
	self.period_index = nil -- self:get_period_index()

	-- invalidate period, so nothing takes this as a reference
	self.period_firstcount = nil -- this is important, will be set on next rollover

	for k,v in pairs(self.last_round) do
		self.last_round[k] = 0 -- 0 = unset (nil not possible, or else key disappears)
	end
end

function Wattmeter:get_period_index()
	if self.period_interval == nil then -- needs to be configured, or else nothing happens
		return nil
	end

	local now = rtc_now()
	if now == 0 then -- rtctime was not set?
		return nil
	end
	return math.floor(now / self.period_interval)
end

function Wattmeter:period_rollover(newindex)
	-- rollover valid?
	-- valid: period index incremented by 1 exactly
	-- invalid: something was nil or we missed something

	-- valid rollover -> period valid too?
	-- valid: only if at previous valid rollover, period_firstcount was set (or else is nil)

	-- TODO: newindex valid and is_absolute -> can report energy_max of previous index

	local valid_rollover = nil
	if newindex == nil or self.period_index == nil or newindex - self.period_index ~= 1 then
		print(string.format("WARNING: period rollover from %d to %d (delta %+d)",
			self.periodindex or -1,
			newindex or -1,
			(newindex or -1) - (self.periodindex or -1)))
		valid_rollover = false
	else
		valid_rollover = true
	end

	-- period is valid?
	if self.period_firstcount ~= nil then
		local dEi = self.pulsecount - self.period_firstcount
		-- more precisely, (pulsecount-1) - (firstcount-1), but -1 cancels out
		local dE = dEi * self.kwh_per_pulse

		local period_center = nil
		if self.period_index ~= nil and self.period_interval ~= nil then
			period_center = (self.period_index + 0.5) * self.period_interval
		end

		local energy_max = nil
		if self.is_absolute then
			energy_max = self.get_energy() - self.kwh_per_pulse -- subtract one pulse
		end

		if period_center ~= nil then
			self.period_cb(
				period_center, -- time [seconds]
				energy_max, -- highest meter value in period (= previous pulse) [kWh]
				self.period_power_min, -- [kW]
				self.period_power_max, -- [kW]
				dE * 3600 / self.period_interval -- [kW]
			)
		end
	end

	if valid_rollover then
		self.period_firstcount = self.pulsecount
	else
		self.period_firstcount = nil
	end

	self.period_index = newindex
	self.period_power_min = nil
	self.period_power_max = nil
end

function Wattmeter:on_pulse()
	local tmrnow = tmr.now() -- [us]
	local now = rtc_now()

	-- estimate power using dt
	-- use dt to last pulse (if any)
	local dt = nil
	local power = nil
	if self.lastpulse ~= nil then
		dt = tmrdiff(self.lastpulse, tmrnow) -- [seconds]
		power = self.kwh_per_pulse * 3600 / dt -- [kWs / s]

		if self.max_kw ~= nil and power > self.max_kw then
			-- ignore pulse, could be bounced signal
			return
		end
	end

	-- add current pulse to accumulator
	self.pulsecount = self.pulsecount + 1
	self.lastpulse = tmrnow

	-- update round increments
	local round_increments = {}
	for k,v in pairs(self.last_round) do
		if self.pulsecount % k == 0 then
			if v > 0 then
				round_increments[k * self.kwh_per_pulse] = now - v
			end
			self.last_round[k] = now
		end
	end

	-- rollover of period?
	local new_period_index = self:get_period_index()
	if new_period_index ~= self.period_index then
		self:period_rollover(new_period_index)
	end

	-- update stats for period
	self.period_power_min = nonnil_binop(math.min, self.period_power_min, power)
	self.period_power_max = nonnil_binop(math.max, self.period_power_max, power)

	-- invoke per-pulse callback
	if self.pulse_cb ~= nil then
		-- per-pulse callback
		self.pulse_cb(
			dt,
			self:get_energy(), -- report nil if no valid reference
			power,
			round_increments
		)
	end
end

return Wattmeter
