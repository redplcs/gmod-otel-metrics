-- Physics simulation time, sampled every tick.

local M = OTelMetrics

local C = {
	Name = "physics",
	Description = "Duration of physics simulation steps.",
	DefaultEnabled = true,
}

function C:IsSupported()
	return physenv ~= nil and physenv.GetLastSimulationTime ~= nil
end

function C:Start(ctx)
	self.steps = ctx.Meter:CreateHistogram("gmod.physics.step.duration", {
		unit = "s",
		description = "Duration of the last physics simulation step, sampled every tick.",
		boundaries = { 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25 },
	}):Bind()
end

function C:OnTick()
	local t = physenv.GetLastSimulationTime()
	if t and t >= 0 then self.steps:Record(t) end
end

M.Collectors.Register(C)
