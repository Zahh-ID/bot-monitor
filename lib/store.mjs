import {MongoClient} from 'mongodb';
const worldPattern=/^[A-Z0-9]{1,32}$/;
function integer(v,min,max,name){if(!Number.isSafeInteger(v)||v<min||v>max)throw Error(`Invalid ${name}`);return v;}
function text(v,max,name){if(typeof v!=='string'||!v.length||v.length>max)throw Error(`Invalid ${name}`);return v;}
function world(v){if(typeof v!=='string'||!worldPattern.test(v))throw Error('Invalid world');return v;}
export function validate(raw,now=Date.now()){
 if(!raw||typeof raw!=='object'||Array.isArray(raw))throw Error('Invalid snapshot');
 const r={agent_id:text(raw.agent_id,64,'agent'),bot_index:integer(raw.bot_index,1,10000,'bot index'),session_id:text(raw.session_id,100,'session'),seq:integer(raw.seq,1,Number.MAX_SAFE_INTEGER,'sequence'),captured_at:integer(raw.captured_at,1,Math.floor(now/1000)+300,'timestamp')};
 if(!/^[a-zA-Z0-9_-]+$/.test(r.agent_id))throw Error('Invalid agent');
 r.farms=raw.farms&&typeof raw.farms==='object'&&!Array.isArray(raw.farms)?Object.keys(raw.farms).map(world):[];
 if(r.farms.length>1000)throw Error('Too many farms');
 r.name=typeof raw.name==='string'?raw.name.slice(0,80):`Bot ${r.bot_index}`;
 r.heartbeat_seconds=integer(raw.heartbeat_seconds??300,0,3600,'heartbeat');r.event_name=typeof raw.event_name==='string'?raw.event_name.slice(0,40):'snapshot';
 r.status=integer(raw.status,0,255,'status');r.phase=text(raw.phase,40,'phase');
 r.world=raw.world?world(raw.world):'EXIT';r.farm=raw.farm?world(raw.farm):null;
 r.x=Number.isFinite(raw.x)?raw.x:null;r.y=Number.isFinite(raw.y)?raw.y:null;
 r.seed_id=integer(raw.seed_id,1,1000000,'seed ID');r.block_id=integer(raw.block_id,1,1000000,'block ID');
 r.inventory={};for(const k of ['seeds','blocks','gems'])r.inventory[k]=raw.inventory?.[k]==null?null:integer(raw.inventory[k],0,Number.MAX_SAFE_INTEGER,k);
 r.counters={};for(const k of ['harvest_attempts','blocks_placed','pnb_hits','seeds_deposited','worlds_completed'])r.counters[k]=integer(raw.counters?.[k]??0,0,Number.MAX_SAFE_INTEGER,k);
 r.last_message=typeof raw.last_message==='string'?raw.last_message.slice(0,300):'';
 if(raw.scan){const a=raw.scan;r.scan={world:world(a.world),observed_at:integer(a.observed_at,1,r.captured_at,'scan time'),trees:integer(a.trees,0,1000000,'trees'),ready:integer(a.ready,0,1000000,'ready'),pass_finished:a.finished===true};if(r.scan.ready>r.scan.trees)throw Error('Invalid ready count');}
 r.scans=[];
 if(raw.scans){if(typeof raw.scans!=='object'||Array.isArray(raw.scans)||Object.keys(raw.scans).length>1000)throw Error('Invalid scan cache');
  for(const a of Object.values(raw.scans)){const v={world:world(a.world),observed_at:integer(a.observed_at,1,r.captured_at,'scan time'),trees:integer(a.trees,0,1000000,'trees'),ready:integer(a.ready,0,1000000,'ready'),pass_finished:a.finished===true};if(v.ready>v.trees)throw Error('Invalid ready count');r.scans.push(v);}
 }
 if(raw.storage){const a=raw.storage;r.storage={world:world(a.world),observed_at:integer(a.observed_at,1,r.captured_at,'storage time'),items:{},stacks:integer(a.stacks,0,1000000,'stacks')};
  if(!a.items||typeof a.items!=='object'||Array.isArray(a.items)||Object.keys(a.items).length>10000)throw Error('Invalid storage items');
  for(const [id,n]of Object.entries(a.items)){if(!/^[1-9][0-9]{0,6}$/.test(id))throw Error('Invalid stored item');r.storage.items[id]=integer(n,0,Number.MAX_SAFE_INTEGER,'stock');}
 }
 return r;
}
export function farmProgress(f){
 const capacity=2645;const known=Number.isFinite(f.trees);
 const remaining=known?f.trees:null;
 const cleared=known?Math.max(0,capacity-remaining):null;
 return {...f,capacity,remaining,cleared,progress_percent:known?Math.min(100,Math.max(0,100*cleared/capacity)):null,harvest_done:known&&remaining===0};
}
export class Store{
 constructor(db,prefix='farm_monitor_'){this.bots=db.collection(prefix+'bots');this.observations=db.collection(prefix+'observations');this.history=db.collection(prefix+'history');this.observedTimes=new Map();}
 async prepare(){await Promise.all([
  this.bots.createIndex({received_at:1},{expireAfterSeconds:30*86400}),
  this.history.createIndex({expires_at:1},{expireAfterSeconds:0}),
  this.history.createIndex({captured_at:-1}),
 ]);return this;}
 async ingest(batch,now=Date.now()){
  if(!Array.isArray(batch)||batch.length<1||batch.length>100)throw Error('Batch must contain 1..100 snapshots');
  const rows=batch.map(x=>validate(x,now));let accepted=0;
  for(const r of rows){
   const newer={$or:[{$gt:[r.captured_at,{$ifNull:['$captured_at',0]}]},{$and:[{$eq:[r.captured_at,'$captured_at']},{$eq:[r.session_id,'$session_id']},{$gt:[r.seq,'$seq']}]}]};
   const id=`${r.agent_id}:${r.bot_index}`;
   const row={_id:id,agent_id:r.agent_id,bot_index:r.bot_index,session_id:r.session_id,seq:r.seq,captured_at:r.captured_at,received_at:new Date(now),snapshot:r};
   const result=await this.bots.updateOne({_id:id},[{$replaceWith:{$cond:[newer,{$literal:row},'$$ROOT']}}],{upsert:true});
   if(!result.modifiedCount&&!result.upsertedCount)continue;accepted++;
   for(const [kind,o]of [['farm',r.scan],...r.scans.map(o=>['farm',o]),['storage',r.storage]])if(o){
    const id=`${r.agent_id}:${kind}:${o.world}`;const seen=this.observedTimes.get(id);if(seen&&(o.observed_at<seen.at||(o.observed_at===seen.at&&(!o.pass_finished||seen.finished))))continue;const row={_id:id,agent_id:r.agent_id,kind,world:o.world,observed_at:o.observed_at,received_at:new Date(now),snapshot:o};
    await this.observations.updateOne({_id:id},[{$replaceWith:{$cond:[{$or:[{$gt:[o.observed_at,{$ifNull:['$observed_at',0]}]},{$and:[{$eq:[o.observed_at,'$observed_at']},{$eq:[o.pass_finished===true,true]},{$ne:['$snapshot.pass_finished',true]}]}]},{$literal:row},'$$ROOT']}}],{upsert:true});
    this.observedTimes.set(id,{at:o.observed_at,finished:o.pass_finished===true});
   }
   const bucket=Math.floor(r.captured_at/60);const hid=`${r.agent_id}:${r.bot_index}:${bucket}`;
   const small={captured_at:r.captured_at,status:r.status,phase:r.phase,farm:r.farm,inventory:r.inventory,counters:r.counters,session_id:r.session_id};
   const hist={_id:hid,agent_id:r.agent_id,bot_index:r.bot_index,captured_at:r.captured_at,expires_at:new Date(now+86400000),snapshot:small};
   await this.history.updateOne({_id:hid},[{$replaceWith:{$cond:[{$gte:[r.captured_at,{$ifNull:['$captured_at',0]}]},{$literal:hist},'$$ROOT']}}],{upsert:true});
  }
  return{accepted,ignored:rows.length-accepted};
 }
 async stats(now=Date.now()){
  const [raw,observations,histories]=await Promise.all([
   this.bots.find({}).sort({agent_id:1,bot_index:1}).limit(10000).toArray(),
   this.observations.find({}).sort({world:1}).limit(10000).toArray(),
   this.history.find({captured_at:{$gt:Math.floor(now/1000)-3600}}).sort({captured_at:1}).limit(100000).toArray(),
  ]);
  const allBots=raw.map(r=>({...r.snapshot,received_at:r.received_at.getTime(),age_seconds:Math.max(0,Math.floor(now/1000)-r.snapshot.captured_at),stale:now/1000-r.snapshot.captured_at>Math.max(120,(r.snapshot.heartbeat_seconds||300)*2+30)}));
  const bots=allBots.filter(b=>!b.stale);
  const farmMap=new Map();for(const b of allBots)for(const world of b.farms||[])farmMap.set(`${b.agent_id}:${world}`,{agent_id:b.agent_id,world,trees:null,ready:null,observed_at:null});
  for(const o of observations.filter(x=>x.kind==='farm'))farmMap.set(`${o.agent_id}:${o.world}`,{...o.snapshot,agent_id:o.agent_id});
  const farms=[...farmMap.values()].sort((a,b)=>a.world.localeCompare(b.world)).map(f=>farmProgress({...f,workers:bots.filter(b=>b.agent_id===f.agent_id&&b.farm===f.world).map(b=>b.bot_index)}));
  const storage=observations.filter(x=>x.kind==='storage').map(x=>({...x.snapshot,agent_id:x.agent_id}));
  const history={};for(const r of histories)(history[`${r.agent_id}:${r.bot_index}`]??=[]).push(r.snapshot);
  return{server_time:now,bots,farms,storage,history,summary:{reporting:bots.filter(b=>!b.stale).length,online:bots.filter(b=>!b.stale&&b.status===1).length,stale:0,hidden_stale:allBots.length-bots.length,carried_seeds:bots.filter(b=>!b.stale).reduce((n,b)=>n+(b.inventory.seeds??0),0)}};
 }
}
export async function getStore(){
 const key=Symbol.for('farm-monitor.mongo');
 if(!globalThis[key])globalThis[key]=(async()=>{if(!process.env.MONGODB_URI)throw Error('Database not configured');const client=new MongoClient(process.env.MONGODB_URI,{maxPoolSize:5,serverSelectionTimeoutMS:5000});await client.connect();return new Store(client.db(process.env.MONGODB_DB||'vendindex')).prepare();})().catch(e=>{delete globalThis[key];throw e;});
 return globalThis[key];
}
