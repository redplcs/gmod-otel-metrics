-- Core: version, logging, time, configuration and lifecycle.

local M = OTelMetrics

M.Version = "0.1.3"
M.ScopeName = "otel_metrics"

local SysTime = SysTime
local string_format = string.format

----------------------------------------------------------------------------
-- Logging

local PREFIX = "[OTel Metrics] "

local function formatMessage(fmt, ...)
	if select("#", ...) == 0 then return tostring(fmt) end
	local ok, msg = pcall(string_format, fmt, ...)
	if ok then return msg end
	return tostring(fmt)
end

function M.Log(fmt, ...)
	print(PREFIX .. formatMessage(fmt, ...))
end

function M.Warn(fmt, ...)
	print(PREFIX .. "WARNING: " .. formatMessage(fmt, ...))
end

local lastWarning = {}

--- Prints a warning at most once per `period` seconds for the given key
--- (once per Lua state when `period` is nil). Returns true if it was printed.
function M.WarnOnce(key, period, fmt, ...)
	local now = SysTime()
	local last = lastWarning[key]
	if last and (period == nil or now - last < period) then return false end
	lastWarning[key] = now
	M.Warn(fmt, ...)
	return true
end

--- Logger handed to collectors (OTelMetrics.Logger in the contract).
M.Logger = {
	Info = function(_, fmt, ...) M.Log(fmt, ...) end,
	Warn = function(_, fmt, ...) M.Warn(fmt, ...) end,
	WarnOnce = function(_, key, fmt, ...) M.WarnOnce(key, nil, fmt, ...) end,
}

----------------------------------------------------------------------------
-- Time
--
-- SysTime() is precise but has an arbitrary origin, os.time() is Unix time
-- with one-second resolution. Anchor one to the other once at load.

local unixAnchor = os.time()
local sysAnchor = SysTime()

--- Current Unix time in seconds, with sub-second precision.
function M.UnixNow()
	return unixAnchor + (SysTime() - sysAnchor)
end

--- Unix seconds (double) -> decimal string of nanoseconds. A double cannot
--- hold nanoseconds since 1970 exactly, so the digits are assembled as text.
function M.FormatUnixNano(t)
	local sec = math.floor(t)
	local nanos = math.floor((t - sec) * 1e9 + 0.5)
	if nanos >= 1e9 then
		sec = sec + 1
		nanos = nanos - 1e9
	end
	return string_format("%.0f%09d", sec, nanos)
end

----------------------------------------------------------------------------
-- Helpers

function M.IsFinite(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local utf8force = utf8 and utf8.force

--- Truncates to maxLen bytes and replaces invalid UTF-8: one bad player name
--- must not make the receiver reject the whole payload.
function M.SanitizeString(s, maxLen)
	s = tostring(s)
	if maxLen and #s > maxLen then s = string.sub(s, 1, maxLen) end
	if utf8force then s = utf8force(s) end
	return s
end

function M.Trim(s)
	return (string.match(s, "^%s*(.-)%s*$"))
end

function M.Split(s, sep)
	local out, pos = {}, 1
	while true do
		local i, j = string.find(s, sep, pos, true)
		if not i then
			out[#out + 1] = string.sub(s, pos)
			return out
		end
		out[#out + 1] = string.sub(s, pos, i - 1)
		pos = j + 1
	end
end

--- "Name: value; Name2: value2" -> { Name = "value", Name2 = "value2" }, count
function M.ParseHeaders(s)
	local headers, count = {}, 0
	for _, item in ipairs(M.Split(s or "", ";")) do
		local name, value = string.match(item, "^([^:]*):(.*)$")
		if name then
			name, value = M.Trim(name), M.Trim(value)
			if name ~= "" and value ~= "" then
				headers[name] = value
				count = count + 1
			end
		end
	end
	return headers, count
end

--- "key=value,key2=value2" -> { key = "value", key2 = "value2" }
function M.ParseResourceAttributes(s)
	local attrs = {}
	for _, item in ipairs(M.Split(s or "", ",")) do
		local key, value = string.match(item, "^([^=]*)=(.*)$")
		if key then
			key = M.Trim(key)
			if key ~= "" then attrs[key] = M.Trim(value) end
		end
	end
	return attrs
end

function M.UrlHost(url)
	return string.match(url or "", "^%a[%w+.-]*://([^/:?#]+)")
end

--- Hosts GMod refuses to send HTTP requests to without -allowlocalhttp.
function M.IsPrivateHost(host)
	if not host then return false end
	host = string.lower(host)
	if host == "localhost" then return true end
	local a, b = string.match(host, "^(%d+)%.(%d+)%.%d+%.%d+$")
	a, b = tonumber(a), tonumber(b)
	if not a then return false end
	return a == 127 or a == 10 or (a == 192 and b == 168)
		or (a == 172 and b >= 16 and b <= 31) or (a == 169 and b == 254)
end

----------------------------------------------------------------------------
-- Configuration (ConVars). Values are read on every use: they may be set
-- after the addon has started.

local Config = {}
M.Config = Config

local CVAR_PREFIX = "otel_metrics_"
local convars = {}

function Config:Name(key)
	return CVAR_PREFIX .. key
end

function Config:Define(key, default, help, flags, min, max)
	local cv = CreateConVar(CVAR_PREFIX .. key, tostring(default), flags or 0, help, min, max)
	convars[key] = cv
	return cv
end

function Config:GetString(key)
	local cv = convars[key]
	return cv and cv:GetString() or ""
end

function Config:GetNumber(key)
	local cv = convars[key]
	return cv and cv:GetFloat() or 0
end

function Config:GetInt(key)
	local cv = convars[key]
	return cv and cv:GetInt() or 0
end

function Config:GetBool(key)
	local cv = convars[key]
	return cv ~= nil and cv:GetBool()
end

function Config:OnChange(key, id, fn)
	cvars.AddChangeCallback(CVAR_PREFIX .. key, function(_, _, value)
		fn(value)
	end, "otel_metrics." .. id)
end

function Config:RemoveOnChange(key, id)
	cvars.RemoveChangeCallback(CVAR_PREFIX .. key, "otel_metrics." .. id)
end

local PROTECTED = FCVAR_PROTECTED or 32

Config:Define("enabled", "1", "Export metrics over OTLP/HTTP (0/1).", 0, 0, 1)
Config:Define("endpoint", "http://127.0.0.1:4318/v1/metrics",
	"OTLP/HTTP metrics endpoint, full URL. Alloy and the OTel Collector: /v1/metrics, Prometheus: /api/v1/otlp/v1/metrics.")
Config:Define("headers", "", "Extra HTTP headers: 'Name: value; Name2: value2'. The value is hidden from clients.", PROTECTED)
Config:Define("interval", "15", "Export interval, seconds (5..3600).", 0, 5, 3600)
Config:Define("service_name", "gmod", "service.name resource attribute; becomes the Prometheus job label.")
Config:Define("instance_id", "",
	"service.instance.id resource attribute; becomes the Prometheus instance label. Empty: server IP:port.")
Config:Define("resource_attributes", "", "Extra resource attributes: 'key=value,key2=value2'.")
Config:Define("max_series", "200",
	"Series limit per instrument; extra attribute sets are merged into one overflow series.", 0, 1, 100000)

----------------------------------------------------------------------------
-- Lifecycle

M.Running = false

--- The addon measures dedicated servers only. Players who subscribe to it in
--- the Workshop also load it in single player and on listen servers.
function M.IsDedicated()
	return not (game and game.IsDedicated) or game.IsDedicated()
end

function M.Start()
	if M.Running then return end
	if not M.IsDedicated() then
		M.Log("v%s loaded. Off: not a dedicated server.", M.Version)
		return
	end
	if not Config:GetBool("enabled") then
		M.Log("v%s loaded. Export is OFF (otel_metrics_enabled 0).", M.Version)
		return
	end
	M.Running = true
	M.Collectors.StartAll()
	M.Exporter.Start()
	-- Settings may be set after GM:Initialize, so the endpoint, the interval
	-- and sv_hibernate_think are reported at the first export, not here.
	M.Log("v%s loaded.", M.Version)
end

function M.Stop()
	if not M.Running then return end
	M.Exporter.Stop()
	M.Collectors.StopAll()
	M.Running = false
end

function M.CheckEnvironment()
	local hibernate = GetConVar("sv_hibernate_think")
	if hibernate and not hibernate:GetBool() then
		M.Warn("sv_hibernate_think is 0: while the server is empty, Tick, Think and timers stop and no metrics are sent. Set sv_hibernate_think 1.")
	end
end

function M.Boot()
	M.StartTime = M.UnixNow()
	if GAMEMODE and not M.MapStartTime then
		-- Loaded after the map had started (auto-refresh or a late include).
		M.MapStartTime = os.time()
	end
	M.Collectors.RestoreExternal()

	Config:OnChange("enabled", "core", function(value)
		if (tonumber(value) or 0) ~= 0 then
			if GAMEMODE then M.Start() end
		elseif M.Running then
			M.Stop()
			M.Log("Export stopped (otel_metrics_enabled 0).")
		end
	end)

	hook.Add("InitPostEntity", "otel_metrics.map_start", function()
		M.MapStartTime = os.time()
	end)

	hook.Add("ShutDown", "otel_metrics.shutdown", function()
		if M.Running then M.Exporter.Export("shutdown") end
		M.Stop()
	end)

	if GAMEMODE then
		M.Start()
	else
		hook.Add("Initialize", "otel_metrics.start", function()
			hook.Remove("Initialize", "otel_metrics.start")
			M.Start()
		end)
	end
end

--- Full teardown, used before the addon reloads itself.
function M.Shutdown()
	M.Stop()
	Config:RemoveOnChange("enabled", "core")
	M.Collectors.RemoveConfigCallbacks()
	M.Exporter.RemoveConfigCallbacks()
	hook.Remove("Initialize", "otel_metrics.start")
	hook.Remove("InitPostEntity", "otel_metrics.map_start")
	hook.Remove("ShutDown", "otel_metrics.shutdown")
end

--- Collects and sends right away. Returns false if nothing was sent
--- (export is off, or the previous request is still in flight).
function M.ExportNow()
	local queued = M.Exporter.Export("manual")
	return queued
end
