# Security Policy

OTel Metrics runs on game servers, handles input from players and can hold the credentials for your metrics backend, so a bug in it can be a security hole. If you find one, please report it privately, so that servers can update before the details become public.

## What to report

For example:

- a player gets the value of `otel_metrics_headers`, which often holds a token for the metrics backend;
- a player changes the addon's settings or runs its commands, which work only from the server console and RCON;
- a player makes the addon use memory or send data without bound, for example by getting past `otel_metrics_max_series` or the length limit on attribute values;
- a player breaks the payload or adds data of their own to it, such as extra attributes or resource attributes;
- a player crashes or freezes the server through the addon;
- the addon sends data anywhere other than `otel_metrics_endpoint`, or sends data about players that the README doesn't list, such as SteamIDs, IP addresses or names.

Not covered by this policy:

- bugs in Garry's Mod, Steam, Grafana Alloy, the OpenTelemetry Collector, Prometheus or Grafana themselves; please report those to their developers;
- made-up client Lua errors: the server can only count what clients report, so a modified client can add errors and addon names of its own, within the series limit;
- server misconfiguration, such as a receiver that anyone can reach without authentication, or an `http://` endpoint on another machine across the internet;
- attacks that need the RCON password, the right to run console commands or Lua on the server (for example through an admin mod), an addon of their own on the server, or access to the server's files.

## Supported versions

Only the latest version gets security fixes. The Steam Workshop always serves the latest version; if you installed the addon manually, update it from this repository.

## How to report

Please don't post security issues in public issues, discussions or Workshop comments.

Report them privately through GitHub: [Report a vulnerability](https://github.com/redplcs/gmod-otel-metrics/security/advisories/new). The same button is on the repository's security page. Only you and the maintainer see the report.

Please include:

- the versions of OTel Metrics and Garry's Mod, and the receiver you send to;
- the steps to reproduce the problem, and what happened compared with what you expected;
- the relevant settings (`otel_metrics_*`) and log lines, without the value of `otel_metrics_headers`.

## What happens next

You'll get a reply within 7 days. Once the problem is confirmed, the fix is published on the Steam Workshop and GitHub, followed by a security advisory that describes the problem. The advisory credits you, unless you'd rather stay anonymous.

Please keep the details private until the fix is released. If 90 days pass without a fix, you're free to disclose the issue.
