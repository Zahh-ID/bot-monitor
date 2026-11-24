import{reject}from'../../../lib/auth.mjs';import{getStore}from'../../../lib/store.mjs';
export const runtime='nodejs';export const dynamic='force-dynamic';
export async function GET(request){const denied=reject(request);if(denied)return denied;try{return Response.json(await (await getStore()).stats(),{headers:{'Cache-Control':'no-store'}});}catch{return Response.json({error:'Database unavailable; check server connection settings'},{status:503});}}
