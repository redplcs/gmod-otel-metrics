-- Instruments and series storage: a small subset of the OpenTelemetry metrics
-- API (Meter, Counter, Gauge, Histogram, observable counters and gauges).
-- All sums and histograms use cumulative temporality.

local M = OTelMetrics
local IsFinite = M.IsFinite
local Sanitize = M.SanitizeString
local SysTime = SysTime

local MAX_KEY_BYTES = 64
local MAX_VALUE_BYTES = 128
local DROPPED_TRACK_LIMIT = 10000

M.Stats = { invalidPoints = 0 }

local function countInvalid()
	M.Stats.invalidPoints = M.Stats.invalidPoints + 1
end

local function copy(list)
	local out = {}
	for i = 1, #list do out[i] = list[i] end
	return out
end

----------------------------------------------------------------------------
-- Attributes

local EMPTY = {}
local OVERFLOW_ATTRS = { { "otel.metric.overflow", true } }

--- { key = value } -> sorted array of { key, value } and a lookup key.
--- Only string keys and string, boolean or finite number values are kept.
local function normalize(attributes)
	if attributes == nil or next(attributes) == nil then return EMPTY, "" end
	local keys = {}
	for k, v in pairs(attributes) do
		local tv = type(v)
		if type(k) == "string" and (tv == "string" or tv == "boolean" or (tv == "number" and IsFinite(v))) then
			keys[#keys + 1] = k
		end
	end
	if #keys == 0 then return EMPTY, "" end
	table.sort(keys)
	local list, parts = {}, {}
	for i = 1, #keys do
		local k = keys[i]
		local v = attributes[k]
		local key = Sanitize(k, MAX_KEY_BYTES)
		if type(v) == "string" then v = Sanitize(v, MAX_VALUE_BYTES) end
		list[i] = { key, v }
		parts[i] = key .. "\31" .. type(v) .. "\31" .. tostring(v)
	end
	return list, table.concat(parts, "\30")
end
M.NormalizeAttributes = normalize

----------------------------------------------------------------------------
-- Instrument base

local Instrument = {}
Instrument.__index = Instrument

local function newInstrument(meta, meter, kind, name, opts)
	opts = type(opts) == "table" and opts or {}
	return setmetatable({
		meter = meter,
		kind = kind,
		name = name,
		unit = type(opts.unit) == "string" and opts.unit or "",
		description = type(opts.description) == "string" and opts.description or "",
		maxSeries = tonumber(opts.maxSeries),
		series = {}, list = {}, count = 0, overflow = nil,
		dropped = 0, droppedKeys = {}, droppedKeyCount = 0,
	}, meta)
end

function Instrument:Limit()
	return self.maxSeries or math.max(1, M.Config:GetInt("max_series"))
end

--- Remembers an attribute set that did not fit into the series limit.
function Instrument:_Drop(key)
	if not self.droppedKeys[key] and self.droppedKeyCount < DROPPED_TRACK_LIMIT then
		self.droppedKeys[key] = true
		self.droppedKeyCount = self.droppedKeyCount + 1
		self.dropped = self.dropped + 1
	end
end

function Instrument:_Series(attributes)
	local list, key = normalize(attributes)
	local s = self.series[key]
	if s then return s end
	if self.count >= self:Limit() then
		self:_Drop(key)
		if not self.overflow then self.overflow = self:_NewSeries(OVERFLOW_ATTRS) end
		return self.overflow
	end
	s = self:_NewSeries(list)
	self.series[key] = s
	self.list[#self.list + 1] = s
	self.count = self.count + 1
	return s
end

function Instrument:_Points(filter)
	local points = {}
	for i = 1, #self.list do
		local s = self.list[i]
		if not filter or filter(s) then points[#points + 1] = s end
	end
	local o = self.overflow
	if o and (not filter or filter(o)) then points[#points + 1] = o end
	return points
end

----------------------------------------------------------------------------
-- Counter: monotonic cumulative sum.

---@class OTelMetrics.Counter
local Counter = setmetatable({}, { __index = Instrument })
Counter.__index = Counter

function Counter:_NewSeries(attrs)
	return { attrs = attrs, value = 0 }
end

--- Adds a non-negative value.
function Counter:Add(value, attributes)
	if not IsFinite(value) or value < 0 then return countInvalid() end
	local s = self:_Series(attributes)
	s.value = s.value + value
end

local BoundCounter = {}
BoundCounter.__index = BoundCounter

function BoundCounter:Add(value)
	if not IsFinite(value) or value < 0 then return countInvalid() end
	local s = self.s
	s.value = s.value + value
end

--- Resolves the series once; Add on the result does not allocate.
function Counter:Bind(attributes)
	return setmetatable({ s = self:_Series(attributes) }, BoundCounter)
end

function Counter:_Collect()
	local points = self:_Points()
	if #points == 0 then return nil end
	return { kind = "sum", monotonic = true, points = points }
end

----------------------------------------------------------------------------
-- Gauge: last recorded value.

---@class OTelMetrics.Gauge
local Gauge = setmetatable({}, { __index = Instrument })
Gauge.__index = Gauge

function Gauge:_NewSeries(attrs)
	return { attrs = attrs, value = 0, set = false }
end

function Gauge:Record(value, attributes)
	if not IsFinite(value) then return countInvalid() end
	local s = self:_Series(attributes)
	s.value = value
	s.set = true
end

--- Stops exporting the series with these attributes.
function Gauge:Remove(attributes)
	local _, key = normalize(attributes)
	local s = self.series[key]
	if not s then return end
	self.series[key] = nil
	self.count = self.count - 1
	for i = #self.list, 1, -1 do
		if self.list[i] == s then
			table.remove(self.list, i)
			break
		end
	end
end

local function isSet(s) return s.set end

function Gauge:_Collect()
	local points = self:_Points(isSet)
	if #points == 0 then return nil end
	return { kind = "gauge", points = points }
end

----------------------------------------------------------------------------
-- Histogram: explicit buckets, cumulative. Bucket i holds values in
-- (bounds[i-1], bounds[i]], which matches Prometheus "le".

---@class OTelMetrics.Histogram
local Histogram = setmetatable({}, { __index = Instrument })
Histogram.__index = Histogram

function Histogram:_NewSeries(attrs)
	local counts = {}
	for i = 1, #self.bounds + 1 do counts[i] = 0 end
	return { attrs = attrs, counts = counts, count = 0, sum = 0 }
end

local function record(bounds, s, value)
	local lo, hi = 1, #bounds + 1
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if value <= bounds[mid] then hi = mid else lo = mid + 1 end
	end
	s.counts[lo] = s.counts[lo] + 1
	s.count = s.count + 1
	s.sum = s.sum + value
end

function Histogram:Record(value, attributes)
	if not IsFinite(value) then return countInvalid() end
	record(self.bounds, self:_Series(attributes), value)
end

local BoundHistogram = {}
BoundHistogram.__index = BoundHistogram

function BoundHistogram:Record(value)
	if not IsFinite(value) then return countInvalid() end
	local h = self.h
	if self.gen ~= h.gen then
		-- Buckets were redefined: the old series is gone, resolve again.
		self.s = h:_Series(self.attributes)
		self.gen = h.gen
	end
	record(h.bounds, self.s, value)
end

function Histogram:Bind(attributes)
	return setmetatable({ h = self, s = self:_Series(attributes), attributes = attributes, gen = self.gen }, BoundHistogram)
end

function Histogram:_SetBounds(bounds)
	self.bounds = bounds
	self.series, self.list, self.count, self.overflow = {}, {}, 0, nil
	self.gen = self.gen + 1
end

function Histogram:_Collect()
	local points = self:_Points()
	if #points == 0 then return nil end
	return { kind = "histogram", points = points, bounds = self.bounds }
end

----------------------------------------------------------------------------
-- Observable counters and gauges: values come from a callback on each
-- collection. A series the callback did not report is not exported.

local Observable = setmetatable({}, { __index = Instrument })
Observable.__index = Observable

function Observable:_NewSeries(attrs)
	return { attrs = attrs, value = 0 }
end

---@class OTelMetrics.Observer
local Observer = {}
Observer.__index = Observer

function Observer:Observe(value, attributes)
	if not IsFinite(value) then return countInvalid() end
	local inst = self.inst
	local s = inst:_Series(attributes)
	if s == inst.overflow and inst.kind == "obs_counter" then
		s.value = s.value + value
	else
		s.value = value
	end
end

function Observable:_Collect()
	self.series, self.list, self.count, self.overflow = {}, {}, 0, nil
	local callback = self.callback
	if not callback then return nil end
	local started = SysTime()
	local ok, err = pcall(callback, self.observer)
	M.Collectors.AddDuration(self.owner, SysTime() - started)
	if not ok then M.Collectors.ReportError(self.owner, err) end
	local points = self:_Points()
	if #points == 0 then return nil end
	if self.kind == "obs_counter" then
		return { kind = "sum", monotonic = true, points = points }
	end
	return { kind = "gauge", points = points }
end

---@class OTelMetrics.Observable
local ObservableHandle = {}
ObservableHandle.__index = ObservableHandle

function ObservableHandle:Unregister()
	local inst = self.inst
	if inst.callback == self.callback then
		inst.callback = nil
		inst.owner = nil
	end
end

----------------------------------------------------------------------------
-- No-op instrument returned on invalid input: every method is callable and
-- does nothing, so a bad instrument never breaks the caller.

local NOOP
local function noop() return NOOP end
NOOP = setmetatable({}, { __index = function() return noop end })
M.NoopInstrument = NOOP

----------------------------------------------------------------------------
-- Meter and registry

---@class OTelMetrics.Meter
local Meter = {}
Meter.__index = Meter

local Registry = { meters = {}, list = {} }
M.Registry = Registry

--- Returns the meter (instrumentation scope) with this name, creating it once.
---@return OTelMetrics.Meter
function M.GetMeter(name, version)
	name = tostring(name or M.ScopeName)
	local meter = Registry.meters[name]
	if meter then return meter end
	meter = setmetatable({
		name = name,
		version = version and tostring(version) or "",
		instruments = {},
		list = {},
	}, Meter)
	Registry.meters[name] = meter
	Registry.list[#Registry.list + 1] = meter
	return meter
end

local function validBounds(bounds)
	if type(bounds) ~= "table" or #bounds == 0 then return false end
	local prev
	for i = 1, #bounds do
		local b = bounds[i]
		if not IsFinite(b) or (prev and b <= prev) then return false end
		prev = b
	end
	return true
end

local function sameBounds(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

--- Returns (existing instrument or nil, rejected).
local function lookup(meter, name, kind)
	if type(name) ~= "string" or name == "" then
		M.WarnOnce("bad-name:" .. tostring(name), nil, "Invalid instrument name: %s", tostring(name))
		return nil, true
	end
	local existing = meter.instruments[name]
	if existing and existing.kind ~= kind then
		M.WarnOnce("conflict:" .. meter.name .. ":" .. name, nil,
			"Instrument %s already exists as %s; the %s with the same name is ignored.", name, existing.kind, kind)
		return nil, true
	end
	return existing, false
end

function Meter:_Add(inst)
	self.instruments[inst.name] = inst
	self.list[#self.list + 1] = inst
	return inst
end

---@return OTelMetrics.Counter
function Meter:CreateCounter(name, opts)
	local existing, rejected = lookup(self, name, "counter")
	if rejected then return NOOP end
	return existing or self:_Add(newInstrument(Counter, self, "counter", name, opts))
end

---@return OTelMetrics.Gauge
function Meter:CreateGauge(name, opts)
	local existing, rejected = lookup(self, name, "gauge")
	if rejected then return NOOP end
	return existing or self:_Add(newInstrument(Gauge, self, "gauge", name, opts))
end

--- opts.boundaries is required: strictly increasing finite numbers.
---@return OTelMetrics.Histogram
function Meter:CreateHistogram(name, opts)
	local bounds = type(opts) == "table" and opts.boundaries or nil
	if not validBounds(bounds) then
		M.WarnOnce("bad-bounds:" .. tostring(name), nil,
			"Histogram %s needs strictly increasing finite boundaries.", tostring(name))
		return NOOP
	end
	local existing, rejected = lookup(self, name, "histogram")
	if rejected then return NOOP end
	if existing then
		if not sameBounds(existing.bounds, bounds) then existing:_SetBounds(copy(bounds)) end
		return existing
	end
	local inst = newInstrument(Histogram, self, "histogram", name, opts)
	inst.bounds = copy(bounds)
	inst.gen = 0
	return self:_Add(inst)
end

function Meter:_CreateObservable(kind, name, callback, opts, owner)
	if type(callback) ~= "function" then
		M.WarnOnce("bad-callback:" .. tostring(name), nil, "Observable %s needs a callback function.", tostring(name))
		return NOOP
	end
	local existing, rejected = lookup(self, name, kind)
	if rejected then return NOOP end
	local inst = existing
	if not inst then
		inst = self:_Add(newInstrument(Observable, self, kind, name, opts))
		inst.observer = setmetatable({ inst = inst }, Observer)
	end
	inst.callback = callback
	inst.owner = owner
	return setmetatable({ inst = inst, callback = callback }, ObservableHandle)
end

---@return OTelMetrics.Observable
function Meter:CreateObservableCounter(name, callback, opts)
	return self:_CreateObservable("obs_counter", name, callback, opts, nil)
end

---@return OTelMetrics.Observable
function Meter:CreateObservableGauge(name, callback, opts)
	return self:_CreateObservable("obs_gauge", name, callback, opts, nil)
end

--- Calls observable callbacks and returns { scope... } plus the number of points.
function Registry.Collect()
	local scopes, points = {}, 0
	for _, meter in ipairs(Registry.list) do
		local metrics = {}
		for _, inst in ipairs(meter.list) do
			local data = inst:_Collect()
			if data then
				data.name, data.unit, data.description = inst.name, inst.unit, inst.description
				metrics[#metrics + 1] = data
				points = points + #data.points
			end
		end
		if #metrics > 0 then
			scopes[#scopes + 1] = { name = meter.name, version = meter.version, metrics = metrics }
		end
	end
	return scopes, points
end

function Registry.DroppedSeries()
	local out = {}
	for _, meter in ipairs(Registry.list) do
		for _, inst in ipairs(meter.list) do
			if inst.dropped and inst.dropped > 0 then
				out[#out + 1] = { name = inst.name, dropped = inst.dropped }
			end
		end
	end
	return out
end
