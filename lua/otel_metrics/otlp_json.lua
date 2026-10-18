-- OTLP/HTTP JSON encoding of a metrics batch (ExportMetricsServiceRequest).
-- Per the OTLP JSON mapping: lowerCamelCase field names, enums as numbers,
-- 64-bit integers (timestamps, counts) as decimal strings.

local M = OTelMetrics
local Json = {}
M.OtlpJson = Json

local string_format, string_gsub, string_byte = string.format, string.gsub, string.byte
local table_concat = table.concat
local math_floor = math.floor
local tostring, tonumber, type = tostring, tonumber, type
local IsFinite = M.IsFinite

local MAX_SAFE_INTEGER = 9007199254740991

local escapes = {
	['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escapeChar(c)
	return escapes[c] or string_format("\\u%04x", string_byte(c))
end

local function quote(s)
	return '"' .. string_gsub(s, '[%c"\\]', escapeChar) .. '"'
end
Json.Quote = quote

--- Shortest decimal form that reads back as the same double.
local function number(v)
	local s = string_format("%.15g", v)
	if tonumber(s) ~= v then s = string_format("%.17g", v) end
	return s
end
Json.Number = number

local function anyValue(v)
	local t = type(v)
	if t == "string" then return '{"stringValue":' .. quote(v) .. "}" end
	if t == "boolean" then return v and '{"boolValue":true}' or '{"boolValue":false}' end
	if t == "number" then
		if v == math_floor(v) and v >= -MAX_SAFE_INTEGER and v <= MAX_SAFE_INTEGER then
			return '{"intValue":"' .. string_format("%.0f", v) .. '"}'
		end
		return '{"doubleValue":' .. number(v) .. "}"
	end
	return '{"stringValue":' .. quote(tostring(v)) .. "}"
end

-- Attribute lists are immutable once a series exists, so their JSON is cached.
local attributeCache = setmetatable({}, { __mode = "k" })

local function attributes(list)
	if #list == 0 then return nil end
	local cached = attributeCache[list]
	if cached then return cached end
	local parts = {}
	for i = 1, #list do
		local kv = list[i]
		parts[i] = '{"key":' .. quote(kv[1]) .. ',"value":' .. anyValue(kv[2]) .. "}"
	end
	cached = '"attributes":[' .. table_concat(parts, ",") .. "]"
	attributeCache[list] = cached
	return cached
end

local function invalid()
	M.Stats.invalidPoints = M.Stats.invalidPoints + 1
end

--- batch = { resource = attrs, startTime = unix, time = unix, zeroTime = unix,
---          scopes = { { name, version, metrics } } }
--- A sum or histogram point with p.zero is preceded by the same point with
--- value zero at zeroTime.
function Json.EncodeMetrics(batch)
	local buf, n = {}, 0
	local function put(s)
		n = n + 1
		buf[n] = s
	end

	local now = M.FormatUnixNano(batch.time)
	local start = M.FormatUnixNano(batch.startTime)
	local withStart = '"startTimeUnixNano":"' .. start .. '","timeUnixNano":"' .. now .. '"'
	local timeOnly = '"timeUnixNano":"' .. now .. '"'
	local atZero = batch.zeroTime
		and '"startTimeUnixNano":"' .. start .. '","timeUnixNano":"' .. M.FormatUnixNano(batch.zeroTime) .. '"'

	local function openPoint(p, times)
		put("{")
		local attrs = attributes(p.attrs)
		if attrs then
			put(attrs)
			put(",")
		end
		put(times)
	end

	put('{"resourceMetrics":[{"resource":{')
	put(attributes(batch.resource) or '"attributes":[]')
	put('},"scopeMetrics":[')

	for si = 1, #batch.scopes do
		local scope = batch.scopes[si]
		if si > 1 then put(",") end
		put('{"scope":{"name":')
		put(quote(scope.name))
		if scope.version ~= "" then
			put(',"version":')
			put(quote(scope.version))
		end
		put('},"metrics":[')

		for mi = 1, #scope.metrics do
			local m = scope.metrics[mi]
			if mi > 1 then put(",") end
			put('{"name":')
			put(quote(m.name))
			if m.description ~= "" then
				put(',"description":')
				put(quote(m.description))
			end
			if m.unit ~= "" then
				put(',"unit":')
				put(quote(m.unit))
			end

			local points, first = m.points, true
			if m.kind == "histogram" then
				local bounds, zeros = {}, {}
				for i = 1, #m.bounds do bounds[i] = number(m.bounds[i]) end
				for i = 1, #m.bounds + 1 do zeros[i] = '"0"' end
				local boundsJson = ',"explicitBounds":[' .. table_concat(bounds, ",") .. "]}"
				local zeroCounts = ',"count":"0","sum":0,"bucketCounts":[' .. table_concat(zeros, ",") .. "]"
				put(',"histogram":{"aggregationTemporality":2,"dataPoints":[')
				for pi = 1, #points do
					local p = points[pi]
					if atZero and p.zero then
						if first then first = false else put(",") end
						openPoint(p, atZero)
						put(zeroCounts)
						put(boundsJson)
					end
					if first then first = false else put(",") end
					openPoint(p, withStart)
					put(',"count":"' .. string_format("%.0f", p.count) .. '"')
					if IsFinite(p.sum) then put(',"sum":' .. number(p.sum)) end
					local counts = {}
					for i = 1, #p.counts do counts[i] = '"' .. string_format("%.0f", p.counts[i]) .. '"' end
					put(',"bucketCounts":[' .. table_concat(counts, ",") .. "]")
					put(boundsJson)
				end
				put("]}}")
			else
				local isSum = m.kind == "sum"
				if isSum then
					put(',"sum":{"aggregationTemporality":2,"isMonotonic":' .. (m.monotonic and "true" or "false") .. ',"dataPoints":[')
				else
					put(',"gauge":{"dataPoints":[')
				end
				local times = isSum and withStart or timeOnly
				for pi = 1, #points do
					local p = points[pi]
					if IsFinite(p.value) then
						if isSum and atZero and p.zero then
							if first then first = false else put(",") end
							openPoint(p, atZero)
							put(',"asDouble":0}')
						end
						if first then first = false else put(",") end
						openPoint(p, times)
						put(',"asDouble":' .. number(p.value) .. "}")
					else
						invalid()
					end
				end
				put("]}}")
			end
		end
		put("]}")
	end
	put("]}]}")
	return table_concat(buf)
end
