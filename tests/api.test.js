import test from 'node:test';
import assert from 'node:assert/strict';
import {PortalApi} from '../public/api.js';
const memory=()=>{const m=new Map();return {getItem:k=>m.get(k)||null,setItem:(k,v)=>m.set(k,v),removeItem:k=>m.delete(k)};};
const session=()=>({access_token:'old',refresh_token:'refresh',expires_at:Math.floor(Date.now()/1000)+3600,user:{id:'user-1'}});
const response=(data,status=200,headers={})=>new Response(JSON.stringify(data),{status,headers});
function apiWith(fetcher){const api=new PortalApi({url:'https://example.supabase.co',key:'sb_publishable_example'},{storage:memory(),fetcher});api.keep(session());return api;}
test('a write requires authentication before any network call',async()=>{
 let calls=0;const api=apiWith(async()=>{calls++;});api.keep(null);
 await assert.rejects(()=>api.save('notes',{title:'a',body:'b'}),/로그인/);assert.equal(calls,0);
});
test('read sends public key plus user token and parses shared total',async()=>{
 const api=apiWith(async(u,o)=>{assert.equal(o.headers.apikey,'sb_publishable_example');assert.equal(o.headers.Authorization,'Bearer old');assert.equal(o.cache,'no-store');return response([{id:'n'}],200,{'content-range':'0-0/6'});});
 const r=await api.rows('notes');assert.equal(r.total,6);assert.equal(r.data[0].id,'n');
});
test('edit is conditional on record version and does not overwrite a conflict',async()=>{
 let calls=0;const api=apiWith(async(u,o)=>{calls++;assert.match(u,/id=eq.n1&version=eq.4$/);assert.equal(o.method,'PATCH');return response([]);});
 await assert.rejects(()=>api.save('notes',{title:'a',body:'b'},{id:'n1',version:4}),/다른 사용자/);assert.equal(calls,1);
});
test('duplicate and permission errors are visible to the user',async()=>{
 let api=apiWith(async()=>response({code:'23505'},409));await assert.rejects(()=>api.save('products',{}),/이미 등록/);
 api=apiWith(async()=>response({code:'42501'},403));await assert.rejects(()=>api.save('products',{}),/사용 권한/);
});
test('ambiguous failed write is not silently retried or reported as saved',async()=>{
 let calls=0;const api=apiWith(async()=>{calls++;throw Error('connection lost');});
 await assert.rejects(()=>api.save('notes',{}),e=>e.unknown===true&&/목록/.test(e.message));assert.equal(calls,1);
});
test('truncated response after write is also treated as an uncertain result',async()=>{
 const api=apiWith(async()=>new Response('{"id":', {status:201}));
 await assert.rejects(()=>api.save('notes',{}),e=>e.unknown===true&&/저장됐을 수/.test(e.message));
});
test('expired session refreshes once for simultaneous reads',async()=>{
 let refreshes=0;const api=apiWith(async(u,o)=>{
  if(u.includes('refresh_token')){refreshes++;await new Promise(resolve=>setTimeout(resolve,10));return response({...session(),access_token:'new'});}
  assert.equal(o.headers.Authorization,'Bearer new');return response([]);
 });api.keep({...session(),expires_at:1});
 await Promise.all([api.rows('notes'),api.rows('products')]);assert.equal(refreshes,1);
});
test('401 triggers one token refresh and a single retry',async()=>{
 let reads=0,refreshes=0;const api=apiWith(async u=>{if(u.includes('refresh_token')){refreshes++;return response({...session(),access_token:'new'});}reads++;return reads===1?response({},401):response([{id:'ok'}]);});
 assert.equal((await api.rows('notes')).data[0].id,'ok');assert.equal(reads,2);assert.equal(refreshes,1);
});
test('failed refresh clears session; logout clears session even on network failure',async()=>{
 const api=apiWith(async()=>response({},400));api.keep({...session(),expires_at:1});await assert.rejects(()=>api.rows('notes'),/만료/);assert.equal(api.session,null);
 const a=apiWith(async()=>{throw Error('offline');});await assert.rejects(()=>a.logout());assert.equal(a.session,null);
});
test('failed login connection never displays data-save instructions or echoes credentials',async()=>{
 const api=apiWith(async()=>{throw Error('network');});api.keep(null);
 await assert.rejects(()=>api.login('person@example.test','private-password'),e=>e.code==='CONNECTION_FAILED'&&e.unknown===false&&/로그인 서버/.test(e.message)&&!/저장됐|private-password|person@example/.test(e.message));
 assert.equal(api.session,null);
});
test('login timeout has an explicit code without implying a database write',async()=>{
 const api=apiWith(async()=>{const e=Error('timeout');e.name='TimeoutError';throw e;});api.keep(null);
 await assert.rejects(()=>api.login('person@example.test','private-password'),e=>e.code==='TIMEOUT'&&!e.unknown&&!/저장/.test(e.message));
});
test('connection check sends only public key, no password or user authorization',async()=>{
 let calls=0;const api=apiWith(async(u,o)=>{calls++;assert.match(u,/\/auth\/v1\/settings$/);assert.equal(o.method,'GET');assert.equal(o.headers.Authorization,undefined);assert.equal(o.body,undefined);return response({external:{email:true}});});
 const r=await api.checkConnection();assert.equal(r.emailEnabled,true);assert.equal(calls,1);
});
test('diagnostic reports email authentication disabled separately from reachability',async()=>{
 const api=apiWith(async()=>response({external:{email:false}}));assert.equal((await api.checkConnection()).emailEnabled,false);
});
test('diagnostic rejects invalid public key with status, without blaming the password',async()=>{
 const api=apiWith(async()=>response({message:'Invalid API key'},401));
 await assert.rejects(()=>api.checkConnection(),e=>e.status===401&&/공개용 키/.test(e.message)&&!/비밀번호/.test(e.message));
});
test('diagnostic preserves HTTP status even when a proxy returns HTML',async()=>{
 const api=apiWith(async()=>new Response('<h1>Unavailable</h1>',{status:503}));
 await assert.rejects(()=>api.checkConnection(),e=>e.status===503&&e.code==='HTTP_503');
});
test('malformed settings and login responses cannot produce false success',async()=>{
 const api=apiWith(async()=>response({ok:true}));api.keep(null);
 await assert.rejects(()=>api.checkConnection(),e=>e.code==='INVALID_RESPONSE');
 await assert.rejects(()=>api.login('person@example.test','password'),e=>e.code==='INVALID_RESPONSE'&&!e.unknown);
 assert.equal(api.session,null);
});
