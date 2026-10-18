-- Exporter: periodic collection and OTLP/HTTP delivery.
--
-- Sums and histograms are cumulative, so a lost or skipped request loses no
-- data: the next payload carries the totals. Hence no queue, at most one
-- request in flight, and a plain pause after failures.

local M = OTelMetrics
local SysTime = SysTime

local Exporter = {}
M.Exporter = Exporter

local TIMER = "otel_metrics.export"
local MAX_BACKOFF = 300
local LONG_PAUSE = 300

local state = {
	seq = 0,
	inFlight = nil,        -- { seq = n, started = SysTime() }
	failures = 0,
	nextAttempt = 0,
	lastResult = nil,
	lastCode = nil,
	lastExport = nil,      -- Unix time of the last finished attempt
	lastBytes = 0,
	lastPoints = 0,
	lastSerialize = 0,
	lastPayload = nil,
	results = {},          -- result -> count
	rejectedPoints = 0,
}
Exporter.state = state

local function count(result)
	if result ~= "skipped" then state.lastResult = result end
	state.results[result] = (state.results[result] or 0) + 1
end

function Exporter.GetInterval()
	local v = M.Config:GetNumber("interval")
	if v < 5 then v = 5 end
	return v
end

----------------------------------------------------------------------------
-- Self-metrics

local function createSelfMetrics()
	local meter = M.GetMeter(M.ScopeName, M.Version)
	local function counter(name, opts, cb) meter:_CreateObservable("obs_counter", name, cb, opts, "self") end
	local function gauge(name, opts, cb) meter:_CreateObservable("obs_gauge", name, cb, opts, "self") end

	counter("gmod.exporter.exports", { unit = "{export}", description = "Export attempts by result." }, function(o)
		for result, n in pairs(state.results) do o:Observe(n, { result = result }) end
	end)
	gauge("gmod.exporter.payload.size", { unit = "By", description = "Size of the previous payload." }, function(o)
		if state.lastBytes > 0 then o:Observe(state.lastBytes) end
	end)
	gauge("gmod.exporter.serialize.duration", { unit = "s", description = "Time spent encoding the previous payload." }, function(o)
		if state.lastBytes > 0 then o:Observe(state.lastSerialize) end
	end)
	gauge("gmod.exporter.series", { unit = "{series}", description = "Data points in the previous payload." }, function(o)
		if state.lastBytes > 0 then o:Observe(state.lastPoints) end
	end)
	counter("gmod.exporter.series.dropped", { unit = "{series}", description = "Attribute sets merged into an overflow series." }, function(o)
		for _, d in ipairs(M.Registry.DroppedSeries()) do o:Observe(d.dropped, { instrument = d.name }) end
	end)
	counter("gmod.exporter.points.invalid", { unit = "{point}", description = "Measurements dropped as NaN, infinite or negative." }, function(o)
		o:Observe(M.Stats.invalidPoints)
	end)
	counter("gmod.exporter.points.rejected", { unit = "{point}", description = "Data points the receiver reported as rejected." }, function(o)
		o:Observe(state.rejectedPoints)
	end)
	gauge("gmod.collector.duration", { unit = "s", description = "Time each collector spent in the previous collection." }, function(o)
		for name, dt in pairs(M.Collectors.lastDurations) do o:Observe(dt, { collector = name }) end
	end)
	counter("gmod.collector.errors", { unit = "{error}", description = "Errors raised inside collectors." }, function(o)
		for name, n in pairs(M.Collectors.errorCounts) do o:Observe(n, { collector = name }) end
	end)
	gauge("gmod.collector.enabled", { description = "1 if the collector is running, 0 otherwise." }, function(o)
		for _, name in ipairs(M.Collectors.order) do
			o:Observe(M.Collectors.active[name] and 1 or 0, { collector = name })
		end
	end)
end

----------------------------------------------------------------------------
-- Lifecycle

local function onTimer()
	Exporter.Export("timer")
end

function Exporter.Start()
	createSelfMetrics()
	timer.Create(TIMER, Exporter.GetInterval(), 0, onTimer)
	M.Config:OnChange("interval", "exporter", function()
		if timer.Exists(TIMER) then timer.Create(TIMER, Exporter.GetInterval(), 0, onTimer) end
	end)
end

function Exporter.Stop()
	timer.Remove(TIMER)
	M.Config:RemoveOnChange("interval", "exporter")
	state.inFlight = nil -- late responses are ignored
end

function Exporter.RemoveConfigCallbacks()
	M.Config:RemoveOnChange("interval", "exporter")
end

----------------------------------------------------------------------------
-- Payload

function Exporter.Resource()
	local attrs = M.ParseResourceAttributes(M.Config:GetString("resource_attributes"))
	local service = M.Trim(M.Config:GetString("service_name"))
	attrs["service.name"] = service ~= "" and service or "gmod"
	local instance = M.Trim(M.Config:GetString("instance_id"))
	if instance == "" and game and game.GetIPAddress then instance = tostring(game.GetIPAddress()) end
	if instance ~= "" then attrs["service.instance.id"] = instance end
	attrs["telemetry.sdk.name"] = M.ScopeName
	attrs["telemetry.sdk.language"] = "lua"
	attrs["telemetry.sdk.version"] = M.Version
	return (M.NormalizeAttributes(attrs))
end

--- Collects all instruments and encodes them. Returns body, points, encode time.
function Exporter.BuildPayload()
	M.Collectors.BeginCollect()
	local ok, scopes, points = pcall(M.Registry.Collect)
	M.Collectors.EndCollect()
	if not ok then error(scopes, 0) end
	local started = SysTime()
	local body = M.OtlpJson.EncodeMetrics({
		resource = Exporter.Resource(),
		startTime = M.StartTime,
		time = M.UnixNow(),
		scopes = scopes,
	})
	return body, points, SysTime() - started
end

----------------------------------------------------------------------------
-- Delivery

local function finish(seq)
	local flight = state.inFlight
	if not flight or flight.seq ~= seq then return false end
	state.inFlight = nil
	return true
end

local function backoff(minDelay)
	state.failures = state.failures + 1
	local delay = math.min(Exporter.GetInterval() * 2 ^ state.failures, MAX_BACKOFF)
	if minDelay and minDelay > delay then delay = minDelay end
	state.nextAttempt = SysTime() + delay
	return math.floor(delay + 0.5)
end

local function excerpt(s)
	s = string.gsub(tostring(s or ""), "%s+", " ")
	if #s > 200 then s = string.sub(s, 1, 200) .. "..." end
	return s
end

local function header(headers, name)
	if type(headers) ~= "table" then return nil end
	name = string.lower(name)
	for k, v in pairs(headers) do
		if type(k) == "string" and string.lower(k) == name then return v end
	end
end

--- reason: "timer", "manual" or "shutdown". Manual and shutdown exports
--- ignore the pause after failures. Returns ok, explanation.
function Exporter.Export(reason)
	if not M.Running then return false, "export is stopped" end
	local now = SysTime()

	local flight = state.inFlight
	if flight then
		local limit = 2 * Exporter.GetInterval()
		if now - flight.started < limit then
			count("skipped")
			return false, "the previous request is still in flight"
		end
		Exporter.OnNetworkFailure(flight.seq, string.format("no response within %g s", limit))
	end

	if reason == "timer" then
		if not M.MapStartTime then return false, "the map is still loading" end
		if now < state.nextAttempt then return false, "pausing after errors" end
	end

	local endpoint = M.Trim(M.Config:GetString("endpoint"))
	if not string.match(string.lower(endpoint), "^https?://") then
		M.WarnOnce("bad-endpoint", 600, "otel_metrics_endpoint must start with http:// or https:// (now '%s').", endpoint)
		return false, "invalid endpoint"
	end

	local ok, body, points, encodeTime = pcall(Exporter.BuildPayload)
	if not ok then
		count("error")
		M.WarnOnce("build-failed", 60, "Failed to build the payload: %s", tostring(body))
		return false, "failed to build the payload"
	end
	state.lastPayload, state.lastBytes, state.lastPoints, state.lastSerialize = body, #body, points, encodeTime

	state.seq = state.seq + 1
	local seq = state.seq
	state.inFlight = { seq = seq, started = now }

	local queued = HTTP({
		url = endpoint,
		method = "POST",
		body = body,
		type = "application/json",
		headers = (M.ParseHeaders(M.Config:GetString("headers"))),
		success = function(code, responseBody, responseHeaders)
			Exporter.OnResponse(seq, code, responseBody, responseHeaders)
		end,
		failed = function(failure)
			Exporter.OnNetworkFailure(seq, failure)
		end,
	})
	if not queued then
		Exporter.OnNetworkFailure(seq, "the request was not queued (is HTTP disabled?)")
		return false, "the request was not queued"
	end
	return true, "queued"
end

function Exporter.CheckPartialSuccess(body)
	if type(body) ~= "string" or body == "" then return end
	local rejected = tonumber(string.match(body, '"rejectedDataPoints"%s*:%s*"?(%d+)'))
	if rejected and rejected > 0 then
		state.rejectedPoints = state.rejectedPoints + rejected
		local message = string.match(body, '"errorMessage"%s*:%s*"(.-)"') or ""
		M.WarnOnce("partial-success", 600, "The receiver rejected %d data points: %s", rejected, excerpt(message))
	end
end

-- GMod reports HTTP 4xx and 5xx through the success callback, so the
-- decision is made by status code.
function Exporter.OnResponse(seq, code, body, headers)
	if not finish(seq) then return end
	code = tonumber(code) or 0
	state.lastCode = code
	state.lastExport = M.UnixNow()

	if code >= 200 and code < 300 then
		count("ok")
		state.failures = 0
		state.nextAttempt = 0
		Exporter.CheckPartialSuccess(body)
		return
	end

	if code == 429 or code >= 500 then
		count("retryable")
		local delay = backoff(tonumber(header(headers, "Retry-After")))
		M.WarnOnce("http-retry-" .. code, 300, "The receiver answered HTTP %d; next attempt in %d s.", code, delay)
		return
	end

	count("rejected")
	if code == 401 or code == 403 then
		state.nextAttempt = SysTime() + LONG_PAUSE
		M.WarnOnce("http-auth", 600, "The receiver answered HTTP %d: check otel_metrics_headers. Next attempt in %d s.", code, LONG_PAUSE)
	elseif code == 404 then
		state.nextAttempt = SysTime() + LONG_PAUSE
		M.WarnOnce("http-404", 600, "The receiver answered HTTP 404: check the path in otel_metrics_endpoint (Alloy and the OTel Collector use /v1/metrics, Prometheus uses /api/v1/otlp/v1/metrics).")
	elseif code == 413 then
		M.WarnOnce("http-413", 600, "The receiver answered HTTP 413: the payload (%d bytes) is too large.", state.lastBytes)
	else
		M.WarnOnce("http-" .. code, 600, "The receiver answered HTTP %d: %s", code, excerpt(body))
	end
end

function Exporter.OnNetworkFailure(seq, failure)
	if not finish(seq) then return end
	state.lastCode = nil
	state.lastExport = M.UnixNow()
	count("network")
	local delay = backoff()
	local endpoint = M.Config:GetString("endpoint")
	local host = M.UrlHost(endpoint) or endpoint
	if M.IsPrivateHost(host) then
		M.WarnOnce("network-local", 600,
			"The request to %s failed (%s). GMod blocks HTTP to local and private addresses unless srcds runs with -allowlocalhttp. Next attempt in %d s.",
			host, tostring(failure), delay)
	else
		M.WarnOnce("network", 300, "The request to %s failed (%s). Next attempt in %d s.", host, tostring(failure), delay)
	end
end

----------------------------------------------------------------------------
-- Status

---@return OTelMetrics.ExporterStatus
function M.GetStatus()
	local dropped = 0
	for _, d in ipairs(M.Registry.DroppedSeries()) do dropped = dropped + d.dropped end
	return {
		Endpoint = M.Config:GetString("endpoint"),
		LastExportTime = state.lastExport,
		LastResult = state.lastResult,
		LastHttpCode = state.lastCode,
		LastPayloadBytes = state.lastBytes,
		SeriesCount = state.lastPoints,
		DroppedSeries = dropped,
		ConsecutiveFailures = state.failures,
		NextAttemptIn = math.max(0, state.nextAttempt - SysTime()),
	}
end
