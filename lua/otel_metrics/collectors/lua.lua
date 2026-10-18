-- Lua runtime: memory of the server Lua state and Lua errors by addon.

local M = OTelMetrics

--- The addon an error belongs to: the title GMod reports, else the folder in
--- the error path. Plain "lua/..." paths cannot be attributed.
local function addonOf(name, err)
	if type(name) == "string" and name ~= "" and name ~= "ERROR" then return name end
	local s = tostring(err or "")
	local folder = string.match(s, "addons/([^/]+)/")
	if folder then return folder end
	local gamemode = string.match(s, "gamemodes/([^/]+)/")
	if gamemode then return "gamemode:" .. gamemode end
	if string.find(s, "lua/includes/", 1, true) then return "base" end
	return "unknown"
end

local C = {
	Name = "lua",
	Description = "Lua memory and errors.",
	DefaultEnabled = true,
}

function C:Start(ctx)
	local meter = ctx.Meter

	meter:CreateObservableGauge("gmod.lua.memory.usage", function(o)
		o:Observe(collectgarbage("count") * 1024)
	end, { unit = "By", description = "Memory used by the server Lua state." })

	local errors = meter:CreateCounter("gmod.lua.errors", {
		unit = "{error}",
		description = "Lua errors by realm and addon.",
	})

	-- Server-side errors only; ErrorNoHalt and Error do not reach this hook.
	ctx:AddHook("OnLuaError", function(err, _, _, name)
		errors:Add(1, { realm = "server", addon = addonOf(name, err) })
	end)

	-- Client errors sent to the server; rate-limited by GMod itself.
	ctx:AddHook("OnClientLuaError", function(err, _, _, name)
		errors:Add(1, { realm = "client", addon = addonOf(name, err) })
	end)
end

M.Collectors.Register(C)
