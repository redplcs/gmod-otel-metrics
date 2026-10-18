-- Server performance: ticks, frame times, lost simulation time.

local M = OTelMetrics

-- Default frame time buckets in ticks: the first holds a normal frame plus some
-- jitter, the next ones a frame slightly to several times too slow. At 33 tick
-- they are 0.035, 0.05, 0.075, 0.1, 0.15, 0.25 and 0.5 s.
local TICK_BUCKETS = { 1.155, 1.65, 2.475, 3.3, 4.95, 8.25, 16.5 }
-- Freezes are measured in seconds whatever the tick rate.
local SECOND_BUCKETS = { 1, 2.5, 5 }

M.Config:Define("frame_buckets", "",
	"Frame duration histogram bounds in seconds, comma-separated. Empty: multiples of the tick length, then 1, 2.5 and 5 s. A change starts the histogram over.")

local BUCKETS_CALLBACK = "collector.server.frame_buckets"

local function sortedUnique(list)
	table.sort(list)
	local unique = {}
	for i = 1, #list do
		if list[i] ~= unique[#unique] then unique[#unique + 1] = list[i] end
	end
	return unique
end

local function parseBounds(s)
	local out = {}
	for _, item in ipairs(M.Split(s or "", ",")) do
		local v = tonumber(M.Trim(item))
		if v and v > 0 and M.IsFinite(v) then out[#out + 1] = v end
	end
	if #out == 0 then return nil end
	return sortedUnique(out)
end

--- Default bounds for a tick length: TICK_BUCKETS ticks rounded to three
--- significant digits, then SECOND_BUCKETS. The engine keeps the tick length
--- as a 32-bit float (0.015 reads back as 0.0149999996), hence the nudge
--- before rounding.
local function defaultFrameBounds(tickInterval)
	if not M.IsFinite(tickInterval) or tickInterval <= 0 then tickInterval = 1 / 33 end
	local out = {}
	for i = 1, #TICK_BUCKETS do
		out[i] = tonumber(string.format("%.3g", TICK_BUCKETS[i] * tickInterval * (1 + 1e-6)))
	end
	for i = 1, #SECOND_BUCKETS do out[#out + 1] = SECOND_BUCKETS[i] end
	return sortedUnique(out)
end

local function frameBounds(value)
	return parseBounds(value) or defaultFrameBounds(engine.TickInterval())
end

--- Creates the histogram, or gives the existing one new bounds (which starts
--- it over).
local function frameHistogram(meter, bounds)
	return meter:CreateHistogram("gmod.server.frame.duration", {
		unit = "s",
		description = "Real time between server frames (Think).",
		boundaries = bounds,
	})
end

local C = {
	Name = "server",
	Description = "Tick rate, frame times and simulation lag.",
	DefaultEnabled = true,
}

function C:Start(ctx)
	local meter = ctx.Meter
	self.frames = frameHistogram(meter, frameBounds(ctx.Config:GetString("frame_buckets"))):Bind()

	-- The value can change after the collector has started: apply new bounds
	-- whenever it changes. Binding again exports the new histogram right away,
	-- before the next frame.
	M.Config:OnChange("frame_buckets", BUCKETS_CALLBACK, function(value)
		local ok, histogram = pcall(function() return frameHistogram(meter, frameBounds(value)) end)
		if ok then
			self.frames = histogram:Bind()
		else
			M.Collectors.ReportError(C.Name, histogram)
		end
	end)

	self.tickBase = engine.TickCount()
	self.lastThink = 0
	self.idle = false
	self.leaving = setmetatable({}, { __mode = "k" }) -- players whose disconnect is in progress
	self.frameMax = 0
	self.framesSeen = false
	self.lagStartReal = nil
	self.lagStartTick = nil
	self.excluded = 0
	self.lagMax = 0
	self.hibernate = GetConVar("sv_hibernate_think")

	meter:CreateObservableCounter("gmod.server.ticks", function(o)
		o:Observe(engine.TickCount() - self.tickBase)
	end, { unit = "{tick}", description = "Server ticks simulated since the collector started." })

	meter:CreateObservableGauge("gmod.server.tick.interval", function(o)
		o:Observe(engine.TickInterval())
	end, { unit = "s", description = "Configured tick interval (1 / tickrate)." })

	meter:CreateObservableGauge("gmod.server.frame.duration.max", function(o)
		if self.framesSeen then o:Observe(self.frameMax) end
		self.frameMax, self.framesSeen = 0, false
	end, { unit = "s", description = "Longest server frame since the previous export." })

	-- Real time minus simulated time. When a frame takes too long the engine
	-- does not catch up on all of it, so the difference keeps the time the
	-- game stood still. Up to one tick is ordinary jitter and is subtracted.
	meter:CreateObservableCounter("gmod.server.simulation.lag", function(o)
		if not self.lagStartReal then return end
		local interval = engine.TickInterval()
		local real = SysTime() - self.lagStartReal - self.excluded
		local simulated = (engine.TickCount() - self.lagStartTick) * interval
		local lag = real - simulated - interval
		if lag > self.lagMax then self.lagMax = lag end
		o:Observe(self.lagMax)
	end, { unit = "s", description = "Real time the simulation fell behind and never caught up." })

	-- The last Think before the server hibernates may still count the player
	-- who is leaving, and the next one comes only when someone joins. So the
	-- server is marked idle as soon as the last player disconnects.
	ctx:AddHook("PlayerDisconnected", function(ply)
		self.leaving[ply] = true
		self.idle = self:IsIdle()
	end)

	ctx:AddHook("Think", function() self:OnThink() end)
end

function C:Stop()
	M.Config:RemoveOnChange("frame_buckets", BUCKETS_CALLBACK)
end

--- True when the server may hibernate: sv_hibernate_think is 0 and no players
--- are left, not counting those whose disconnect is in progress.
function C:IsIdle()
	local hibernate = self.hibernate
	if hibernate and hibernate:GetBool() then return false end
	local count = player.GetCount()
	for ply in pairs(self.leaving) do
		if IsValid(ply) then
			count = count - 1
		else
			self.leaving[ply] = nil
		end
	end
	return count <= 0
end

function C:OnThink()
	local now = SysTime()
	local last = self.lastThink
	self.lastThink = now

	-- Without sv_hibernate_think an empty server stops thinking. The gap before
	-- the next frame is hibernation, not lag.
	local wasIdle = self.idle
	self.idle = self:IsIdle()

	if last == 0 then
		self.lagStartReal = now
		self.lagStartTick = engine.TickCount()
		return
	end

	local dt = now - last
	if wasIdle and dt > 1 then
		self.excluded = self.excluded + dt
		return
	end

	self.frames:Record(dt)
	if dt > self.frameMax then self.frameMax = dt end
	self.framesSeen = true
end

C.DefaultFrameBounds = defaultFrameBounds

M.Collectors.Register(C)
