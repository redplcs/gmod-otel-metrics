# OTel Metrics

<img src="workshop/icon.jpg" alt="OTel Metrics icon" width="128" align="right">

Server metrics for Garry's Mod over OpenTelemetry. Tick rate, frame times, players, connections, Lua errors and more, pushed every 15 seconds over OTLP/HTTP to Grafana Alloy, the OpenTelemetry Collector or Prometheus.

## Features

- **Pure Lua, no dependencies.** No binary modules and no other addons. Works with any gamemode.
- **Push instead of scrape.** Lua can't open a port, so instead of serving `/metrics` the addon sends OTLP/HTTP (JSON) to a receiver next to the server.
- **Server performance:** ticks, frame times, the longest frame, how long the game stood still, physics step times.
- **Players:** humans and bots online, ping, packet loss, timeouts.
- **Connections:** time to join (downloads included), disconnect reasons, session length, player-hours.
- **Lua errors by addon**, on the server and on clients, and Lua memory.
- **Entities and edicts**, with the edict limit to compare against.
- **Nothing is lost when a request fails.** Counters and histograms are cumulative, so the next successful export carries the totals.
- **Server-side only.** Nothing is sent to clients: no `AddCSLuaFile`, no net messages, no network strings.
- **Stays out of the game's way.** Its hooks never return a value, and an error inside a collector is counted and logged instead of breaking the hook.
- **Modular.** Collectors can be switched off one by one, and other addons can add their own metrics.
- **Ready-made Grafana dashboards and alert rules** in [`grafana`](grafana).

## Requirements

- A dedicated server. In single player and on a listen server the addon stays off.
- An OTLP/HTTP receiver that accepts JSON: [Grafana Alloy](https://grafana.com/docs/alloy/latest/), the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) or Prometheus 3.
- `-allowlocalhttp` on the srcds command line if the receiver runs on the same machine or in a private network. Without it GMod refuses HTTP requests to `localhost`, `127.0.0.1`, `10.x.x.x`, `192.168.x.x` and other local addresses.
- `sv_hibernate_think 1` is recommended. Without it an empty server stops `Think`, `Tick` and timers, so no metrics are sent until someone joins.

## Installation

1. Add [OTel Metrics from the Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3823660148) to the collection your server mounts with `host_workshop_collection`. Or download this repository (**Code → Download ZIP**) and extract it into `garrysmod/addons/`, or clone it there:

   ```sh
   git clone https://github.com/redplcs/gmod-otel-metrics garrysmod/addons/gmod-otel-metrics
   ```

   The game only uses the `lua` folder, and only that folder is in the Workshop. The Alloy fragment and the Grafana dashboards are here.

2. If the receiver runs on the same machine, add `-allowlocalhttp` to the srcds command line.

3. Set these console variables in the server config, so they survive a restart:

   ```
   sv_hibernate_think 1
   otel_metrics_instance_id "my-server"
   ```

   `otel_metrics_instance_id` becomes the `instance` label. Without it the server's IP and port are used.

4. Set up a [receiver](#receivers).

5. Restart the server fully; a map change is not enough. The first line appears at startup, the second with the first export about 15 seconds later:

   ```
   [OTel Metrics] v0.1.3 loaded.
   [OTel Metrics] Exporting to http://127.0.0.1:4318/v1/metrics every 15 s.
   ```

Within half a minute `otel_metrics_status` in the server console should report `result ok`, and `gmod_server_ticks_total` shows up in Prometheus or Grafana. To look at the metrics, import the [Grafana dashboards](#grafana-dashboards).

## Receivers

By default the addon sends to `http://127.0.0.1:4318/v1/metrics`, the standard OTLP/HTTP port on the same machine. Any receiver that accepts OTLP/HTTP with JSON works.

### Grafana Alloy

Append [`alloy/otel_metrics.alloy`](alloy/otel_metrics.alloy) to your Alloy configuration (`/etc/alloy/config.alloy` on Linux) and reload Alloy with `systemctl reload alloy`:

```hcl
otelcol.receiver.otlp "gmod" {
  http {
    endpoint = "127.0.0.1:4318"
  }

  output {
    metrics = [otelcol.processor.batch.gmod.input]
  }
}

otelcol.processor.batch "gmod" {
  output {
    metrics = [otelcol.exporter.prometheus.gmod.input]
  }
}

otelcol.exporter.prometheus "gmod" {
  forward_to = [prometheus.remote_write.metrics_service.receiver]
}
```

It receives on `127.0.0.1:4318` and passes the metrics to an existing `prometheus.remote_write` component. `metrics_service` is the name Grafana Cloud uses in its Alloy configuration; change `forward_to` if yours is named differently.

### OpenTelemetry Collector

Enable the OTLP receiver over HTTP and add `otlp` to the receivers of a metrics pipeline:

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 127.0.0.1:4318
```

### Prometheus

Prometheus 3 accepts OTLP itself. Start it with `--web.enable-otlp-receiver` and point the addon at it:

```
otel_metrics_endpoint "http://127.0.0.1:9090/api/v1/otlp/v1/metrics"
```

### Names in Prometheus

Alloy, the OpenTelemetry Collector and Prometheus convert names the same way by default: dots become underscores, the unit is appended, and counters get `_total`. So `gmod.server.ticks` becomes `gmod_server_ticks_total`, and the histogram `gmod.server.frame.duration` becomes `gmod_server_frame_duration_seconds_bucket`, `_sum` and `_count`. Attribute names change the same way: `player.kind` becomes `player_kind`.

The resource attribute `service.name` (`otel_metrics_service_name`, `gmod` by default) becomes the `job` label, and `service.instance.id` (`otel_metrics_instance_id`) becomes `instance`. Other resource attributes go to the `target_info` metric.

## Grafana dashboards

The [`grafana/dashboards`](grafana/dashboards) folder has six dashboards built on this addon's metrics alone:

| Dashboard | What it shows |
|---|---|
| Fleet overview<br>`gmod-fleet.json` | Every server at a glance: which ones report, addon versions, players, Lua errors, a table of servers and the slowest ones. |
| Overview<br>`gmod-overview.json` | One server: performance, players, Lua and the exporter, each linking to its details. |
| Performance<br>`gmod-performance.json` | Simulation speed, ticks per second, game time lost, frame times, physics and entities. |
| Players<br>`gmod-players.json` | Players online, joins and disconnects, time to join, sessions, player-hours, ping and packet loss. |
| Lua<br>`gmod-lua.json` | Lua errors by addon and realm, and Lua memory. |
| Exporter<br>`gmod-exporter.json` | The addon itself: delivery, export results, payload size, encoding time and collectors. |

To import them, open **Dashboards → New → Import** in Grafana and upload each file. To update them later, import the new files and choose **Overwrite**: the UIDs stay the same.

Every dashboard has the same variables at the top: **Data source**, **Job** and **Server** (the `job` and `instance` labels), and **Export interval**, which should match `otel_metrics_interval`. The links at the top switch between the dashboards and keep the time range; in the fleet overview, a click on a server opens its overview.

Tested with Grafana Cloud. The hourly and daily bars use a negative `offset`, which needs Prometheus 2.33 or later.

### Alerts

[`grafana/alerts.yml`](grafana/alerts.yml) has four alert rules in the Prometheus rule file format:

| Alert | Fires when |
|---|---|
| `GmodNoData` | No metrics have arrived for 5 minutes. |
| `GmodSimulationSlow` | The server has simulated less than 90% of its tick rate for 5 minutes. |
| `GmodFreeze` | The game stood still for more than 5 seconds within 5 minutes. |
| `GmodEdictsNearLimit` | Over 90% of edicts are in use. |

In Grafana, open **Alerting → Alert rules**, choose **Import to Grafana-managed rules** and pick **Prometheus YAML file** as the source. In Prometheus, add the file to `rule_files`. `GmodNoData` is labeled `severity: critical`, the others `warning`.

Set `sv_hibernate_think 1`: otherwise an empty server stops sending metrics, and `GmodNoData` fires until someone joins.

## Settings

| Setting | Default | Description |
|---|---|---|
| `otel_metrics_enabled` | `1` | Collect and export metrics. `0` stops the collectors and the export timer. |
| `otel_metrics_endpoint` | `http://127.0.0.1:4318/v1/metrics` | Full URL of the OTLP/HTTP metrics endpoint. Alloy and the OpenTelemetry Collector use `/v1/metrics`, Prometheus `/api/v1/otlp/v1/metrics`. |
| `otel_metrics_headers` | | Extra HTTP headers as `Name: value; Name2: value2`, for example for authentication. Protected like `sv_password`: the value is never sent to clients, and `otel_metrics_status` shows only how many headers are set. |
| `otel_metrics_interval` | `15` | Seconds between exports, from 5 to 3600. |
| `otel_metrics_service_name` | `gmod` | `service.name`: the `job` label in Prometheus. |
| `otel_metrics_instance_id` | | `service.instance.id`: the `instance` label. Empty: the server's IP and port. |
| `otel_metrics_resource_attributes` | | Extra resource attributes as `key=value,key2=value2`. |
| `otel_metrics_max_series` | `200` | Series limit per metric. Further attribute combinations are merged into one series labeled `otel_metric_overflow="true"`. |
| `otel_metrics_frame_buckets` | | Bounds of the frame time histogram in seconds, comma-separated. Empty: 1.155, 1.65, 2.475, 3.3, 4.95, 8.25 and 16.5 ticks, then 1, 2.5 and 5 seconds. At 33 tick that is `0.035, 0.05, 0.075, 0.1, 0.15, 0.25, 0.5, 1, 2.5, 5`, at 66 tick `0.0173, 0.0248, 0.0371, 0.0495, 0.0743, 0.124, 0.248, 1, 2.5, 5`. A change starts the histogram over. |
| `otel_metrics_collector_<name>` | `1` | Turns a collector on or off: `server`, `physics`, `lua`, `players`, `connections`, `entities`, `info`. |

Set them in the server config, from the console or over RCON. They take effect without a restart.

## Commands

These work only from the server console and RCON.

| Command | What it does |
|---|---|
| `otel_metrics_status` | Shows the endpoint, the result of the last export, the payload size, failures and the state of each collector. |
| `otel_metrics_export_now` | Collects and sends metrics right away, even during the pause after errors. |
| `otel_metrics_dump` | Writes the last payload to `data/otel_metrics/last_payload.json`, to see exactly what is sent. |

```
[OTel Metrics] v0.1.3, running
  endpoint: http://127.0.0.1:4318/v1/metrics, every 15 s
  headers: none
  last export: 2026-10-18 12:00:15 (4 s ago), result ok, HTTP 200
  last payload: 10382 bytes, 44 points
  consecutive failures: 0, next attempt in 0 s
  dropped series: 0, invalid points: 0
  collectors: server=on physics=on lua=on players=on connections=on entities=on info=on
  sv_hibernate_think: 1
```

A collector shows as `off` when it is switched off, `unsupported` when the server lacks what it needs, and `failed` after repeated errors.

## Metrics

Each metric is listed with its OTLP name and its name in Prometheus. Metrics with nothing to report yet appear after the first event: `gmod_lua_errors_total` after the first error, `gmod_player_disconnects_total` after the first disconnect. A new series is sent with a zero just before its first value, so `rate()` and `increase()` count the first event too. Counters start from zero on every map change; `rate()` and `increase()` handle that.

### Server performance (`server`)

| Metric | Type | Description |
|---|---|---|
| `gmod.server.ticks`<br>`gmod_server_ticks_total` | counter | Ticks simulated since the collector started. `rate()` of it is the actual tick rate. |
| `gmod.server.tick.interval`<br>`gmod_server_tick_interval_seconds` | gauge | Configured tick interval, 1 / tickrate. |
| `gmod.server.frame.duration`<br>`gmod_server_frame_duration_seconds` | histogram | Real time between server frames (`Think`). At 33 tick a normal frame takes about 30 ms. |
| `gmod.server.frame.duration.max`<br>`gmod_server_frame_duration_max_seconds` | gauge | Longest frame since the previous export. |
| `gmod.server.simulation.lag`<br>`gmod_server_simulation_lag_seconds_total` | counter | How long the game stood still: real time the simulation fell behind and never caught up. Up to one tick of jitter is not counted. |

### Physics (`physics`)

| Metric | Type | Description |
|---|---|---|
| `gmod.physics.step.duration`<br>`gmod_physics_step_duration_seconds` | histogram | Duration of the last physics simulation step, sampled every tick. |

### Lua (`lua`)

| Metric | Type | Description |
|---|---|---|
| `gmod.lua.memory.usage`<br>`gmod_lua_memory_usage_bytes` | gauge | Memory used by the server Lua state. |
| `gmod.lua.errors`<br>`gmod_lua_errors_total` | counter | Lua errors. `realm` is `server` or `client`. `addon` is the addon title GMod reports, otherwise the addon folder from the error path (`gamemode:<name>` for gamemodes, `base` for GMod's own `lua/includes`), otherwise `unknown`. |

Errors raised with `Error` or `ErrorNoHalt` are not counted, and GMod limits how many client errors reach the server. The text of each error is still in the console.

### Players (`players`)

| Metric | Type | Description |
|---|---|---|
| `gmod.player.count`<br>`gmod_player_count` | gauge | Players on the server. `player.kind` is `human` or `bot`. |
| `gmod.player.limit`<br>`gmod_player_limit` | gauge | Player slots (`maxplayers`). |
| `gmod.player.ping`<br>`gmod_player_ping_seconds` | histogram | Ping of human players, one sample per player per export. |
| `gmod.player.packet_loss.max`<br>`gmod_player_packet_loss_max_ratio` | gauge | Highest packet loss among human players, from 0 to 1. |
| `gmod.player.timing_out`<br>`gmod_player_timing_out` | gauge | Human players the server hasn't heard from for more than 4 seconds. |

### Connections (`connections`)

| Metric | Type | Description |
|---|---|---|
| `gmod.player.connections`<br>`gmod_player_connections_total` | counter | Connections that reached the server, bots excluded. |
| `gmod.player.join.duration`<br>`gmod_player_join_duration_seconds` | histogram | Time from connecting to being fully in the game, content download included. |
| `gmod.player.disconnects`<br>`gmod_player_disconnects_total` | counter | Disconnects. `disconnect.reason` is `client` (left on their own), `timeout`, `kicked`, `banned`, `shutdown`, `aborted` (left before they were fully in the game) or `other`. |
| `gmod.player.session.duration`<br>`gmod_player_session_duration_seconds` | histogram | Session length at disconnect. |
| `gmod.player.time`<br>`gmod_player_time_seconds_total` | counter | Time all human players spent on the server, added up (player-seconds). |

### Entities (`entities`)

| Metric | Type | Description |
|---|---|---|
| `gmod.entity.count`<br>`gmod_entity_count` | gauge | Existing entities. |
| `gmod.edict.count`<br>`gmod_edict_count` | gauge | Networked entities (edicts). |
| `gmod.edict.limit`<br>`gmod_edict_limit` | gauge | Edict limit, 8192. `ents.Create` starts failing somewhat before it is reached. |

### Server info (`info`)

| Metric | Type | Description |
|---|---|---|
| `gmod.server.info`<br>`gmod_server_info` | gauge | Always 1. The information is in the attributes `map`, `gamemode`, `gmod.version`, `gmod.branch` and `arch`. |
| `gmod.map.start_time`<br>`gmod_map_start_time_seconds` | gauge | Unix time when the current map started. |

### Self-monitoring

Always exported while the addon runs.

| Metric | Type | Description |
|---|---|---|
| `gmod.exporter.exports`<br>`gmod_exporter_exports_total` | counter | Export attempts. `result` is `ok`, `retryable` (HTTP 429 or 5xx), `rejected` (other HTTP errors), `network` (no response), `skipped` (the previous request was still in flight) or `error` (the payload could not be built). |
| `gmod.exporter.payload.size`<br>`gmod_exporter_payload_size_bytes` | gauge | Size of the previous payload. |
| `gmod.exporter.serialize.duration`<br>`gmod_exporter_serialize_duration_seconds` | gauge | Time spent encoding the previous payload. |
| `gmod.exporter.series`<br>`gmod_exporter_series` | gauge | Data points in the previous payload. |
| `gmod.exporter.series.dropped`<br>`gmod_exporter_series_dropped_total` | counter | Attribute combinations merged into an overflow series, by `instrument`. |
| `gmod.exporter.points.invalid`<br>`gmod_exporter_points_invalid_total` | counter | Measurements dropped as NaN, infinite or negative. |
| `gmod.exporter.points.rejected`<br>`gmod_exporter_points_rejected_total` | counter | Data points the receiver reported as rejected. |
| `gmod.collector.duration`<br>`gmod_collector_duration_seconds` | gauge | Time each `collector` spent in the previous collection. |
| `gmod.collector.errors`<br>`gmod_collector_errors_total` | counter | Errors inside each `collector`. |
| `gmod.collector.enabled`<br>`gmod_collector_enabled` | gauge | 1 if the `collector` is running, 0 if not. |

## Example queries

| Question | PromQL |
|---|---|
| Actual tick rate | `rate(gmod_server_ticks_total[1m])` |
| 99th percentile frame time | `histogram_quantile(0.99, sum by (le) (rate(gmod_server_frame_duration_seconds_bucket[5m])))` |
| How long the game stood still in the last hour | `increase(gmod_server_simulation_lag_seconds_total[1h])` |
| Players online | `gmod_player_count{player_kind="human"}` |
| Player-hours per day | `increase(gmod_player_time_seconds_total[1d]) / 3600` |
| Lua errors per addon in the last hour | `sum by (addon) (increase(gmod_lua_errors_total[1h]))` |
| Share of edicts in use | `gmod_edict_count / gmod_edict_limit` |
| Map uptime | `time() - gmod_map_start_time_seconds` |

## How it works

- Every `otel_metrics_interval` seconds the addon collects all metrics and sends them in one `POST` with GMod's `HTTP()`. The interval is real time, checked every frame: GMod timers follow game time and would slow down together with an overloaded server. At most one request is in flight: if the previous one hasn't been answered yet, the export is skipped.
- Counters and histograms are cumulative: every request carries the totals since the map started. A lost request loses no data, so nothing is queued or sent twice.
- A series sent for the first time gets a zero point just after the previous collection, so the receiver sees it start from zero. The zero point is sent again only if the receiver answered 429 or 5xx: after a network error the request may have arrived, and a second zero would read as a counter reset.
- After a failed request the addon waits twice the interval, twice as long again after each further failure, up to 5 minutes, and at least as long as `Retry-After` asks. After HTTP 401, 403 or 404 it waits 5 minutes, since those need a configuration fix.
- The first export goes out after the map has loaded.
- Settings are read when they are used, so values set after the addon has started apply too. The endpoint, the interval and `sv_hibernate_think` are reported at the first export for the same reason.
- Most values are read once per export. Frame times are measured every frame, physics every tick.
- Each collector is isolated. Its hooks never return a value, so they can't change game behavior, and errors inside it are counted in `gmod_collector_errors_total` and logged at most once a minute. A collector that fails 10 times within 60 seconds is switched off.
- Without `sv_hibernate_think 1` an empty server stops `Think`, `Tick` and timers, so nothing is sent until someone joins. That gap is counted neither as a frame nor as lag.
- The addon tries one last export when the server shuts down.

## Logs

Everything goes to the server console with the `[OTel Metrics]` prefix. Repeated warnings are rate-limited.

| Message | What to do |
|---|---|
| `The request to 127.0.0.1 failed (...). GMod blocks HTTP to local and private addresses unless srcds runs with -allowlocalhttp.` | Add `-allowlocalhttp` to the srcds command line, and check that the receiver is running. |
| `The receiver answered HTTP 404: check the path in otel_metrics_endpoint` | Alloy and the OpenTelemetry Collector use `/v1/metrics`, Prometheus `/api/v1/otlp/v1/metrics`. |
| `The receiver answered HTTP 401` or `403` | Check `otel_metrics_headers`. |
| `The receiver rejected N data points` | The request was accepted, but the receiver dropped some points. Its explanation follows. |
| `sv_hibernate_think is 0` | Set `sv_hibernate_think 1`. |
| `Collector 'name' disabled after 10 errors in 60 s.` | The collector keeps failing; the errors before this line say why. Turn it back on with `otel_metrics_collector_<name> 0`, then `1`. |

To see what is sent, run `otel_metrics_dump`. To see what arrives at Alloy, uncomment the `otelcol.exporter.debug` block in `alloy/otel_metrics.alloy`.

## For developers

Other addons can add their own metrics. Register a collector once all addons have loaded, for example in `Initialize`:

```lua
hook.Add("Initialize", "myaddon.metrics", function()
	if not OTelMetrics then return end -- OTel Metrics is not installed

	OTelMetrics.RegisterCollector({
		Name = "myaddon",
		Description = "Purchases and money in circulation.",

		Start = function(self, ctx)
			local purchases = ctx.Meter:CreateCounter("myaddon.purchases", {
				unit = "{purchase}",
				description = "Items bought, by category.",
			})

			ctx:AddHook("MyAddonPurchase", function(ply, item)
				purchases:Add(1, { category = item.Category })
			end)

			ctx.Meter:CreateObservableGauge("myaddon.money", function(observer)
				observer:Observe(MyAddon.GetTotalMoney())
			end, { description = "Money held by all players." })
		end,
	})
end)
```

The collector gets its own switch, `otel_metrics_collector_myaddon`, and the same isolation as the built-in ones. Hooks, game events, observable callbacks and detours registered through `ctx` are removed when it stops.

| Collector field | Description |
|---|---|
| `Name` | Required. Letters, digits and underscores. |
| `Start(self, ctx)` | Required. Creates instruments and hooks. |
| `Stop(self)` | Called when the collector is switched off. |
| `OnTick(self, now)` | Called every tick; `now` is `SysTime()`. |
| `OnCollect(self)` | Called right before each export: the place to sample values. |
| `IsSupported(self)` | Return `false` to skip the collector on this server. |
| `DefaultEnabled` | `false` to ship the collector switched off. |
| `Description` | A short description. |

| Context | Description |
|---|---|
| `ctx.Meter` | Creates instruments, see below. |
| `ctx:AddHook(event, fn)` | `hook.Add` whose return value is discarded and whose errors are counted. |
| `ctx:ListenGameEvent(event, fn)` | `gameevent.Listen` plus `ctx:AddHook`. |
| `ctx:Detour(tbl, key, wrap)` | Replaces `tbl[key]` with `wrap(original)` until the collector stops. |
| `ctx.Config`, `ctx.Log` | Settings and logging: `ctx.Log:Info(...)`, `ctx.Log:Warn(...)`. |

| Meter method | Instrument |
|---|---|
| `CreateCounter(name, opts)` | `:Add(value, attributes)`, for totals that only grow. |
| `CreateGauge(name, opts)` | `:Record(value, attributes)` and `:Remove(attributes)`. |
| `CreateHistogram(name, opts)` | `:Record(value, attributes)`. Needs `opts.boundaries`. |
| `CreateObservableCounter(name, callback, opts)` | `callback(observer)` runs at each export and reports the current total with `observer:Observe(value, attributes)`. |
| `CreateObservableGauge(name, callback, opts)` | The same for current values. |

`opts` takes `unit` (`"s"`, `"By"`, `"1"` or `"{item}"`), `description`, `boundaries` and `maxSeries`. Counters and histograms also have `:Bind(attributes)`: it returns an object whose `:Add(value)` or `:Record(value)` uses those attributes without looking them up each time.

Keep attribute values to a small fixed set. Every combination is a separate series, so SteamIDs or player names as attributes quickly hit `otel_metrics_max_series`.

Outside a collector, `OTelMetrics.GetMeter(name, version)` gives a meter without a switch or cleanup, `OTelMetrics.ExportNow()` sends right away, and `OTelMetrics.GetStatus()` returns the export status as a table.