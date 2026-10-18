-- OTel Metrics: Garry's Mod server metrics over OTLP/HTTP (JSON).
-- Server-side only. Nothing is sent to clients: no AddCSLuaFile, no net messages.

local previous = OTelMetrics
if previous and previous.Shutdown then
	-- Lua auto-refresh: stop the old instance (hooks, timers, wrapped functions)
	-- before the new code takes over.
	local ok, err = pcall(previous.Shutdown)
	if not ok then
		print("[OTel Metrics] WARNING: failed to stop the previous instance: " .. tostring(err))
	end
end

OTelMetrics = {
	MapStartTime = previous and previous.MapStartTime or nil,
	_externalCollectors = previous and previous._externalCollectors or {},
}

include("otel_metrics/core.lua")
include("otel_metrics/meter.lua")
include("otel_metrics/otlp_json.lua")
include("otel_metrics/collectors.lua")
include("otel_metrics/exporter.lua")
include("otel_metrics/commands.lua")

include("otel_metrics/collectors/server.lua")
include("otel_metrics/collectors/physics.lua")
include("otel_metrics/collectors/lua.lua")
include("otel_metrics/collectors/players.lua")
include("otel_metrics/collectors/connections.lua")
include("otel_metrics/collectors/entities.lua")
include("otel_metrics/collectors/info.lua")

OTelMetrics.Boot()
