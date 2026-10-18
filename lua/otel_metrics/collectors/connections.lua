-- Connections: join time, disconnect reasons, session length, player time.

local M = OTelMetrics

local PENDING_TTL = 3600

--- Free-text disconnect reason -> a small fixed set of categories.
local function classify(reason)
	local r = string.lower(tostring(reason or ""))
	if string.find(r, "timed out", 1, true) or string.find(r, "timing out", 1, true) then return "timeout" end
	if string.find(r, "%f[%a]ban") then return "banned" end
	if string.find(r, "%f[%a]kick") then return "kicked" end
	if string.find(r, "disconnect by user", 1, true) or string.find(r, "disconnected by user", 1, true) then
		return "client"
	end
	if string.find(r, "shutting down", 1, true) or string.find(r, "shutdown", 1, true) then return "shutdown" end
	return "other"
end

local C = {
	Name = "connections",
	Description = "Join time, disconnect reasons, session length, player time.",
	DefaultEnabled = true,
}

function C:Start(ctx)
	local meter = ctx.Meter
	self.pending = {}               -- userid -> SysTime() of player_connect
	self.lastCollect = SysTime()

	self.connections = meter:CreateCounter("gmod.player.connections", {
		unit = "{connection}",
		description = "Connections that reached the server (bots excluded).",
	}):Bind()

	self.joins = meter:CreateHistogram("gmod.player.join.duration", {
		unit = "s",
		description = "Time from connecting to fully signed on, content download included.",
		boundaries = { 5, 10, 20, 30, 60, 120, 300, 600 },
	}):Bind()

	self.disconnects = meter:CreateCounter("gmod.player.disconnects", {
		unit = "{disconnect}",
		description = "Disconnects by reason; aborted means the player left before signing on.",
	})

	self.sessions = meter:CreateHistogram("gmod.player.session.duration", {
		unit = "s",
		description = "Session length at disconnect.",
		boundaries = { 60, 300, 900, 1800, 3600, 7200, 14400, 28800 },
	}):Bind()

	self.playerTime = meter:CreateCounter("gmod.player.time", {
		unit = "s",
		description = "Accumulated presence of human players (player-seconds).",
	}):Bind()

	local FULL = SIGNONSTATE_FULL or 6

	ctx:ListenGameEvent("player_connect", function(data)
		if tonumber(data.bot) == 1 then return end
		self.connections:Add(1)
		local id = tonumber(data.userid)
		if id then self.pending[id] = SysTime() end
	end)

	-- The player object is not available in this hook, so the join is matched
	-- by userid from player_connect.
	ctx:AddHook("ClientSignOnStateChanged", function(userID, _, newState)
		if newState ~= FULL then return end
		local started = self.pending[userID]
		if started then
			self.pending[userID] = nil
			self.joins:Record(SysTime() - started)
		end
	end)

	ctx:ListenGameEvent("player_disconnect", function(data)
		if tonumber(data.bot) == 1 then return end
		local id = tonumber(data.userid)
		local reason
		if id and self.pending[id] then
			self.pending[id] = nil
			reason = "aborted"
		else
			reason = classify(data.reason)
		end
		self.disconnects:Add(1, { ["disconnect.reason"] = reason })
	end)

	ctx:AddHook("PlayerDisconnected", function(ply)
		if not IsValid(ply) or ply:IsBot() then return end
		self.sessions:Record(ply:TimeConnected())
	end)
end

function C:OnCollect()
	local now = SysTime()
	-- Capped so that a wake-up after hibernation does not count the idle hours.
	local dt = math.min(now - self.lastCollect, 2 * M.Exporter.GetInterval())
	self.lastCollect = now
	local humans = #player.GetHumans()
	if humans > 0 and dt > 0 then self.playerTime:Add(humans * dt) end

	for id, started in pairs(self.pending) do
		if now - started > PENDING_TTL then self.pending[id] = nil end
	end
end

C.Classify = classify

M.Collectors.Register(C)
