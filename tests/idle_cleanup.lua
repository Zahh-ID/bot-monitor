local root=MASSING_ROOT or "lua"
local f=assert(io.open(root.."/HARVEST_PNB.lua","rb"));local s=f:read("*a");f:close()
local a=assert(s:find("local function objectTile",1,true));local b=assert(s:find("-- ---------- harvest",a,true))
local c=assert(s:find("local warpState=",1,true));local d=assert(s:find("local function walkTo",c,true))
local fixture=[=[
local time=0;local os={time=function()return time end};local idleDisconnected=false;local idleDisconnectAt=0;local workAutoReconnect=true;local maintainIdle;local expect={world="FARM01"};local entryTiles={};local blocked={}
local BotStatus={online=1,offline=0};local bot={status=1,world="FARM01",auto_reconnect=true,x=7,y=1};local inventory={[107]=1,[999]=2};local drops={};local connects=0;local disconnects=0;local events={}
local STORAGE={world="STORE",door="ID",start_x=2,end_x=3,start_y=21,min_y=21};local SEED_ID=107;local MAX_STACKS=20;local MAX_ITEMS=3800;local part=1;local PARTS=2
local telemetry={phase="waiting",counters={seeds_deposited=0}}
local function count(id)return inventory[id]or 0 end
local function say()end
local function nativeMs()return 100 end
local function nativeList(v)return v end
local function setCollect(v)bot.auto_collect=v end
local function worldName()return bot.world end
local function readyForActions()return bot.status==1 and bot.world~="EXIT"end
local function onWhiteDoor()return false end
local function tileAt()return {fg=0}end
local function guard()end
local function publishStats(reason)events[#events+1]=reason end
local function eventWait(n)time=time+n;if maintainIdle then maintainIdle()end end
local function nap()time=time+1 end
local function walkTo(x,y)bot.x=x;bot.y=y;return true end
local function enter(w)bot.world=w;bot.status=1;return true end
function bot:getWorld()return {x=100,y=60,getObjects=function()return {}end}end
function bot:getInventory()return {getItems=function()local out={};for id,n in pairs(inventory)do if n>0 then out[#out+1]={id=id,count=n}end end;return out end}end
function bot:isInWorld(w)return self.world==w end
function bot:isInTile(x,y)return self.x==x and self.y==y end
function bot:setDirection()end
function bot:drop(id,n)assert(self.world=="STORE" and self:isInTile(1,21));drops[#drops+1]=id;inventory[id]=inventory[id]-n end
function bot:leaveWorld()assert(not next(inventory) or (count(107)==0 and count(999)==2));self.world="EXIT"end
function bot:disconnect()assert(count(107)==0 and count(999)==2);self.status=0;disconnects=disconnects+1 end
function bot:connect()connects=connects+1;self.status=1 end
function bot:warp(w,id)self.world=w end
]=]
local idleChecks=[=[
leaveAndIdle(true);assert(count(107)==0 and count(999)==2 and #drops==1)
assert(telemetry.counters.seeds_deposited==1 and events[1]=="storage_complete")
assert(bot.world=="EXIT" and bot.status==0 and not bot.auto_reconnect and expect==nil)
for i=1,20 do eventWait(1)end
assert(connects==0 and disconnects==1,"idle wait reconnects or spams disconnect")
]=]
local assignedChecks=[=[
assert(enter("FARM02","DOOR"));assert(connects==1 and bot.world=="FARM02" and not idleDisconnected)
inventory[107]=1;inventory[999]=2
function bot:leaveWorld()self.world="EXIT"end
function bot:disconnect()self.status=0 end
local previousDrops=#drops
leaveAndIdle(false);assert(#drops==previousDrops and count(107)==1 and count(999)==2,"startup unexpectedly stored inventory")
return "Idle cleanup passed: final Toilet singleton stored, unrelated item preserved, leave before disconnect, no idle connects, reconnect only on assignment"
]=]
return assert(load(fixture..s:sub(a,b-1)..idleChecks..s:sub(c,d-1)..assignedChecks,"idle-cleanup-test"))()
