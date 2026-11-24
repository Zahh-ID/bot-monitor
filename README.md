# Farm Monitor

Separate Next.js app using the existing MongoDB `vendindex` database. The vend-index API/server is not modified.

## Run and deploy

Node 22+ on a modern web host: `npm ci`, `npm run build`, `npm start`. Listens on port 3200, all interfaces. Development: `npm run dev`.

Set server environment variables using `.env.example`: `MONGODB_URI` (existing connection), `MONGODB_DB=vendindex`, and a separate random `MONITOR_TOKEN`. For local development, copy .env.example to .env.local and fill these settings. Deployment supplies them through server environment variables. The ignored local `.env.local` contains the generated monitor token. Enter that token in the dashboard. The browser retains it in sessionStorage, not URLs. Use HTTPS for public hosting.

## Lucifer: single script, embedded webhook sender

Configure `MONITOR` at the top of `lua/HARVEST_PNB.lua`: enable it, set `url` to `https://YOUR-DOMAIN/api/ingest`, and set `token` to the monitor token. Run the same file on bots 1..15. Use a different `agent_id` for each Lucifer installation.

The committed Lua uses example farm/storage/door settings and a blank monitor URL/token. Fill those locally and keep configured copies private. MongoDB credentials never enter Lua.

Lua starts its embedded PowerShell TLS 1.2 sender, like an OHDEAR webhook. One sender process per bot receives JSON over stdin and sends HTTP. No separate uploader script, generated snapshot files, or tokens in process command arguments. Requests time out after five seconds. HTTP delivery is best effort: writing a report to the child process is not a database acknowledgement. Pipe writes decouple normal HTTP timing but are not a formal nonblocking I/O guarantee. Each sender adds process/memory overhead.

Reports are event-driven: one when action/farm/connection changes, not once per harvest/PNB loop. No reports are sent while storing; after all drops finish there is one `storage_complete` report containing the observed storage totals. Later action/heartbeat reports omit storage. `heartbeat_seconds=300` sends a low-frequency heartbeat for unchanged activity; set 0 to disable periodic heartbeats. The dashboard stale threshold is two heartbeat intervals plus 30 seconds (minimum 120 seconds; 630 seconds with the default). Long storage visits intentionally produce no heartbeats. A blocked native call can also stop the heartbeat. Failed sender writes are backed off for 30 seconds.

Blank URL/token or `enabled=false` disables telemetry. Farming, white-door rewarp, native action delays, claim board, PNB and pre-drop position/capacity validation retain their existing behavior.

## Metrics and accuracy

- Bots: status, job, farm, world/position, carried seeds/blocks/gems, run counters, report age, latest action message and seed history.
- Farms: all configured worlds; standing/ready tree counts from whole-world scans. Latest observation wins; pair reports are never summed. Scan cache retains previous farms during travel.
- Storage: observed dropped items by ID, stack counts and observation time. Latest snapshot is counted once across bots. Observed once after each completed storage visit; no entry/drop-loop reports or forced travel.
- Harvest counts are hit attempts, not confirmed breaks. Deposits use observed inventory decreases. Counters reset when the Lua session restarts.
- Offline inventory is unknown/null. Stale reports retain last values and are excluded from live summary totals.
- No account credentials, proxy passwords, door IDs, packet dumps or script source are sent. Email-like display names become Bot N.

## Database and endpoints

Dedicated collections: `farm_monitor_bots`, `farm_monitor_observations`, `farm_monitor_history`. Existing vends/leads records remain untouched. Duplicate and older bot reports are ignored. Farm/storage freshness uses observation time, not upload time. History is one point per bot/minute with a 24-hour TTL. Latest bot records expire after 30 days. MongoDB TTL deletion is asynchronous.

Both endpoints require `Authorization: Bearer MONITOR_TOKEN`: `POST /api/ingest` accepts `{snapshots:[...]}` (100 reports / 1 MiB maximum); `GET /api/stats` returns uncached stats. The browser defaults to polling every 30 seconds, with a selectable interval, and pauses polling in hidden tabs. It avoids overlapping polling requests. Polling does not change game action delays.

## Verification

`npm test` checks validation/authentication. `RUN_MONGO_TESTS=1 npm test` uses uniquely named temporary MongoDB collections and removes only those collections. Real Mongo checks passed for duplicate/stale reports, storage deduplication and farm observation order. Production build passed. The actual embedded PowerShell code successfully POSTed to the local API and MongoDB; temporary transport records were removed. Browser login, polling and desktop/mobile layout passed. Live Lucifer telemetry and public-domain delivery remain unverified until configured.


## Vercel scaffold

Import this repository as the Vercel project root (the repository root), using the Next.js framework preset. Set MONGODB_URI, MONGODB_DB and MONITOR_TOKEN as server environment variables. The local vend environment is not available on Vercel. After deployment, set the Lua MONITOR.url to the public `/api/ingest` URL and use the same monitor token. A minimal vercel.json is included. No deployment or publishing has been performed. Actual event frequency, dashboard viewing time, CPU, memory and transfer determine free-plan usage; no unlimited/free guarantee is made.


## Full-world scan and storage placement fixes

Harvest reads every coordinate from `(0,0)` through `(world.x-1,world.y-1)` using live `getTile`, retries incomplete tile data, and logs the checked tile count. Nonempty but partial `getTilesSafe` snapshots are no longer trusted as the whole world.

Every bot begins each storage visit at the configured `(start_x,start_y)` — default `(2,21)` — scanning right, then upward when the row is full. The former second-part offset into row 11 was removed. Drop validation rejects occupied standing tiles, entry-arrival neighborhoods and nearby door/portal tiles, and checks both exact coordinates and `isInTile` immediately before sending. These are safeguards against door-position drops; the cause of any particular live drop still requires live verification. `tests/harvest_storage.lua` covers the full scan and drop-site regressions.

## Older Windows TLS fallback

If the log shows `transport_SecureChannelFailure`, install a portable non-Schannel curl build from https://curl.se/windows/. Extract the package contents so the executable is `C:\curl\bin\curl.exe`, retaining the accompanying certificate bundle. The sender prefers that executable, then curl.exe on PATH, otherwise uses PowerShell's HTTPS client. Optionally set `MONITOR.curl_path` to another executable path. No PATH edit is required for the default location.

Reload the updated Lua file. A successful curl report logs `[FarmStats] HTTP 200 (curl)`. A `curl_exit_N` reports curl's exit code. TLS certificate verification stays enabled. URL, authorization header and JSON payload are supplied over curl's standard input, not process arguments. No changes to Schannel settings or registry are made. Portable curl HTTPS delivery was tested against the public monitor endpoint; Windows Server 2012 R2 operation still needs verification on the actual server.
