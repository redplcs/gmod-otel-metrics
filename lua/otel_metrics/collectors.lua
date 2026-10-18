-- Collector manager: lifecycle, per-collector context and error isolation.
--
-- A collector is a table:
--   Name           string, letters, digits and underscores
--   Description    string
--   DefaultEnabled boolean (default true)
--   IsSupported    function(self): boolean, optional
--   Start          function(self, ctx)
--   Stop           function(self), optional
--   OnTick         function(self, now), optional, every server tick
--   OnCollect      function(self), optional, right before each collection
--
-- Hooks, game events, observable instruments and wrapped functions are
-- registered through the context, so stopping a collector removes all of them.

local M = OTelMetrics
local SysTime = SysTime

local ERROR_LIMIT, ERROR_WINDOW = 10, 60

local Collectors = {
	defs = {}, order = {}, active = {},
	state = {},          -- name -> "unsupported" | "failed"
	errorCounts = {}, errorTimes = {}, pendingDisable = {},
	durations = {}, lastDurations = {},
}
M.Collectors = Collectors

-- Originals of wrapped functions survive a reload of this file, so a new
-- instance always wraps the real function, never a stale wrapper.
OTelMetricsOriginals = OTelMetricsOriginals or setmetatable({}, { __mode = "k" })

----------------------------------------------------------------------------
-- Context

---@class OTelMetrics.CollectorContext
local Context = {}
Context.__index = Context

local MeterProxy = {}
MeterProxy.__index = MeterProxy

function MeterProxy:CreateCounter(name, opts) return self._meter:CreateCounter(name, opts) end
function MeterProxy:CreateGauge(name, opts) return self._meter:CreateGauge(name, opts) end
function MeterProxy:CreateHistogram(name, opts) return self._meter:CreateHistogram(name, opts) end

function MeterProxy:CreateObservableCounter(name, callback, opts)
	return self._ctx:_Track(self._meter:_CreateObservable("obs_counter", name, callback, opts, self._ctx.Name))
end

function MeterProxy:CreateObservableGauge(name, callback, opts)
	return self._ctx:_Track(self._meter:_CreateObservable("obs_gauge", name, callback, opts, self._ctx.Name))
end

local function newContext(def)
	local ctx = setmetatable({
		Name = def.Name,
		Config = M.Config,
		Log = M.Logger,
		_def = def, _hooks = {}, _observables = {}, _detours = {}, _hookIndex = 0,
	}, Context)
	ctx.Meter = setmetatable({ _meter = M.GetMeter(M.ScopeName, M.Version), _ctx = ctx }, MeterProxy)
	return ctx
end

function Context:_Track(handle)
	self._observables[#self._observables + 1] = handle
	return handle
end

--- Adds a hook. The wrapper never returns a value, so it cannot change
--- game behaviour, and errors are counted instead of propagated.
function Context:AddHook(event, fn)
	self._hookIndex = self._hookIndex + 1
	local id = "otel_metrics." .. self.Name .. "." .. self._hookIndex
	local name = self.Name
	hook.Add(event, id, function(...)
		local ok, err = pcall(fn, ...)
		if not ok then Collectors.ReportError(name, err) end
	end)
	self._hooks[#self._hooks + 1] = { event, id }
end

function Context:ListenGameEvent(event, fn)
	gameevent.Listen(event)
	self:AddHook(event, fn)
end

--- Replaces target[key] with wrap(original). Restored when the collector stops.
function Context:Detour(target, key, wrap)
	local saved = OTelMetricsOriginals[target]
	local original = saved and saved[key] or target[key]
	local wrapped = wrap(original)
	if type(wrapped) ~= "function" then
		error("Detour: the wrapper for " .. tostring(key) .. " must return a function", 2)
	end
	saved = saved or {}
	saved[key] = original
	OTelMetricsOriginals[target] = saved
	target[key] = wrapped
	self._detours[#self._detours + 1] = { target, key, wrapped, original }
end

function Context:_Cleanup()
	for i = #self._hooks, 1, -1 do
		local h = self._hooks[i]
		hook.Remove(h[1], h[2])
	end
	self._hooks = {}

	for i = #self._observables, 1, -1 do
		self._observables[i]:Unregister()
	end
	self._observables = {}

	for i = #self._detours, 1, -1 do
		local d = self._detours[i]
		local target, key, wrapped, original = d[1], d[2], d[3], d[4]
		if target[key] == wrapped then
			target[key] = original
		else
			M.Warn("Collector '%s': %s was wrapped again by someone else; leaving it in place.", self.Name, tostring(key))
		end
		local saved = OTelMetricsOriginals[target]
		if saved then saved[key] = nil end
	end
	self._detours = {}
end

----------------------------------------------------------------------------
-- Registration

function Collectors.Register(def, external)
	if type(def) ~= "table" or type(def.Name) ~= "string" or type(def.Start) ~= "function" then
		M.Warn("RegisterCollector: a collector needs a Name and a Start function.")
		return false
	end
	local name = def.Name
	if not string.match(name, "^[%w_]+$") then
		M.Warn("RegisterCollector: collector name '%s' may contain only letters, digits and underscores.", name)
		return false
	end

	if Collectors.defs[name] then
		Collectors.Stop(name)
	else
		Collectors.order[#Collectors.order + 1] = name
	end
	Collectors.defs[name] = def
	Collectors.state[name] = nil
	if external then M._externalCollectors[name] = def end

	M.Config:Define("collector_" .. name, def.DefaultEnabled == false and "0" or "1",
		"Enable the '" .. name .. "' collector (0/1).", 0, 0, 1)
	M.Config:OnChange("collector_" .. name, "collector." .. name, function(value)
		if not M.Running then return end
		if (tonumber(value) or 0) ~= 0 then
			Collectors.state[name] = nil
			Collectors.errorTimes[name] = nil
			Collectors.Start(name)
		else
			Collectors.Stop(name)
		end
	end)

	if M.Running then Collectors.Start(name) end
	return true
end

--- Public API: registers a collector from another addon.
function M.RegisterCollector(def)
	return Collectors.Register(def, true)
end

--- Re-registers collectors of other addons after this addon reloaded itself.
function Collectors.RestoreExternal()
	for _, def in pairs(M._externalCollectors) do
		Collectors.Register(def, true)
	end
end

function Collectors.RemoveConfigCallbacks()
	for _, name in ipairs(Collectors.order) do
		M.Config:RemoveOnChange("collector_" .. name, "collector." .. name)
	end
end

----------------------------------------------------------------------------
-- Start and stop

function Collectors.IsEnabled(name)
	return M.Config:GetBool("collector_" .. name)
end

function Collectors.Start(name)
	local def = Collectors.defs[name]
	if not def or Collectors.active[name] or not Collectors.IsEnabled(name) then return end
	if def.IsSupported then
		local ok, supported = pcall(def.IsSupported, def)
		if not ok or not supported then
			Collectors.state[name] = "unsupported"
			return
		end
	end
	local ctx = newContext(def)
	Collectors.active[name] = ctx
	Collectors.state[name] = nil
	local ok, err = pcall(def.Start, def, ctx)
	if not ok then
		Collectors.ReportError(name, err)
		Collectors.Stop(name)
		Collectors.state[name] = "failed"
	end
end

function Collectors.Stop(name)
	local ctx = Collectors.active[name]
	if not ctx then return end
	Collectors.active[name] = nil
	local def = ctx._def
	if def.Stop then
		local ok, err = pcall(def.Stop, def)
		if not ok then M.Warn("Collector '%s' failed to stop cleanly: %s", name, tostring(err)) end
	end
	ctx:_Cleanup()
end

function Collectors.StartAll()
	for i = 1, #Collectors.order do
		Collectors.Start(Collectors.order[i])
	end
	hook.Add("Tick", "otel_metrics.tick", Collectors.Tick)
end

function Collectors.StopAll()
	hook.Remove("Tick", "otel_metrics.tick")
	for i = #Collectors.order, 1, -1 do
		Collectors.Stop(Collectors.order[i])
	end
end

----------------------------------------------------------------------------
-- Errors: counted, logged once a minute per collector; a collector that
-- fails ERROR_LIMIT times within ERROR_WINDOW seconds is switched off.

function Collectors.ReportError(name, err)
	name = name or "external"
	Collectors.errorCounts[name] = (Collectors.errorCounts[name] or 0) + 1
	M.WarnOnce("collector-error:" .. name, 60, "Collector '%s' error: %s", name, tostring(err))
	if not Collectors.defs[name] then return end
	local now = SysTime()
	local times = Collectors.errorTimes[name] or {}
	times[#times + 1] = now
	while #times > ERROR_LIMIT do table.remove(times, 1) end
	Collectors.errorTimes[name] = times
	if #times >= ERROR_LIMIT and now - times[1] <= ERROR_WINDOW then
		-- Disabled on the next tick, never from inside a running hook call.
		Collectors.pendingDisable[name] = true
	end
end

function Collectors.ProcessPending()
	for name in pairs(Collectors.pendingDisable) do
		Collectors.pendingDisable[name] = nil
		if Collectors.active[name] then
			Collectors.Stop(name)
			Collectors.state[name] = "failed"
			Collectors.errorTimes[name] = nil
			M.Warn("Collector '%s' disabled after %d errors in %d s. Re-enable it with otel_metrics_collector_%s 0, then 1.",
				name, ERROR_LIMIT, ERROR_WINDOW, name)
		end
	end
end

----------------------------------------------------------------------------
-- Tick dispatch and collection phases

function Collectors.Tick()
	local now = SysTime()
	local order, active = Collectors.order, Collectors.active
	for i = 1, #order do
		local ctx = active[order[i]]
		if ctx then
			local def = ctx._def
			local onTick = def.OnTick
			if onTick then
				local ok, err = pcall(onTick, def, now)
				if not ok then Collectors.ReportError(ctx.Name, err) end
			end
		end
	end
	if next(Collectors.pendingDisable) then Collectors.ProcessPending() end
end

function Collectors.AddDuration(name, dt)
	name = name or "external"
	Collectors.durations[name] = (Collectors.durations[name] or 0) + dt
end

--- Runs OnCollect of every active collector, before observable callbacks.
function Collectors.BeginCollect()
	if next(Collectors.pendingDisable) then Collectors.ProcessPending() end
	Collectors.durations = {}
	for i = 1, #Collectors.order do
		local ctx = Collectors.active[Collectors.order[i]]
		if ctx and ctx._def.OnCollect then
			local started = SysTime()
			local ok, err = pcall(ctx._def.OnCollect, ctx._def)
			Collectors.AddDuration(ctx.Name, SysTime() - started)
			if not ok then Collectors.ReportError(ctx.Name, err) end
		end
	end
end

--- Durations are reported one collection late: the self-metric that reports
--- them runs inside the collection it would be measuring.
function Collectors.EndCollect()
	Collectors.lastDurations = Collectors.durations
	Collectors.durations = {}
end
