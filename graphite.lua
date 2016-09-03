Graphite = {
	server = "graphite",
	port = 2003,
	connection = nil,
	fifo = {},
	fifo_drained = true
}
Graphite.__index = Graphite

function Graphite:new(obj)
	obj = obj or {}
	setmetatable(obj, self)
	return obj
end

function Graphite:connect()
	self.connection = net.createConnection(net.TCP, 0)

	self.connection:on("sent",
		function() self:_sender() end)
	self.connection:on("disconnection",
		function() self:connect() end)

	self.connection:connect(self.port, self.server)
end

function Graphite:_sender()
	if #self.fifo > 0 then
		self.connection:send(table.remove(self.fifo, 1))
	else
		self.fifo_drained = true
	end
end

function Graphite:send_raw(moardata)
	table.insert(self.fifo, moardata)
	if self.fifo_drained then
		self.fifo_drained = false
		self:_sender()
	end
end

function Graphite:send(key, value, timestamp)
	if self.connection == nil then
		self:connect()
	end

	if timestamp == nil and rtctime ~= nil then
		local now, unow = rtctime.get()
		if now ~= 0 or unow ~= 0 then
			timestamp = now + unow * 1e-6
		end
	end
	self:send_raw(string.format("%s %s %s\n", key, value, timestamp))
end


return Graphite
