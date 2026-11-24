local root=MASSING_ROOT or "lua";local f=assert(io.open(root.."/HARVEST_PNB.lua","rb"));local s=f:read("*a");f:close()
local a=assert(s:find("local function farmWorld(world)",1,true));local b=assert(s:find("-- ---------- claim board",a,true))
local c=assert(s:find("local function followerWait()",b,true));local d=assert(s:find("local function waitFollowerDone",c,true))
local fixture=[=[
local telemetry={scans={},counters={worlds_completed=0}};local lastTreeTotal;local seedCount=44;local SEED_ID=107;local BLOCK_ID=106;local SEED_LIMIT=100;local BLOCK_LIMIT=180;local FARM_DOOR="DOOR"
local bot={index=2};local part=2;local PARTS=2;local pair=1;local lastDone="FARM01";local stores=0;local cleanups=0;local leaves=0;local tick=0
local leader={custom_status="CLAIM|1|FARM02"}
local function count(id)return id==SEED_ID and seedCount or 0 end
local function enter()return true end
local function setCollect()end
local function say()end
local function guard()end
local function publishStats()end
local function harvestPass()return 0,false,false,0 end
local function treesToDo()return {},0 end
local function storeSeeds()stores=stores+1;seedCount=0 end
local function leaveCurrentWorld()leaves=leaves+1 end
local function leaveAndIdle(cleanup)if cleanup then cleanups=cleanups+1;seedCount=0 end end
local function botByIndex()return leader end
local function statusOf(b)return b.custom_status end
local function parseStatus(s)local k,p,w=s:match("^(%u+)|(%d+)|(%w+)");return k,tonumber(p),w end
local function eventWait()tick=tick+1;leader.custom_status="CLAIM|1|FARM02"end
]=]
local farmChecks=[=[
farmWorld("FARM01");assert(seedCount==44 and stores==0 and leaves==1 and telemetry.has_completed_job,"farm finish drained sub-limit seeds")
]=]
local followerChecks=[=[
assert(followerWait()=="FARM02");assert(cleanups==0 and seedCount==44,"next assignment caused final storage")
leader.custom_status="IDLE|1|EXIT";assert(followerWait()=="FARM02");assert(cleanups==0 and seedCount==44,"temporary handoff caused storage")
leader.custom_status="WAIT|1|EXIT";assert(followerWait()=="FARM02");assert(cleanups==1 and seedCount==0,"actual no-world decision did not drain inventory")
return "Queue cleanup passed: 44 seeds carried between farms; no handoff drain; cleanup only on explicit no-assignment decision"
]=]
return assert(load(fixture..s:sub(a,b-1)..farmChecks..s:sub(c,d-1)..followerChecks,"queue-cleanup-test"))()
