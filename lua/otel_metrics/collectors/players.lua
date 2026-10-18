-- Players: counts and connection quality, sampled once per export.

local M = OTelMetrics

local C = {
	Name = "players",
	Description = "Player counts, ping, packet loss and timeouts.",
	DefaultEnabled = true,
}

function C:Start(ctx)
	local meter = ctx.Meter
	self.humans, self.bots, self.lossMax, self.timingOut = 0, 0, 0, 0

	self.ping = meter:CreateHistogram("gmod.player.ping", {
		unit = "s",
		description = "Player ping, one sample per player per export.",
		boundaries = { 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 1 },
	}):Bind()

	meter:CreateObservableGauge("gmod.player.count", function(o)
		o:Observe(self.humans, { ["player.kind"] = "human" })
		o:Observe(self.bots, { ["player.kind"] = "bot" })
	end, { unit = "{player}", description = "Connected players." })

	meter:CreateObservableGauge("gmod.player.limit", function(o)
		o:Observe(game.MaxPlayers())
	end, { unit = "{player}", description = "Player slots (maxplayers)." })

	meter:CreateObservableGauge("gmod.player.packet_loss.max", function(o)
		o:Observe(self.lossMax)
	end, { unit = "1", description = "Highest packet loss among players, 0..1." })

	meter:CreateObservableGauge("gmod.player.timing_out", function(o)
		o:Observe(self.timingOut)
	end, { unit = "{player}", description = "Players with no packets for more than 4 seconds." })
end

function C:OnCollect()
	local humans, bots, lossMax, timingOut = 0, 0, 0, 0
	for _, ply in ipairs(player.GetAll()) do
		if ply:IsBot() then
			bots = bots + 1
		else
			humans = humans + 1
			self.ping:Record(ply:Ping() / 1000)
			local loss = ply:PacketLoss() / 100
			if loss > lossMax then lossMax = loss end
			if ply:IsTimingOut() then timingOut = timingOut + 1 end
		end
	end
	self.humans, self.bots, self.lossMax, self.timingOut = humans, bots, lossMax, timingOut
end

M.Collectors.Register(C)
