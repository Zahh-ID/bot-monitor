local root=MASSING_ROOT or "lua";local f=assert(io.open(root.."/HARVEST_PNB.lua","rb"));local s=f:read("*a");f:close()
local a=assert(s:find("local warpState=",1,true));local b=assert(s:find("local function walkTo",a,true))
assert(not(s:sub(1,a-1)..s:sub(b)):find("bot:warp(",1,true),"warp outside shared gate")
local fixture=[=[
local t=0;local os={time=function()return t end};local BotStatus={online=1,offline=0};local bot={status=0,world="EXIT",auto_reconnect=true,x=5,y=3};local idleDisconnected=false;local workAutoReconnect=true;local blocked={};local expect;local entryTiles={};local sends={};local white=false;local mode=""
local function readyForActions()return bot.status==1 and bot.world~="EXIT"end
local function onWhiteDoor()return white end
local function nativeMs()return 100 end
local function setCollect()end
local function worldName()return bot.world end
local function say()end
function bot:isInWorld(w)return self.world==w end
function bot:connect()error("must not connect in this fixture")end
function bot:warp(w,d)assert(self.status==1 and not idleDisconnected);sends[#sends+1]=t;self.world=w end
local function eventWait(n)
 t=t+n;assert(t<100)
 if mode=="handoff" and t>=24 then bot.status=1;bot.world="FARM02"end
 if mode=="white" then white=false end
end
]=]
local checks=[=[
for _,status in ipairs({0,26,28,34})do bot.status=status;assert(not requestWarp("FARM01","ID"))end
assert(#sends==0)
bot.status=1;assert(requestWarp("FARM01","ID"));assert(not requestWarp("FARM01","ID"))
t=1;assert(not requestWarp("STORE","ID"),"destination switch reset cooldown")
t=10;assert(requestWarp("STORE","ID"));assert(#sends==2)
bot.status=26;bot.world="EXIT";mode="handoff";assert(enter("FARM02","ID"));assert(#sends==2 and t==24,"warp during transitional status")
mode="white";white=true;assert(enter("FARM02","ID"));assert(#sends==3 and sends[3]==24)
mode="";assert(enter("FARM03","ID"));assert(#sends==4 and sends[4]>=34)
for i=2,#sends do assert(sends[i]-sends[i-1]>=10,"warp spam")end
local before=#sends;assert(enter("FARM03","ID"));assert(#sends==before,"warped while already ready")
idleDisconnected=true;assert(not requestWarp("FARM04","ID"))
return "Warp audit passed: online-only sends, shared 10s minimum across destinations/enter calls, no handoff or already-ready spam, white-door retry gated, idle cannot warp"
]=]
return assert(load(fixture..s:sub(a,b-1)..checks,"warp-gate-test"))()
