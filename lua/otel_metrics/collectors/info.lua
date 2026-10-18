-- Server information and map start time.

local M = OTelMetrics

local C = {
	Name = "info",
	Description = "Map, gamemode, game version and map start time.",
	DefaultEnabled = true,
}

function C:Start(ctx)
	local meter = ctx.Meter

	meter:CreateObservableGauge("gmod.server.info", function(o)
		o:Observe(1, {
			map = game.GetMap(),
			gamemode = engine.ActiveGamemode(),
			["gmod.version"] = tostring(VERSIONSTR or VERSION or "unknown"),
			["gmod.branch"] = tostring(BRANCH or "unknown"),
			arch = jit and jit.arch or "unknown",
		})
	end, { description = "Server information in attributes; the value is always 1." })

	meter:CreateObservableGauge("gmod.map.start_time", function(o)
		o:Observe(M.MapStartTime or M.StartTime)
	end, { unit = "s", description = "Unix time when the current map started." })
end

M.Collectors.Register(C)
