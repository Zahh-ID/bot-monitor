local root=MASSING_ROOT or "lua";local f=assert(io.open(root.."/HARVEST_PNB.lua","rb"));local s=f:read("*a");f:close()
local a=assert(s:find("local function allBots()",1,true));local b=assert(s:find("local cursor=1",a,true))
local c=assert(s:find("local function waitFollowerDone(world)",b,true));local d=assert(s:find("\nif MONITOR.enabled",c,true))
local fixture=[=[
local BotStatus={online=1};local bot={index=1,status=0};local pair=1;local SEED_ID=107;local BOT_COUNT=15;local tick=0;local telemetry={scans={FARM01={finished=true,trees=0}}}
local follower={index=2,status=0,custom_status="DONE|1|FARM04|seed=107|cleared=FARM04"}
local other={index=3,status=1,custom_status="CLAIM|2|FARM03|seed=107|cleared=FARM06"}
function bot:getWorld()return {name="EXIT"}end
function follower:getWorld()return {name="FARM05"}end
function other:getWorld()return {name="FARM03"}end
local function getBots()return {bot,follower,other}end
local function say()end
local function leaveAndIdle()assert(bot.status==0)end
local function eventWait()tick=tick+1;if tick==3 then follower.custom_status="DONE|1|FARM02|seed=107|cleared=FARM02"end end
]=]
local checks=[=[
assert(worldCleared("FARM01") and worldCleared("FARM04") and worldCleared("FARM06"))
assert(not worldCleared("FARM02"));assert(not freeFor("FARM03"));assert(freeFor("FARM05"),"offline cached world blocks assignment")
setStatus("CLAIM|1|FARM02");local kind,p,w=parseStatus(bot.custom_status);assert(kind=="CLAIM" and p==1 and w=="FARM02")
follower.custom_status="IDLE|1|EXIT|seed=107|cleared=FARM04"
]=]
return assert(load(fixture..s:sub(a,b-1)..checks..s:sub(c,d-1)..'\nwaitFollowerDone("FARM02");assert(tick==3,"offline follower incorrectly considered finished");return "Claim board passed: shared cleared worlds, idle presence ignored, claim kept until actual follower DONE"',"claim-board-test"))()
