import{reject}from'../../../lib/auth.mjs';import{getStore,validate}from'../../../lib/store.mjs';
export const runtime='nodejs';export const dynamic='force-dynamic';
export async function POST(request){
 const denied=reject(request);if(denied)return denied;let rows;
 try{
  if(Number(request.headers.get('content-length')||0)>1048576)return Response.json({error:'Batch too large'},{status:413});
  const reader=request.body?.getReader();if(!reader)throw Error('Empty request');let size=0;const chunks=[];
  while(true){const{done,value}=await reader.read();if(done)break;size+=value.length;if(size>1048576){await reader.cancel();return Response.json({error:'Batch too large'},{status:413});}chunks.push(Buffer.from(value));}
  rows=JSON.parse(Buffer.concat(chunks).toString('utf8')).snapshots;
  if(!Array.isArray(rows)||rows.length<1||rows.length>100)throw Error('Invalid batch');rows.forEach(r=>validate(r));
 }catch{return Response.json({error:'Invalid snapshot batch'},{status:400});}
 try{return Response.json(await(await getStore()).ingest(rows));}catch{return Response.json({error:'Database unavailable; retry the next report'},{status:503});}
}
