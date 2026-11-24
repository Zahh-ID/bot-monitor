-- Production scan and storage-site tests; no client/network execution.
local root=MASSING_ROOT or "lua"
local f=assert(io.open(root.."/HARVEST_PNB.lua","rb"));local source=f:read("*a");f:close()
local a=assert(source:find("local function treesToDo()",1,true));local b=assert(source:find("-- one pass:",a,true))
local fixture=[=[
local SEED_ID=107;local reads={};local retry=0;local reported=false
local bot={getWorld=function()return {x=4,y=3,getTilesSafe=function()error("partial tile copy must not be used")end}end}
local function guard()end
local function readyForActions()return true end
local function worldName()return "FARM01"end
local function say(s)if s:find("12/12",1,true)then reported=true end end
local function eventWait()retry=retry+1 end
local function tileAt(x,y)
 local key=x..":"..y;reads[key]=(reads[key]or 0)+1
 if x==3 and y==2 and retry==0 then return nil end
 return {fg=(x==0 or x==3) and 107 or 0,canHarvest=function()return true end}
end
]=]
local checks=[=[
local ready,total=treesToDo();assert(retry==1 and total==6 and #ready==6 and reported)
for y=0,2 do for x=0,3 do assert(reads[x..":"..y],"coordinate omitted")end end
]=]
assert(load(fixture..source:sub(a,b-1)..checks,"full-world-regression"))()
a=assert(source:find("local function validDropSite",1,true));b=assert(source:find("local function storeSeeds",a,true))
fixture=[=[
local STORAGE={world="STORE"};local entryTiles={STORE={["door"]={x=65,y=24}}}
local mode="clear";local sends=0;local walks=0;local naps=0;local quantity=100
local MAX_STACKS=20;local MAX_ITEMS=3800;local SEED_ID=107
local bot={x=1,y=21}
local function count()return quantity end
local function guard()end
local function nativeMs()return 100 end
local function readyForActions()return true end
local function onWhiteDoor()return false end
local function setCollect()end
local function say()end
local function nativeList(v)return v end
local function objectTile(o)return o.x,o.y end
local function tileAt(x,y)
 if mode=="door" and x==1 and y==21 then return {fg=12} end
 if mode=="adjacent" and x==3 and y==21 then return {fg=12}end
 return {fg=0}
end
local function getInfo()return {name="Wooden Door"}end
local function walkTo(x,y)walks=walks+1;bot.x=x;bot.y=y;return true end
local function nap()naps=naps+1;if mode=="rejoin" and naps==1 then bot.x=65;bot.y=24 end end
function bot:isInWorld(w)return w=="STORE"end
function bot:isInTile(x,y)return self.x==x and self.y==y end
function bot:getWorld()return {getObjects=function()return {}end}end
function bot:setDirection()end
function bot:drop(id,n)assert(self.x==1 and self.y==21);sends=sends+1;quantity=quantity-n end
]=]
checks=[=[
mode="door";assert(not dropSeedAt(2,21));assert(sends==0)
mode="adjacent";assert(not validDropSite(2,21));assert(sends==0)
mode="clear";assert(not validDropSite(65,24));assert(validDropSite(2,21))
mode="rejoin";assert(dropSeedAt(2,21));assert(sends==1 and walks==2)
]=]
assert(load(fixture..source:sub(a,b-1)..checks,"door-drop-regression"))()
assert(source:find("local startAt=1 -- every bot starts",1,true),"part-dependent start offset returned")
return "Full-world/storage tests passed: all coordinates, incomplete-data retry, door/entry exclusion, reconnect reposition, all bots start at 2,21"
