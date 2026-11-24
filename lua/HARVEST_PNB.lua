-- HARVEST_PNB.lua : run one copy on each configured bot (indexes 1..15). Harvest Toilet trees, PNB the blocks, drop the seeds into the storage grid.
-- 15 bots = 7 pairs plus solo Bot 15: odd bot index = part 1, even = part 2 of pair (index+1)//2. The two bots of a pair work the SAME farm and RACE: no split
-- of the farm, whoever reaches a ready tree first harvests it. Part 1 PNBs at 3,1 and part 2 at 7,1.
-- Per farm world, in order:
--   1. harvest: every ready tree of the seed in the whole world (stand on the tree tile, hit it), until the bot carries BLOCK_LIMIT blocks or
--      no ready tree is left;
--   2. PNB: when it carries blocks and (BLOCK_LIMIT reached or nothing is left to harvest): stand on its PNB tile and run place-all / break-all /
--      collect cycles on the five tiles of the chicken layout until it has no block left; then harvest again;
--   3. seeds: whenever it carries SEED_LIMIT seeds, go to the storage world, drop them on the grid, and come back;
--   4. the world is finished when nothing ready is left AND no block is left; then the next world (and round and round the list).
-- No replanting. Optional embedded PowerShell webhook sends stats; logs remain in bot:getLog().
-- Storage: the grid is SHARED by both bots; each bot reads the dropped objects itself, every time, to see what a tile holds (stacks / items),
-- uses a tile only below the limits. Every bot starts at (2,21), scans right, then the row above.
-- Delays: harvest, place, hit and move come from THIS bot's own native intervals: bot:getInterval(index), read every time they are used (seconds
-- in the log of the interval probe). Which index is which is NOT documented: run INTERVAL_MAP_PROBE.lua, change one delay at a time in the
-- Lucifer panel, see which index moves, and fill INTERVAL_INDEX below. The other delays are the ones of your chicken script.
-- NOT verified in Lucifer: hitting a tree from its own tile (the chicken script does), the five-tile PNB layout with these two stands, dropping
-- on the grid tile in front of the bot, Tile:canHarvest(), World.x as the world width, and that seeds come from harvesting/PNB as expected.
local FARMS={"FARM01","FARM02","FARM03","FARM04","FARM05","FARM06","FARM07","FARM08"} -- replace with your farms
local MONITOR={enabled=false,url="",token="",agent_id="lucifer-main",heartbeat_seconds=300}
-- Set url to https://YOUR-MONITOR/api/ingest and token to its MONITOR_TOKEN.
-- Embedded PowerShell sender runs separately; no manual uploader or database password in Lua.
local FARM_DOOR="YOUR_FARM_DOOR"
local SEED_ID=107                 -- Toilet Seed (recipe data of CHICKEN_MASSING_ONE_FILE.lua)
local BLOCK_ID=106                -- Toilet
local BLOCK_LIMIT=180             -- yours (inventory_block_limit)
local SEED_LIMIT=100              -- yours (inventory_seed_limit)
local PARTS=2                      -- bots per farm: odd bot index = part 1 (PNB stand 3,1), even bot index = part 2 (PNB stand 7,1); a pair is (1,2) (3,4) (5,6) (7,8)
local BOT_COUNT=15                  -- 1..14 form seven pairs; bot 15 claims and works a farm solo
local PAIRS=(BOT_COUNT+1)//2        -- eight claim groups on the shared farm list
local PNB_STAND={[1]={x=3,y=1},[2]={x=7,y=1}}                   -- yours
local PNB_OFFSETS={{dx=-2,dy=-1},{dx=-1,dy=-1},{dx=0,dy=-1},{dx=1,dy=-1},{dx=2,dy=-1}} -- the five tiles of the chicken layout
local STORAGE={world="YOUR_STORAGE",door="YOUR_STORAGE_DOOR",start_x=2,end_x=98,start_y=21,min_y=1} -- yours
local WARP_RETRY_MIN_MS=10000 -- minimum interval between warp requests
local MAX_STACKS=20               -- chicken max_drop_stacks: a tile with this many stacks is full
local MAX_ITEMS=3800              -- chicken max_drop_items
-- Indexes of bot:getInterval, in the order of the Lucifer panel as you listed it (move, collect, hit, place, harvest, plant, warp, drop, trash)
-- = indexes 0..8. Only index 6 has been confirmed with the probe so far (it moved when one setting was changed, and its ~10 s base fits "warp");
-- run INTERVAL_MAP_PROBE.lua once per setting to confirm the others.
local INTERVAL_INDEX={move=0,collect=1,hit=2,place=3,harvest=4,plant=5,warp=6,drop=7,trash=8}

local bot=getBot()
assert(type(bot.index)=="number" and bot.index>=1,"bot.index is not available for this bot")
local part=(bot.index%2==1) and 1 or 2        -- odd index = part 1, even index = part 2
local pair=(bot.index+1)//2                   -- 1,2 -> pair 1; 3,4 -> pair 2; 5,6 -> pair 3; 7,8 -> pair 4
assert(bot.index%1==0 and bot.index<=BOT_COUNT,"bot index "..bot.index.." is outside configured bots 1.."..BOT_COUNT)
for _,k in ipairs({"harvest","place","hit","move","drop","warp"}) do assert(type(INTERVAL_INDEX[k])=="number","set INTERVAL_INDEX."..k.." (run INTERVAL_MAP_PROBE.lua to find it)") end
local STAND=PNB_STAND[part]

local monitorFarms={};for _,world in ipairs(FARMS) do monitorFarms[world]=true end
local telemetry={phase="waiting",scans={},first_scans={},counters={harvest_attempts=0,blocks_placed=0,pnb_hits=0,seeds_deposited=0,worlds_completed=0}}
local publishStats,observeStorage,maintainIdle
local idleDisconnected=false
local idleDisconnectAt=0
local workAutoReconnect=bot.auto_reconnect
local nativeListenEvents=listenEvents
local function eventWait(seconds)
 nativeListenEvents(seconds)
 if maintainIdle then maintainIdle() end
 if publishStats then publishStats() end
end
local function say(text)
 telemetry.last_message=tostring(text):gsub("|[%w_]+","|[hidden]"):sub(1,300)
 pcall(function() bot:getLog():append(text) end)
end
local function count(id) return bot:getInventory():getItemCount(id) end
local function tileAt(x,y) local ok,t=pcall(function() return bot:getWorld():getTile(x,y) end);if ok then return t end end
local function worldName() local ok,n=pcall(function() return bot:getWorld().name end);if ok and type(n)=="string" and n~="" then return n:upper() end end
local function nativeMs(kind) -- this bot's own native interval, in ms, read at the moment of use
 local ok,v=pcall(function() return bot:getInterval(INTERVAL_INDEX[kind]) end)
 assert(ok and type(v)=="number" and v>0 and v<60,"bot:getInterval("..tostring(INTERVAL_INDEX[kind])..") for '"..kind.."' did not return a usable number of seconds: "..tostring(v))
 return math.floor(v*1000+0.5)
end
-- Self-contained HTTP webhook transport. Secrets are sent on stdin, never command arguments.
local function jsonEncode(v)
 local t=type(v)
 if t=="nil" then return "null" elseif t=="boolean" then return v and "true" or "false"
 elseif t=="number" then return v==v and v~=math.huge and v~=-math.huge and tostring(v) or "null"
 elseif t=="string" then return '"'..v:gsub('[%z\1-\31\\"]',function(c)
  local escapes={['"']='\\"',['\\']='\\\\',['\n']='\\n',['\r']='\\r',['\t']='\\t'}
  return escapes[c] or string.format('\\u%04x',c:byte())
 end)..'"'
 elseif t=="table" then
  local out={}
  for k,x in pairs(v) do out[#out+1]=jsonEncode(tostring(k))..":"..jsonEncode(x) end
  return "{"..table.concat(out,",").."}"
 end
 return "null"
end
local function base64(bytes)
 local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
 return ((bytes:gsub('.',function(c)
  local bits='';local n=c:byte();for i=8,1,-1 do bits=bits..(n%2^i-n%2^(i-1)>0 and '1' or '0') end;return bits
 end)..'0000'):gsub('%d%d%d?%d?%d?%d?',function(bits)
  if #bits<6 then return '' end
  local n=0;for i=1,6 do n=n+(bits:sub(i,i)=='1' and 2^(6-i) or 0) end
  return alphabet:sub(n+1,n+1)
 end)..({'','==','='})[#bytes%3+1])
end
local senderCode=[[
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
[Console]::InputEncoding=New-Object System.Text.UTF8Encoding -ArgumentList $false
try {
 $configLine=[Console]::In.ReadLine()
 $config=$configLine|ConvertFrom-Json
 $uri=[Uri]$config.url
 if ($uri.Scheme -notin @('https','http')) {exit 1}
 $headers=@{Authorization=('Bearer '+$config.token)}
 $curlPath=$null
 if ($config.curl_path -and (Test-Path -LiteralPath $config.curl_path)) {$curlPath=[string]$config.curl_path}
 if (-not $curlPath) {$curlCommand=Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue;if ($curlCommand) {$curlPath=$curlCommand.Definition}}
 function CurlQuote([string]$value) {return '"'+$value.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n')+'"'}
 function SendCurl([string]$payload) {
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=$curlPath
  $info.Arguments='--config - --silent --show-error --write-out \n%{http_code} --max-filesize 16384 --connect-timeout 5 --max-time 12'
  $info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $process=New-Object Diagnostics.Process
  $process.StartInfo=$info
  try {
   [void]$process.Start()
   $curlLines=@(('url = '+(CurlQuote $config.url)),'request = "POST"',('header = '+(CurlQuote ('Authorization: Bearer '+$config.token))),'header = "Content-Type: application/json; charset=utf-8"',('data-binary = '+(CurlQuote $payload)))
   $curlBytes=[Text.Encoding]::UTF8.GetBytes(($curlLines -join "`n")+"`n")
   $process.StandardInput.BaseStream.Write($curlBytes,0,$curlBytes.Length)
   $process.StandardInput.BaseStream.Close()
   $output=$process.StandardOutput.ReadToEnd();$discard=$process.StandardError.ReadToEnd()
   $process.WaitForExit()
   $split=$output.LastIndexOf("`n");$http='';$body=''
   if ($split -ge 0) {$http=$output.Substring($split+1).Trim();$body=$output.Substring(0,$split)}
   if ($process.ExitCode -eq 0 -and $http -match '^\d{3}$') {
    $answer='HTTP '+$http+' (curl)'
    if ([int]$http -ge 400) {
     try {
      $detail=$body|ConvertFrom-Json
      if ($detail.reason -match '^(Invalid [A-Za-z ]+|Too many farms)$') {$answer+=': '+$detail.reason}
      if ($detail.reason -eq 'Invalid timestamp') {$answer+='; check server date/time'}
     } catch {}
    }
    return $answer
   }
   return 'curl_exit_'+$process.ExitCode
  } finally {$process.Dispose()}
 }
 while ($null -ne ($line=[Console]::In.ReadLine())) {
  if (-not $line) {continue}
  $result='transport_error'
  try {
   if ($curlPath) {$result=SendCurl $line}
   else {
   $response=Invoke-WebRequest -UseBasicParsing -Uri $uri -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($line)) -TimeoutSec 5
   $result='HTTP '+[int]$response.StatusCode
   }
  } catch {
   if ($_.Exception.Response) {$result='HTTP '+[int]$_.Exception.Response.StatusCode}
   elseif ($_.Exception.Status) {$result='transport_'+[string]$_.Exception.Status}
  }
  if ($config.ack) {try {[IO.File]::WriteAllText([string]$config.ack,$result,[Text.Encoding]::ASCII)} catch {}}
 }
} catch {exit 1}
]]
local senderStatusPath=nil;local lastSenderStatus=nil
local sender=nil;local nextHeartbeat=0;local retryReportAt=0;local storagePending=false;local lastSignature=nil;local sequence=0
local session=tostring(os.time())..'-'..tostring(bot.index)..'-'..tostring(math.random(100000,999999))
local function safeValue(fn) local ok,v=pcall(fn);if ok then return v end end
publishStats=function(reason)
 if senderStatusPath then
  pcall(function()
   local f=io.open(senderStatusPath,"rb")
   if f then
    local status=f:read("*a");f:close()
    if status~="" and status~=lastSenderStatus then
     lastSenderStatus=status
     bot:getLog():append("[FarmStats] "..status)
    end
   end
  end)
 end
 if reason=="storage_complete" then storagePending=true end
 if os.time()<retryReportAt then return end
 if not MONITOR.enabled or MONITOR.url=="" or MONITOR.token=="" or telemetry.suppress then return end
 local signature=telemetry.phase..":"..tostring(telemetry.farm)..":"..tostring(bot.status)..":"..tostring(worldName())
 local heartbeat=MONITOR.heartbeat_seconds or 300
 if not storagePending and reason~="first_world_scan" and reason~="farm_finished" and signature==lastSignature and (heartbeat<=0 or os.time()<nextHeartbeat) then return end
 local ok,err=pcall(function()
  if not sender then
   local encoded=base64(senderCode)
   -- UTF-8 wrapper keeps the command below cmd.exe's 8191-character limit.
   local command=[[powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "& ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(']]..encoded..[['))))"]]
   sender=assert(io.popen(command,'w'),'stats sender unavailable')
   sender:setvbuf('no')
   local temp=safeValue(function()return os.getenv("TEMP")end) or "."
   senderStatusPath=temp.."/farm-monitor-"..session..".status"
   assert(sender:write(jsonEncode({url=MONITOR.url,token=MONITOR.token,ack=senderStatusPath,curl_path=MONITOR.curl_path or "C:/curl/bin/curl.exe"})..'\n'));assert(sender:flush())
   bot:getLog():append("[FarmStats] sender started; awaiting HTTP receipt")
  end
  local currentWorld=worldName() or 'EXIT'
  local online=bot.status==BotStatus.online and currentWorld~='EXIT'
  local inventory={}
  if online then
   inventory.seeds=safeValue(function()return count(SEED_ID)end)
   inventory.blocks=safeValue(function()return count(BLOCK_ID)end)
   inventory.gems=safeValue(function()return bot.gem_count end)
  end
  local name=safeValue(function()return bot.name end)
  if type(name)~='string' or name:find('@',1,true) then name='Bot '..bot.index end
  sequence=sequence+1
  local snapshot={heartbeat_seconds=heartbeat,event_name=(storagePending and "storage_complete") or reason or (signature~=lastSignature and "action_changed" or "heartbeat"),farms=monitorFarms,agent_id=MONITOR.agent_id,bot_index=bot.index,session_id=session,seq=sequence,captured_at=os.time(),name=name,status=tonumber(bot.status) or 0,phase=telemetry.phase,world=currentWorld,farm=telemetry.farm,x=bot.x,y=bot.y,seed_id=SEED_ID,block_id=BLOCK_ID,inventory=inventory,counters=telemetry.counters,scan=telemetry.scan,scans=telemetry.scans,storage=storagePending and telemetry.storage or nil,last_message=telemetry.last_message}
  assert(sender:write('{"snapshots":['..jsonEncode(snapshot)..']}\n'));assert(sender:flush())
  lastSignature=signature;nextHeartbeat=os.time()+math.max(60,heartbeat);storagePending=false;retryReportAt=0
 end)
 if not ok then
  -- Farming stays active if launching/writing telemetry fails. No secrets in logs.
  sender=nil;retryReportAt=os.time()+30
  pcall(function()bot:getLog():append('[FarmStats] sender unavailable; retrying next report')end)
 end
end

-- After action delays, recover the expected world. With a configured door ID, white-door arrival must rewarp using that ID.
local expect=nil
local entryTiles={}
local rejoins=0
local enter
local function onWhiteDoor() local t=tileAt(bot.x,bot.y);return t~=nil and t.fg==6 end
local function readyForActions()
 local name=worldName()
 return bot.status==BotStatus.online and name~=nil and name~="EXIT"
end
local function guard()
 if not expect then return end
 local hasDoor=expect.door~=nil and expect.door~=""
 if readyForActions() and bot:isInWorld(expect.world) and not (hasDoor and onWhiteDoor()) then return end
 say("not in place ("..tostring(worldName())..(hasDoor and onWhiteDoor() and ", on the white door" or "").."), expected "..expect.world..": joining again")
 enter(expect.world,expect.door)
 rejoins=rejoins+1
end
local function nap(ms) sleep(ms);guard();if publishStats then publishStats() end end
-- Native collect: the bot's own auto_collect does the picking up (with its own collect range and delay). It is ON in the farm worlds and OFF in
-- the storage world, so the bot does not pick its own dropped seeds up again (SC_ROTATION turns it off for storage for the same reason).
local function setCollect(on)
 local ok,err=pcall(function() bot.auto_collect=on end)
 if not ok then say("auto_collect could not be set to "..tostring(on)..": "..tostring(err));return end
 if bot.auto_collect~=on then say("auto_collect did not take: it reads "..tostring(bot.auto_collect)) end
end

-- ---------- worlds ----------
local blocked={}
addEvent(Event.variantlist,function(varlist,netid) -- "Players lower than level N can't enter WORLD." marks the world as refused
 local ok,kind=pcall(function() return varlist:get(0):getString() end)
 if not ok or kind~="OnConsoleMessage" then return end
 local okm,text=pcall(function() return varlist:get(1):getString() end)
 if not okm or type(text)~="string" then return end
 local refused=text:match("[Cc]an[^%w%s]+t enter ([%w]+)")
 if refused then refused=refused:upper();if not blocked[refused] then blocked[refused]=text;say("entry refused: "..text) end end
end)
local function nativeList(raw)
 if type(raw)=="table" then local out={};for _,v in pairs(raw) do out[#out+1]=v end;return out end
 local out={};local ok,n=pcall(function()return #raw end)
 if not ok then return nil end
 local ok0,v=pcall(function()return raw[0]end);local base=ok0 and v~=nil and 0 or 1
 for i=base,base+n-1 do local good,value=pcall(function()return raw[i]end);if not good or value==nil then return nil end;out[#out+1]=value end
 return out
end
-- One per-bot gate shared by farm, storage, return and recovery entry calls.
local warpState={next_at=0}
local function requestWarp(world,door)
 if bot.status~=BotStatus.online or idleDisconnected then return false end
 local hasDoor=door~=nil and door~=""
 if readyForActions() and bot:isInWorld(world) and not (hasDoor and onWhiteDoor()) then return false end
 if os.time()<warpState.next_at then return false end
 -- Set the cooldown before sending, including when the native call fails.
 warpState.next_at=os.time()+math.ceil(math.max(WARP_RETRY_MIN_MS or 10000,nativeMs("warp"))/1000)
 if STORAGE and world==STORAGE.world then setCollect(false) end
 if hasDoor and onWhiteDoor() then say("white door: rejoining "..world.."|"..door)
 else say("joining "..world.." from "..tostring(worldName())) end
 -- Final online check at the sole native warp call site.
 if bot.status~=BotStatus.online or idleDisconnected then return false end
 if hasDoor then bot:warp(world,door) else bot:warp(world) end
 return true
end
-- Check state after a warp; do not require a fixed sleep after successful arrival.
function enter(world,door)
 world=world:upper();expect={world=world,door=door}
 local hasDoor=door~=nil and door~=""
 if blocked[world] then return false end
 local nextConnect=0
 if idleDisconnected then
  idleDisconnected=false;bot.auto_reconnect=workAutoReconnect
  if bot.status==BotStatus.offline then bot:connect();nextConnect=os.time()+15 end
 end
 if readyForActions() and bot:isInWorld(world) and not (hasDoor and onWhiteDoor()) then return true end
 while true do
  if blocked[world] then return false end
  if bot.status~=BotStatus.online then
   if bot.status==BotStatus.offline and not bot.auto_reconnect and os.time()>=nextConnect then
    bot:connect();nextConnect=os.time()+15
   end
  else requestWarp(world,door) end
  eventWait(1)
  if readyForActions() and bot:isInWorld(world) and not (hasDoor and onWhiteDoor()) then
   entryTiles[world]=entryTiles[world] or {}
   entryTiles[world][bot.x..":"..bot.y]={x=bot.x,y=bot.y}
   say("joined "..tostring(worldName())..": online, not EXIT; continuing")
   return true
  end
 end
end

local function walkTo(x,y)
 guard()
 if bot:isInTile(x,y) then return true end
 say("walking from "..bot.x..","..bot.y.." to "..x..","..y)
 -- Execute native pathfinding; do not reject every target based on getPath's
 -- empty/unsupported container representation before movement is even tried.
 bot:findPath(x,y)
 local seen=rejoins;local lastX,lastY=bot.x,bot.y;local changed=os.time();local started=os.time()
 while not bot:isInTile(x,y) do
  nap(nativeMs("move"))
  if rejoins~=seen then seen=rejoins;bot:findPath(x,y);changed=os.time();started=os.time() end
  if bot.x~=lastX or bot.y~=lastY then lastX,lastY=bot.x,bot.y;changed=os.time() end
  if os.time()-changed>=5 or os.time()-started>=30 then
   say("path stalled at "..bot.x..","..bot.y.." toward "..x..","..y.."; returning to next target")
   return false
  end
 end
 return true
end

-- ---------- storage: the shared grid ----------
local function objectTile(o) local x=o.x/32;return (x%1>0.5 and math.ceil(x) or math.floor(x)),math.floor(o.y/32) end
observeStorage=function()
 local stock={};local stacks=0
 for _,o in ipairs(assert(nativeList(bot:getWorld():getObjects()),"dropped object list unavailable")) do
  local id=tostring(o.id);stock[id]=(stock[id] or 0)+(o.count or 1);stacks=stacks+1
 end
 telemetry.storage={world=STORAGE.world,observed_at=os.time(),items=stock,stacks=stacks}
end
local function validDropSite(x,y)
 local target,stand=tileAt(x,y),tileAt(x-1,y)
 if not target or not stand or target.fg~=0 or stand.fg~=0 then return false end
 for _,entry in pairs(entryTiles[STORAGE.world] or {}) do
  if math.abs(y-entry.y)<=1 and (math.abs(x-entry.x)<=1 or math.abs(x-1-entry.x)<=1) then return false end
 end
 -- Protect doors/portals near both the standing position and drop target.
 for yy=y-1,y+1 do for xx=x-2,x+1 do
  local t=tileAt(xx,yy)
  if t and t.fg~=0 then
   if t.fg==6 then return false end
   local ok,name=pcall(function()return getInfo(t.fg).name:lower()end)
   if ok and (name:find("door",1,true) or name:find("portal",1,true) or name:find("entrance",1,true)) then return false end
  end
 end end
 return true
end
local function dropSeedAt(x,y)
 local id=SEED_ID
 if not validDropSite(x,y) then return false end
 while count(id)>0 do
  guard()
  if not walkTo(x-1,y) then return false end
  setCollect(false);bot:setDirection(false)
  nap(nativeMs("drop"))
  -- nap may reconnect/rejoin. Never trust the pre-delay position.
  if readyForActions() and bot:isInWorld(STORAGE.world) and not onWhiteDoor() and bot:isInTile(x-1,y) and bot.x==x-1 and bot.y==y and validDropSite(x,y) then
   local target=tileAt(x,y);local stacks,total=0,0
   for _,o in ipairs(assert(nativeList(bot:getWorld():getObjects()),"dropped object list unavailable")) do
    local ox,oy=objectTile(o)
    if ox==x and oy==y then stacks=stacks+1;total=total+(o.count or 1) end
   end
   if not target or target.fg~=0 or stacks>=MAX_STACKS or total>=MAX_ITEMS then return false end
   local before=count(id);local amount=math.min(before,MAX_ITEMS-total)
   if amount<=0 then return false end
   -- Facing has settled; no yield between final validation and the drop.
   if readyForActions() and bot:isInWorld(STORAGE.world) and not onWhiteDoor() and bot:isInTile(x-1,y) and bot.x==x-1 and bot.y==y and validDropSite(x,y) then
    say("dropping Toilet Seed ("..id..") x"..amount.." at "..x..","..y)
    bot:drop(id,amount)
    local nextPendingLog=os.time()+10
    while true do
     guard()
     if readyForActions() and bot:isInWorld(STORAGE.world) and not onWhiteDoor() and count(id)<before then
      say("Toilet Seed drop confirmed; carrying "..count(id))
      return true,before
     end
     if os.time()>=nextPendingLog then
      nextPendingLog=os.time()+30
      say("Toilet Seed drop pending; waiting, not moving to another tile or resending")
     end
     nap(math.max(100,nativeMs("drop")))
    end
   end
  end
  say("drop position changed; repositioning at "..(x-1)..","..y.." before dropping")
 end
 return false
end
local function storeSeeds(farmWorld,finishOnly)
 telemetry.phase="storing";telemetry.farm=farmWorld;telemetry.suppress=true
 say("seeds: "..count(SEED_ID).." carried, going to storage "..STORAGE.world)
 setCollect(false) -- native collect off BEFORE joining: on arrival it would pick the seeds already lying in storage up again
 enter(STORAGE.world,STORAGE.door)
 local w=bot:getWorld()
 local last=math.min(STORAGE.end_x,w.x-1)
 local width=last-STORAGE.start_x+1
 local size=width*(STORAGE.start_y-STORAGE.min_y+1)
 local startAt=1 -- every bot starts at STORAGE.start_x, STORAGE.start_y
 local lastReported=""
 while true do
  guard()
  if count(SEED_ID)<=0 then break end
  local itemId=SEED_ID
  -- what lies on each tile NOW (read again before every drop; the other bot drops here too)
  local used={}
  for _,o in ipairs(assert(nativeList(bot:getWorld():getObjects()),"dropped object list unavailable")) do
   local x,y=objectTile(o);local key=x..":"..y
   local cell=used[key] or {stacks=0,total=0};used[key]=cell
   cell.stacks=cell.stacks+1;cell.total=cell.total+(o.count or 1)
  end
  local dropped=false
  for off=0,size-1 do
   local idx=(startAt-1+off)%size+1
   local zero=idx-1
   local x=STORAGE.start_x+zero%width;local y=STORAGE.start_y-zero//width
   local occ=used[x..":"..y] or {stacks=0,total=0}
   local t=tileAt(x,y)
   if t and validDropSite(x,y) and occ.stacks<MAX_STACKS and occ.total<MAX_ITEMS then
    local sent,before=dropSeedAt(x,y)
    if sent then
     nap(nativeMs("drop"))
     if count(itemId)<before then if itemId==SEED_ID then telemetry.counters.seeds_deposited=telemetry.counters.seeds_deposited+(before-count(itemId)) end;dropped=true;startAt=idx;break end
    end
   end
  end
  if not dropped then
   if lastReported~="full" then lastReported="full";say("storage grid: no tile took the seeds; looking again") end
   eventWait(1)
  end
 end
 observeStorage()
 telemetry.phase="storage_complete";telemetry.suppress=false
 if publishStats then publishStats("storage_complete") end
 if finishOnly then
  say("final storage complete: no Toilet Seeds carried")
 else
  say("seeds dropped; back to "..farmWorld)
  enter(farmWorld,FARM_DOOR)
  setCollect(true)
 end
end

maintainIdle=function()
 if not idleDisconnected then return end
 bot.auto_reconnect=false
 if bot.status~=BotStatus.offline and os.time()>=idleDisconnectAt then
  bot:disconnect();idleDisconnectAt=os.time()+5
 end
end
local function leaveCurrentWorld()
 setCollect(false);expect=nil
 local nextLeave=0
 while bot.status==BotStatus.online and worldName() and worldName()~="EXIT" do
  if os.time()>=nextLeave then bot:leaveWorld();nextLeave=os.time()+5 end
  eventWait(1)
 end
end
local function leaveAndIdle(cleanupInventory)
 if idleDisconnected then maintainIdle();return end
 if cleanupInventory and count(SEED_ID)>0 then storeSeeds(telemetry.farm or worldName() or "EXIT",true) end
 bot.auto_reconnect=false
 leaveCurrentWorld()
 idleDisconnected=true;maintainIdle()
 telemetry.phase="idle";telemetry.farm=nil
 say(cleanupInventory and "Toilet Seeds stored; no assignment available; disconnected" or "unassigned; disconnected until assigned")
 if publishStats then publishStats() end
end

-- ---------- harvest ----------
local function treesToDo()
 local list,total
 while true do
  guard()
  local w=bot:getWorld();local width,height=w.x,w.y
  local expectedWorld=worldName()
  local complete=type(width)=="number" and type(height)=="number" and width>0 and height>0
  list={};total=0
  if complete then
   for y=0,height-1 do
    for x=0,width-1 do
     local t=tileAt(x,y)
     if not t then complete=false;break end
     if t.fg==SEED_ID then
      total=total+1
      local ok,ready=pcall(function()return t:canHarvest()end)
      if not ok then complete=false;break end
      if ready then list[#list+1]={x=x,y=y} end
     end
    end
    if not complete then break end
   end
  end
  if complete and readyForActions() and worldName()==expectedWorld then
   say("world scan: "..(width*height).."/"..(width*height).." tiles checked")
   break
  end
  say("world scan incomplete; waiting for tile data before retrying")
  eventWait(1)
 end
 table.sort(list,function(a,b) if a.y~=b.y then return a.y<b.y end return a.x<b.x end)
 local out,i,flip={},1,false
 while i<=#list do
  local j=i
  while j<=#list and list[j].y==list[i].y do j=j+1 end
  if flip then for k=j-1,i,-1 do out[#out+1]=list[k] end else for k=i,j-1 do out[#out+1]=list[k] end end
  flip=not flip;i=j
 end
 return out,total
end
-- one pass: hits every ready tree once; returns how many were ready, and whether the block limit was reached
local function harvestPass()
 telemetry.phase="harvesting"
 guard() -- a read of the world while disconnected sees no trees and would end the world: be in place first
 say("scanning ready trees in "..tostring(worldName()))
 local list,total=treesToDo()
 telemetry.scan={world=worldName(),observed_at=os.time(),trees=total,ready=#list}
 telemetry.scans[telemetry.scan.world]=telemetry.scan
 local firstScan=not telemetry.first_scans[telemetry.scan.world]
 telemetry.first_scans[telemetry.scan.world]=true
 if firstScan then
  say(telemetry.scan.world..": first scan — "..total.." trees, "..#list.." ready"..(total==0 and "; HARVEST DONE" or "; work remaining"))
 end
 if publishStats then publishStats(firstScan and "first_world_scan" or nil) end
 say("scan complete: "..total.." trees, "..#list.." ready; starting harvest")
 local hit,noRoute,gone=0,0,0
 local function report() say(string.format("pass: %d tree(s) in the world, %d ready, hit %d, no route %d, already taken/not ready on arrival %d",total,#list,hit,noRoute,gone)) end
 for _,c in ipairs(list) do
  local t=tileAt(c.x,c.y)
  local ready=false
  if t and t.fg==SEED_ID then pcall(function() ready=t:canHarvest()==true end) end
  if ready then
   if walkTo(c.x,c.y) then
    -- the other bot may have been faster while this one walked: hit only if the tree is still there and ready
    t=tileAt(c.x,c.y)
    ready=false
    if t and t.fg==SEED_ID then pcall(function() ready=t:canHarvest()==true end) end
    if ready then
     bot:hit(c.x,c.y)
     hit=hit+1;telemetry.counters.harvest_attempts=telemetry.counters.harvest_attempts+1
     nap(nativeMs("harvest")) -- the native auto_collect picks the drops up
    else gone=gone+1 end
    if count(SEED_ID)>=SEED_LIMIT then report();return #list,false,true,total end
    if count(BLOCK_ID)>=BLOCK_LIMIT then report();return #list,true,false,total end
   else noRoute=noRoute+1 end
  end
 end
 if #list>0 then report() end
 if #list>0 and hit==0 and noRoute>0 then nap(5000) end
 return #list,false,false,total
end

-- ---------- PNB: place all / break all / collect, on the chicken layout, until the bot has no block ----------
local function pnbTargets()
 local list={}
 for _,o in ipairs(PNB_OFFSETS) do list[#list+1]={x=STAND.x+o.dx,y=STAND.y+o.dy} end
 return list
end
local function pnbCycle(farmWorld)
 telemetry.phase="pnb";telemetry.farm=farmWorld
 if publishStats then publishStats() end
 guard()
 if not walkTo(STAND.x,STAND.y) then say("no route to the PNB tile "..STAND.x..","..STAND.y);return end
 local targets=pnbTargets()
 for _,tg in ipairs(targets) do
  guard()
  if not walkTo(STAND.x,STAND.y) then return end
  local t=tileAt(tg.x,tg.y)
  if t and t.fg==0 and count(BLOCK_ID)>0 and readyForActions() and bot:isInWorld(farmWorld) and bot:isInTile(STAND.x,STAND.y) then
   bot:place(tg.x,tg.y,BLOCK_ID)
   telemetry.counters.blocks_placed=telemetry.counters.blocks_placed+1
   nap(nativeMs("place"))
  end
 end
 for _,tg in ipairs(targets) do
  while true do
   guard()
   if not walkTo(STAND.x,STAND.y) then return end
   local t=tileAt(tg.x,tg.y)
   if not t or t.fg~=BLOCK_ID then break end
   if readyForActions() and bot:isInWorld(farmWorld) and bot:isInTile(STAND.x,STAND.y) then
    bot:hit(tg.x,tg.y)
    telemetry.counters.pnb_hits=telemetry.counters.pnb_hits+1
    nap(nativeMs("hit"))
   end
  end
 end
end

local lastTreeTotal=nil
local function farmWorld(world)
 telemetry.farm=world;telemetry.phase="joining"
 if not enter(world,FARM_DOOR) then say(world..": refused, skipped");leaveAndIdle();return end
 setCollect(true) -- native collect on in the farm
 say(world..": start, part "..part.." of "..PARTS)
 while true do
  guard()
  local readyCount,atLimit,seedFull,treeTotal=harvestPass()
  lastTreeTotal=treeTotal
  if seedFull then storeSeeds(world) end
  -- PNB when the block limit was reached, or when nothing is left to harvest and blocks are carried
  if count(BLOCK_ID)>0 and (atLimit or readyCount==0 or count(BLOCK_ID)>=BLOCK_LIMIT) then
   while count(BLOCK_ID)>0 do
    pnbCycle(world)
    if count(SEED_ID)>=SEED_LIMIT then storeSeeds(world) end
   end
  end
  if count(SEED_ID)>=SEED_LIMIT then storeSeeds(world) end
  if readyCount==0 and count(BLOCK_ID)==0 then break end -- nothing ready, no block left: this world is finished
 end
 local finalReady,finalTotal=treesToDo()
 local finalObserved=os.time()
 setCollect(false)
 telemetry.scan={world=world,observed_at=finalObserved,trees=finalTotal,ready=#finalReady,finished=true}
 telemetry.scans[world]=telemetry.scan
 lastTreeTotal=finalTotal
 telemetry.counters.worlds_completed=telemetry.counters.worlds_completed+1;telemetry.phase="waiting";telemetry.has_completed_job=true
 say(world..": finished ("..finalTotal.." trees standing, "..#finalReady.." ready)")
 if publishStats then publishStats("farm_finished") end
 leaveCurrentWorld()
end

-- ---------- claim board: one shared list, never more than one pair on a farm ----------
-- Each bot's custom_status is the board (the bots can read each other's: CUSTOM_STATUS_PROBE.lua showed it).
--   leader (odd index)  writes  "CLAIM|<pair>|<WORLD>"  before it joins a world, and clears it when the whole pair is finished there;
--   follower (even index) reads its leader's claim and works the same world; when it is finished it writes "DONE|<pair>|<WORLD>".
-- A leader takes the next world of the list that no OTHER pair has claimed and that no bot of another pair is standing in. After writing the claim it
-- reads the board again: if another pair claimed the same world at the same moment, the LOWER pair number keeps it and the other picks again.
local function allBots()
 local out={}
 local ok,raw=pcall(function() return getBots() end)
 if not ok or raw==nil then return out end
 if type(raw)=="table" then for _,b in pairs(raw) do out[#out+1]=b end
 else
  local ok0,first=pcall(function() return raw[0] end)
  local base=(ok0 and first~=nil) and 0 or 1
  local okn,n=pcall(function() return #raw end)
  for i=base,base+((okn and n) or 0)-1 do out[#out+1]=raw[i] end
 end
 return out
end
local function statusOf(b) local ok,s=pcall(function() return b.custom_status end);return (ok and type(s)=="string") and s or "" end
local function indexOf(b) local ok,i=pcall(function() return b.index end);return ok and i or nil end
local function worldOfBot(b) if b.status~=BotStatus.online then return nil end;local ok,n=pcall(function() return b:getWorld().name end);return (ok and type(n)=="string") and n:upper() or nil end
local function setStatus(text)
 local cleared={}
 for world,scan in pairs(telemetry.scans) do if scan.finished and scan.trees==0 then cleared[#cleared+1]=world end end
 table.sort(cleared)
 if text=="" then text="IDLE|"..pair.."|EXIT" end
 text=text.."|seed="..SEED_ID.."|cleared="..table.concat(cleared,",")
 local ok,err=pcall(function() bot.custom_status=text end)
 if not ok then say("custom_status could not be set: "..tostring(err)) end
end
local function botByIndex(i) for _,b in ipairs(allBots()) do if indexOf(b)==i then return b end end end
local function parseStatus(s) local kind,p,w=s:match("^(%u+)|(%d+)|(%w+)");if kind then return kind,tonumber(p),w:upper() end end
-- is `world` free for pair `me`? claimed by another pair, or another pair's bot standing in it, means no
local function freeFor(world)
 for _,b in ipairs(allBots()) do
  local i=indexOf(b)
  if i and i~=bot.index and (i+1)//2~=pair then
   local kind,p,w=parseStatus(statusOf(b))
   if kind=="CLAIM" and w==world and p~=pair then return false end
   if worldOfBot(b)==world then return false end
  end
 end
 return true
end
local function claimedByLowerPair(world)
 for _,b in ipairs(allBots()) do
  local i=indexOf(b)
  if i and (i+1)//2~=pair then
   local kind,p,w=parseStatus(statusOf(b))
   if kind=="CLAIM" and w==world and p<pair then return true end
  end
 end
 return false
end
local function worldCleared(world)
 local own=telemetry.scans[world]
 if own and own.finished and own.trees==0 then return true end
 for _,b in ipairs(allBots()) do
  local board=statusOf(b)
  if tonumber(board:match("|seed=(%d+)"))==SEED_ID then
   local cleared=board:match("|cleared=([A-Z0-9,]*)")
   for name in (cleared or ""):gmatch("[A-Z0-9]+") do if name==world then return true end end
  end
 end
 return false
end
local cursor=1
local function leaderPick()
 telemetry.phase="claiming"
 local warned=false
 while true do
  local availableWork=false
  for k=0,#FARMS-1 do
   local idx=(cursor-1+k)%#FARMS+1
   local w=FARMS[idx]:upper()
   local notDone=not blocked[w] and not worldCleared(w)
   if notDone then availableWork=true end
   if notDone and freeFor(w) then
    setStatus("CLAIM|"..pair.."|"..w)
    eventWait(1) -- let the other leaders' claims and mine settle, then read the board again
    if freeFor(w) and not claimedByLowerPair(w) then cursor=idx%#FARMS+1;return w end
    setStatus("") -- another pair took it at the same moment (and has the lower number, or is already in): choose again
   end
  end
  setStatus("WAIT|"..pair.."|EXIT")
  leaveAndIdle(telemetry.has_completed_job==true)
  telemetry.phase=availableWork and "waiting_for_world" or "all_farms_done"
  if not warned then
   warned=true;say(availableWork and "no free world: waiting disconnected" or "all farm worlds cleared; staying disconnected until next run")
  end
  eventWait(1)
 end
end
local lastDone=nil
local function followerWait()
 leaveCurrentWorld()
 if not telemetry.has_completed_job then leaveAndIdle(false) end
 telemetry.phase="waiting_for_leader"
 local warned=false
 while true do
  local leader=botByIndex(bot.index-1)
  if leader then
   local kind,p,w=parseStatus(statusOf(leader))
   if kind=="CLAIM" and p==pair and w~=lastDone then return w end
   -- Only an explicit no-assignment decision triggers final storage.
   -- Do not drain between DONE and the leader's next CLAIM.
   if kind=="WAIT" and p==pair then leaveAndIdle(telemetry.has_completed_job==true) end
  end
  if not warned then warned=true;say("waiting for the leader's next assignment") end
  eventWait(1)
 end
end
local function waitFollowerDone(world)
 if bot.index+1>BOT_COUNT then return end
 leaveCurrentWorld();telemetry.phase="waiting_for_partner"
 -- A follower being offline is normal idle behavior, not a DONE acknowledgement.
 while true do
  local follower=botByIndex(bot.index+1)
  if follower then
   local kind,p,w=parseStatus(statusOf(follower))
   if kind=="DONE" and p==pair and w==world then return end
  end
  eventWait(1)
 end
end

if MONITOR.enabled and MONITOR.url~="" and MONITOR.token~="" then
 say("[FarmStats] telemetry enabled; sending action changes")
else
 say("[FarmStats] telemetry disabled: set MONITOR.enabled, url and token")
end
assert(#FARMS>0,"the world list is empty")
say("pair "..pair..", part "..part.." ("..(part==1 and "leader: claims worlds" or "follower: follows the leader's claim").."), "..#FARMS.." world(s) in the shared list")
setStatus("")
while true do
 if part==1 then
  local w=leaderPick()
  say("claimed "..w)
  farmWorld(w)
  waitFollowerDone(w) -- the claim stays until the whole pair is finished there
  setStatus("")
 else
  local w=followerWait()
  setStatus("")
  farmWorld(w)
  lastDone=w
  setStatus("DONE|"..pair.."|"..w)
 end
end
