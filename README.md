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


## Farm completion and live bot visibility

Each farm shows capacity 2,645 and harvest progress `(2645 - standing target trees) / 2645`, clamped to 0..100%. This is cleared capacity, not a count of server-confirmed harvest actions. Zero standing target trees shows Harvest done; PNB/storage may still be running. A script pass finishing with trees remaining never forces the percentage to 100%. The Lua sender does a final full scan and emits `farm_finished` once when its farm pass finishes. Existing scans also receive progress calculations without waiting for a new Lua version.

Stale bot rows are omitted from the live API list and dashboard. Their stored reports/history and the latest farm/storage observations remain retained. A new report brings a bot back automatically. This hides stale reports; it does not delete database history or remove game accounts.


## Finished and unassigned bots

Finished bots perform final inventory cleanup before marking their job finished: remaining farm blocks are processed by the existing PNB loop, and final storage deposits every remaining carried inventory item, including singleton seeds. This final storage visit does not unnecessarily warp back to the farm. Gems are a separate balance, not droppable inventory items. If an item cannot be deposited, cleanup stays pending rather than falsely declaring an empty inventory.

After cleanup the bot leaves the world, disables auto-reconnect and disconnects. Waiting for a leader, partner or free farm does not connect the account. A real new assignment clears idle state and initiates connection once; normal connection recovery then applies. A leader keeps its claim until the follower reports DONE, even if that follower is still offline waiting to begin. Idle/offline cached world names no longer block other pairs.

Every bot's first scan of a world in a run logs and emits `first_world_scan`: zero target trees means Harvest done; otherwise work remains. This is not an initial census of all worlds before farming: each pair claims, scans and processes its world before taking the next one. Cleared farm names are shared in the existing custom-status claim board, scoped by seed ID, so pairs skip cleared worlds for the rest of the run. Once all farms are cleared, bots stay disconnected. Restart all bot scripts for a new planted run to reset this in-memory cleared-world registry. No additional files or network service are used for the claim board.

`tests/idle_cleanup.lua` checks final one-seed/extra-item storage, leave-before-disconnect, no idle connects and assignment-only reconnect. `tests/claim_board.lua` checks shared cleared-world status and waiting for an actual follower acknowledgement.

Startup correction: unassigned/startup waits leave and disconnect without a final inventory-drain trip. Starting inventory is preserved for the next assigned farm. All-item storage remains mandatory when completing an actual farm job. The idle cleanup test covers both paths.


Queue-end cleanup clarification: finishing one farm no longer forces an inventory drain or disconnect. Bots leave that farm, retain sub-limit seeds (e.g. 44), and proceed to the next assignment. Normal SEED_LIMIT storage trips remain unchanged. Final all-item storage and disconnection occur only when the leader cannot claim a world. Leaders publish WAIT for that definite decision; followers do not mistake temporary IDLE or the previous CLAIM during handoff for queue completion. A follower receiving WAIT drains leftovers and goes offline. `tests/queue_cleanup.lua` covers this distinction. This clarification supersedes the earlier per-farm cleanup description.


Seed-only cleanup correction: storage sends ONLY the configured Toilet Seed (107). Unrelated inventory items are left alone; earlier all-item-cleanup text is superseded. Normal threshold trips and queue-end leftover deposits both follow this rule. The bot waits its native drop interval after facing right, revalidates world/position/capacity, and sends one drop. It then waits for an inventory decrease observed online in storage, without advancing to another tile or resending an uncertain drop. Full targets detected before sending are skipped normally. An unresolved receipt is logged as pending, not misclassified as a full tile or successful storage; it can remain pending if the server never acknowledges the drop. `tests/drop_receipt.lua` covers delayed receipt, false zero inventory in EXIT, settled facing and single-send behavior.
