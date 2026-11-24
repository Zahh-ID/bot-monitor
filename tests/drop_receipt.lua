local root=MASSING_ROOT or "lua";local f=assert(io.open(root.."/HARVEST_PNB.lua","rb"));local s=f:read("*a");f:close()
local a=assert(s:find("local function validDropSite",1,true));local b=assert(s:find("local function storeSeeds",a,true))
local fixture=[=[
local time=0;local os={time=function()return time end};local STORAGE={world="STORE"};local entryTiles={};local SEED_ID=107;local MAX_STACKS=20;local MAX_ITEMS=3800
local bot={x=1,y=21,world="STORE"};local quantity=44;local drops=0;local walks=0;local pending=false;local ticks=0;local face=false;local settled=false
local function count(id)assert(id==107);return quantity end
local function guard()end
local function readyForActions()return bot.world~="EXIT"end
local function onWhiteDoor()return false end
local function tileAt()return {fg=0}end
local function nativeList(x)return x end
local function objectTile(o)return o.x,o.y end
local function nativeMs()return 100 end
local function setCollect()end
local function say()end
local function walkTo(x,y)walks=walks+1;bot.x=x;bot.y=y;return true end
local function nap()
 time=time+1
 if not pending then assert(face);settled=true;return end
 ticks=ticks+1
 if ticks==1 then bot.world="EXIT";quantity=0
 elseif ticks==2 then bot.world="STORE";quantity=44
 elseif ticks==3 then quantity=0 end
 assert(ticks<=3,"receipt wait did not complete")
end
function bot:isInWorld(w)return self.world==w end
function bot:isInTile(x,y)return self.x==x and self.y==y end
function bot:getWorld()return {getObjects=function()return {}end}end
function bot:setDirection(left)assert(left==false);face=true end
function bot:drop(id,n)assert(id==107 and n==44 and settled);drops=drops+1;pending=true end
]=]
return assert(load(fixture..s:sub(a,b-1)..'\nlocal sent,before=dropSeedAt(2,21);assert(sent and before==44 and drops==1 and walks==1 and ticks==3);return "Drop receipt passed: only Toilet Seed, facing settled, delayed receipt waits in place, EXIT inventory ignored, no resend"',"drop-receipt-test"))()
