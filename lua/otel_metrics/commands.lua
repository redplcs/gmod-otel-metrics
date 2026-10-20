-- Console commands. Available only from the server console and RCON.

local M = OTelMetrics

local function fromConsole(ply)
	if IsValid(ply) then
		ply:PrintMessage(HUD_PRINTCONSOLE, "otel_metrics commands are available only from the server console or RCON.\n")
		return false
	end
	return true
end

local function out(fmt, ...)
	print(string.format(fmt, ...))
end

concommand.Add("otel_metrics_status", function(ply)
	if not fromConsole(ply) then return end
	local s = M.GetStatus()
	out("[OTel Metrics] v%s, %s", M.Version,
		M.Running and "running" or (M.IsDedicated() and "stopped" or "off: not a dedicated server"))
	out("  endpoint: %s, every %g s", s.Endpoint, M.Exporter.GetInterval())
	local _, headerCount = M.ParseHeaders(M.Config:GetString("headers"))
	out("  headers: %s", headerCount > 0 and ("set (" .. headerCount .. ")") or "none")
	if s.LastExportTime then
		out("  last export: %s (%d s ago), result %s, HTTP %s",
			os.date("%Y-%m-%d %H:%M:%S", math.floor(s.LastExportTime)),
			math.floor(M.UnixNow() - s.LastExportTime),
			tostring(s.LastResult),
			s.LastHttpCode and tostring(s.LastHttpCode) or "-")
	else
		out("  last export: none yet")
	end
	out("  last payload: %d bytes, %d points", s.LastPayloadBytes, s.SeriesCount)
	out("  consecutive failures: %d, next attempt in %d s", s.ConsecutiveFailures, math.ceil(s.NextAttemptIn))
	out("  dropped series: %d, invalid points: %d", s.DroppedSeries, M.Stats.invalidPoints)
	local parts = {}
	for _, name in ipairs(M.Collectors.order) do
		local st = M.Collectors.active[name] and "on" or (M.Collectors.state[name] or "off")
		parts[#parts + 1] = name .. "=" .. st
	end
	out("  collectors: %s", table.concat(parts, " "))
	local hibernate = GetConVar("sv_hibernate_think")
	out("  sv_hibernate_think: %s", hibernate and hibernate:GetString() or "n/a")
end, nil, "Show the OTel Metrics export status.")

concommand.Add("otel_metrics_export_now", function(ply)
	if not fromConsole(ply) then return end
	local ok, why = M.Exporter.Export("manual")
	if ok then
		M.Log("Export queued; otel_metrics_status shows the result.")
	else
		M.Log("Export not sent: %s.", tostring(why))
	end
end, nil, "Collect and send metrics right now.")

concommand.Add("otel_metrics_dump", function(ply)
	if not fromConsole(ply) then return end
	local body = M.Exporter.state.lastPayload
	if not body then
		local ok, result = pcall(M.Exporter.BuildPayload)
		if not ok then
			M.Warn("Failed to build the payload: %s", tostring(result))
			return
		end
		body = result
	end
	file.CreateDir("otel_metrics")
	file.Write("otel_metrics/last_payload.json", body)
	M.Log("Wrote %d bytes to data/otel_metrics/last_payload.json.", #body)
end, nil, "Write the last OTLP payload to data/otel_metrics/last_payload.json.")
