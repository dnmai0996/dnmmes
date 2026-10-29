import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdtemp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHandler} from '../server/accounts-service.mjs';
import {AccountService} from '../public/modules/accounts.js';
const BASE=new URL('../',import.meta.url), read=async p=>readFile(new URL(p,BASE),'utf8');
const UID='00000000-0000-4000-a000-000000000011';const ID='00000000-0000-4000-a000-000000000012';
const ORIGIN='https://dnmmes.netlify.app',PROJECT='https://dnm-test.supabase.co';
test('no Netlify secret configuration, name login goes to Supabase Edge Function',async()=>{
 const calls=[];const api={c:{url:PROJECT,key:'sb_publishable_TEST'},session:null,fetcher:async(url,opts)=>{calls.push({url,opts});return Response.json({ok:true});}};
 await new AccountService(api).request('public_status',{},false);
 assert.equal(calls[0].url,`${PROJECT}/functions/v1/dnm-accounts`);
 assert.equal(calls[0].opts.headers.apikey,'sb_publishable_TEST');
 assert.equal(calls[0].opts.headers.Authorization,undefined);
 assert.equal(calls[0].opts.credentials,'omit');
});
test('new worker registration uses internal Auth identifier only, without personal email',async()=>{
 const calls=[],backend={c:{url:PROJECT},async identity(){return {user:{id:'00000000-0000-4000-a000-000000000001'},ctx:{profile:{role:'admin'}}};},async throttle(){},
 async rpc(action,args){calls.push(['rpc',action,args]);return action==='prepare'?{done:false,new_user:true,email:args.email,employee_id:UID,name:'검수 작업자'}:{ok:true};},
 async call(path,opts){calls.push(['call',path,opts]);return path==='/auth/v1/admin/users'?{id:'00000000-0000-4000-a000-000000000002'}:{};}};
 const h=createHandler({backendFactory:()=>backend});
 const request=new Request(`${ORIGIN}/.netlify/functions/dnm-accounts`,{method:'POST',headers:{origin:ORIGIN,'Content-Type':'application/json',Authorization:'Bearer admin'},body:JSON.stringify({action:'provision',project_url:PROJECT,employee_id:UID,request_id:ID,version:1,email:'',reason:'현재 재직 확인',confirm_owner:true})});
 const response=await h(request,{ip:'198.51.100.42'});
 assert.equal(response.status,200);
 const email=`worker-${UID}@dnm.example`;
 assert.equal(calls.find(x=>x[1]==='prepare')[2].email,email);
 assert.equal(calls.find(x=>x[1]==='/auth/v1/admin/users')[2].body.email,email);
 const body=JSON.stringify(await response.json());
 assert.ok(!body.includes('code_hash')&&!body.includes('sb_secret_'));
});
test('workmaster active state and atomic role save use access checks and preserve historic data',async()=>{
 const sql=await read('database/20_upgrade_v4_8_worker_login.sql');
 for(const v of ['dnm_v48_set_worker_active','dnm_v48_worker_master_state','dnm_private.sync_worker_login','dnm_v48_set_access','role=p_role','dnm_v42_set_access','auth.role() IS DISTINCT FROM \'service_role\''])assert.ok(sql.includes(v),v);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION public\.dnm_v48_set_worker_active\(uuid,boolean,text\) TO authenticated/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION public\.dnm_v48_set_access\(uuid,text,jsonb,boolean,numeric,date,text\) TO authenticated/);
 assert.doesNotMatch(sql,/\b(?:DROP TABLE|TRUNCATE|DELETE FROM auth\.)/i);
});
test('ACL edit handles viewer/member in one server request',async()=>{
 const js=await read('public/modules/v42.js');
 assert.match(js,/select\('baseRole','기본역할'/);
 assert.match(js,/this\.rpc\('dnm_v48_set_access'/);
 assert.match(js,/\$\('#aclBaseRole'\)\.value='member'/);
});
test('Edge wrapper rejects other origins and does not disclose its keys',async()=>{
 const js=await read('supabase/functions/dnm-accounts/index.ts');
 assert.match(js,/Deno\.env\.get\('SUPABASE_SECRET_KEYS'\)/);
 const dest=join(await mkdtemp(join(tmpdir(),'dnm-edge-')),'index.mjs');await writeFile(dest,js);
 let handler,spy=[];const oldDeno=globalThis.Deno,oldFetch=globalThis.fetch;
 try{
  globalThis.Deno={env:{get:key=>({SUPABASE_URL:PROJECT,SUPABASE_SECRET_KEYS:JSON.stringify({default:'sb_secret_FAKE_TEST'})}[key]||'')},serve:fn=>handler=fn};
  globalThis.fetch=async (url,opts)=>{spy.push({url,opts});const b=JSON.parse(opts.body||'{}');return Response.json(b.p_action==='rate'?{allowed:true}:{ok:true});};
  await import(pathToFileURL(dest).href);
  const pre=await handler(new Request(`${PROJECT}/functions/v1/dnm-accounts`,{method:'OPTIONS',headers:{origin:ORIGIN}}));
  assert.equal(pre.status,204);assert.equal(pre.headers.get('access-control-allow-origin'),ORIGIN);
  const blocked=await handler(new Request(`${PROJECT}/functions/v1/dnm-accounts`,{method:'POST',headers:{origin:'https://evil.netlify.app'}}));assert.equal(blocked.status,403);
  const req=new Request(`${PROJECT}/functions/v1/dnm-accounts`,{method:'POST',headers:{origin:ORIGIN,apikey:'sb_publishable_TEST','Content-Type':'application/json'},body:JSON.stringify({action:'public_status',project_url:PROJECT})});
  const response=await handler(req);assert.equal(response.status,200);assert.equal((await response.json()).version,'4.8.0');
  assert.equal(spy.length,2);assert.ok(spy.every(x=>x.opts.headers.apikey==='sb_secret_FAKE_TEST'));
 } finally {globalThis.Deno=oldDeno;globalThis.fetch=oldFetch;}
});
