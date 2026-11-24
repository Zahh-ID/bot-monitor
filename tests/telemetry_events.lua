-- Production event publisher with an in-memory sender; never starts PowerShell.
local root=MASSING_ROOT or "lua"
local f=assert(io.open(root.."/HARVEST_PNB.lua","rb"));local s=f:read("*a");f:close()
s=s:sub(1,assert(s:find("-- After action delays, recover",1,true))-1)
s=s:gsub('enabled=false,url="",token=""','enabled=true,url="http://localhost/api/ingest",token="test-only"',1)
local fixture=[=[
local now=0;local os={time=function()return now end};local frames={};local pipe={}
function pipe:write(text)frames[#frames+1]=text;return self end
function pipe:flush()return true end
function pipe:setvbuf()end
local io={popen=function()return pipe end}
BotStatus={online=1};local b={index=1,status=1,x=7,y=1,name="Test bot",gem_count=10}
function getBot()return b end
function b:getWorld()return {name="KNXSA"}end
function b:getInventory()return {getItemCount=function()return 20 end}end
function b:getLog()return {append=function()end}end
function listenEvents(t)now=now+t end
]=]
local checks=[=[
publishStats();assert(#frames==2)
for i=1,200 do now=now+1;publishStats()end
assert(#frames==2,"unchanged harvest loop sent reports")
telemetry.phase="pnb";publishStats();publishStats();assert(#frames==3)
telemetry.phase="storing";telemetry.suppress=true
for i=1,600 do now=now+1;publishStats()end
assert(#frames==3,"storage loop sent reports")
telemetry.storage={world="444YI",observed_at=now,items={["107"]=1000},stacks=5}
telemetry.phase="storage_complete";telemetry.suppress=false
publishStats("storage_complete");publishStats();assert(#frames==4)
telemetry.phase="pnb";publishStats();publishStats();assert(#frames==5)
now=now+301;publishStats();assert(#frames==6)
local storageReports=0
for i=2,#frames do if frames[i]:find('"storage":',1,true)then storageReports=storageReports+1 end end
assert(storageReports==1,"storage snapshot repeated on later reports")
assert(frames[6]:find('"event_name":"heartbeat"',1,true))
return "Event telemetry passed: 800 unchanged-loop checks silent, transitions once, storage once, heartbeat once"
]=]
return assert(load(fixture..s..checks,"telemetry-event-test"))()
