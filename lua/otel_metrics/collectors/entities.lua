-- Entities: total count and networked entities (edicts) against the limit.

local M = OTelMetrics

local C = {
	Name = "entities",
	Description = "Entity and edict counts.",
	DefaultEnabled = true,
}

function C:Start(ctx)
	local meter = ctx.Meter
	local limit = 2 ^ (tonumber(MAX_EDICT_BITS) or 13)

	meter:CreateObservableGauge("gmod.entity.count", function(o)
		o:Observe(ents.GetCount())
	end, { unit = "{entity}", description = "Existing entities." })

	meter:CreateObservableGauge("gmod.edict.count", function(o)
		o:Observe(ents.GetEdictCount())
	end, { unit = "{edict}", description = "Networked entities (edicts)." })

	meter:CreateObservableGauge("gmod.edict.limit", function(o)
		o:Observe(limit)
	end, { unit = "{edict}", description = "Edict limit; ents.Create starts failing somewhat below it." })
end

M.Collectors.Register(C)
