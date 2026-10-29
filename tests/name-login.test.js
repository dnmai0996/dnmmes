import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {initialHash,createHandler,normalizeWorkerId,AccountError} from '../server/accounts-service.mjs';
import {AccountService} from '../public/modules/accounts.js';
const PROJECT='https://dnm-test.supabase.co', ORIGIN='https://dnm-test.netlify.app';
const UID='00000000-0000-4000-a000-000000000002';
function req(body){return new Request(ORIGIN+'/.netlify/functions/dnm-accounts',{method:'POST',headers:{Origin:ORIGIN,'Content-Type':'application/json'},body:JSON.stringify(body)});}
async function mock(opts={}){
 const calls=[];const initial=await initialHash(),st={pending:opts.pending||false,enabled:opts.enabled!==false,unknown:opts.unknown||false,role:opts.role||'member',bad:opts.bad||false,allowRate:opts.rate!==false,expired:opts.expired||false};
 const b={c:{url:PROJECT},calls,st,
  async throttle(...a){calls.push(['throttle',...a]);if(!st.allowRate)throw new AccountError('제한',429,'RATE_LIMIT');},
  async identity(token,admin){calls.push(['identity',token,admin]);if(token!=='worker-token')throw new AccountError('로그인 오류',401);return{user:{id:UID},ctx:{profile:{id:UID,active:true,role:st.role}}};},
  async rpc(action,data){calls.push(['rpc',action,data]);if(action==='probe')return{valid:st.pending&&!st.expired,profile_id:UID,generation:'00000000-0000-4000-a000-000000000003',...initial};if(action==='issue_ticket')return{ok:true,expires_at:'2099-01-01T00:00:00Z'};return{ok:true};},
  async call(path,args){calls.push(['call',path,args]);if(path.includes('dnm_v47_login_lookup'))return st.unknown?{}:{email:'worker@example.invalid',profile_id:UID,login_id:'김영희',enabled:st.enabled,state:st.pending?'pending':'ready',name:'김영희'};
   if(path.includes('token?grant_type=password')){if(st.bad)throw new AccountError('Bad email or password',401,'CREDENTIALS_INVALID');return{access_token:'worker-token',refresh_token:'refresh-token',user:{id:UID},expires_in:3600};}
   return{};}
 };return b;
}
async function run(b,body,env={}){const h=createHandler({backendFactory:()=>b,env});const r=await h(req({...body,project_url:PROJECT}),{ip:'192.0.2.30'});return{status:r.status,body:await r.json()};}

test('Korean worker names accepted, email and control characters disallowed',()=>{
 assert.equal(normalizeWorkerId('  김영희  '),'김영희');
 assert.equal(normalizeWorkerId('박영진-2'),'박영진-2');
 for(const x of ['', 'a@company.com','홍\n길동','X'.repeat(81)])assert.throws(()=>normalizeWorkerId(x));
});
test('name login resolves identity only on Netlify server and verifies Supabase password',async()=>{
 const b=await mock();const r=await run(b,{action:'name_login',login_id:'김영희',password:'Strong-Pw-2026!'});
 assert.equal(r.status,200);assert.equal(r.body.session.access_token,'worker-token');
 assert.ok(b.calls.some(x=>x[0]==='call'&&x[1].includes('dnm_v47_login_lookup')));
 assert.ok(b.calls.some(x=>x[0]==='call'&&x[1].includes('grant_type=password')&&x[2].body.email==='worker@example.invalid'));
 assert.ok(b.calls.some(x=>x[0]==='identity'&&x[1]==='worker-token'));
 assert.ok(!('email' in r.body));
});
test('name login never returns session for unknown, disabled, wrong password or admin',async()=>{
 for(const o of [{unknown:true},{enabled:false},{bad:true},{role:'admin'},{pending:true}]){
  const b=await mock(o);const r=await run(b,{action:'name_login',login_id:'김영희',password:'Strong-Pw-2026!'});
  assert.notEqual(r.status,200);assert.ok(!r.body.session);
 }
});
test('name login does not inherit initial-password network allowlist',async()=>{
 const b=await mock();const r=await run(b,{action:'name_login',login_id:'김영희',password:'Strong-Pw-2026!'},{DNM_INITIAL_LOGIN_ALLOWED_IPS:'198.51.100.2'});
 assert.equal(r.status,200);
});
test('initial 1111 with worker name issues ticket, never a Supabase session or email address',async()=>{
 const b=await mock({pending:true});const r=await run(b,{action:'name_temporary_login',login_id:'김영희',password:'1111'});
 assert.equal(r.status,200);assert.equal(r.body.login_id,'김영희');assert.match(r.body.ticket,/^[A-Za-z0-9_-]{43}$/);
 assert.ok(!('session' in r.body));assert.ok(!('email' in r.body));
 assert.equal(b.calls.some(x=>x[0]==='call'&&x[1].includes('grant_type=password')),false);
});
test('invalid initial credentials and expired or disabled account rejected',async()=>{
 for(const opts of [{pending:true,expired:true},{pending:true,enabled:false},{unknown:true}]){
  const b=await mock(opts);const r=await run(b,{action:'name_temporary_login',login_id:'김영희',password:'1111'});
  assert.notEqual(r.status,200);assert.ok(!r.body.ticket);
 }
 const b=await mock({pending:true});const r=await run(b,{action:'name_temporary_login',login_id:'김영희',password:'2222'});assert.equal(r.status,401);
});
test('public worker login is rate-limited and does not allow credential leakage',async()=>{
 const b=await mock({rate:false});const r=await run(b,{action:'name_login',login_id:'김영희',password:'SECRET_DO_NOT_ECHO'});
 assert.equal(r.status,429);assert.ok(!JSON.stringify(r.body).includes('SECRET_DO_NOT_ECHO'));
});
test('frontend names are sent only to same-origin Netlify server and not to Supabase public lookup',async()=>{
 const calls=[];const api={c:{url:PROJECT},session:null,fetcher:async(u,o)=>{calls.push([u,o]);return new Response(JSON.stringify({ok:true,session:{access_token:'worker-token'}}));}};
 await new AccountService(api).loginName('김영희','PRIVATE_PASSWORD');
 assert.equal(calls[0][0],PROJECT+'/functions/v1/dnm-accounts');
 assert.equal(calls[0][1].credentials,'omit');
 assert.equal(calls[0][1].headers.Authorization,undefined);
 assert.equal(JSON.parse(calls[0][1].body).action,'name_login');
});
test('SQL migration keeps names server-only, creates unique worker IDs, grants admin-only list',()=>{
 const sql=readFileSync(new URL('../database/18_upgrade_v4_7_name_login.sql',import.meta.url),'utf8');
 assert.match(sql,/ALTER TABLE dnm_private\.login_controls ADD COLUMN IF NOT EXISTS login_id/);
 assert.match(sql,/CREATE UNIQUE INDEX IF NOT EXISTS dnm_v47_worker_login_id_unique/);
 assert.match(sql,/dnm_v47_assign_worker_login_id/);
 assert.match(sql,/GRANT EXECUTE ON FUNCTION public\.dnm_v47_login_lookup\(text\) TO service_role/);
 assert.match(sql,/REVOKE ALL ON FUNCTION public\.dnm_v47_login_lookup\(text\) FROM PUBLIC,anon,authenticated/);
 assert.match(sql,/IF public\.dnm_portal_role\(\) IS DISTINCT FROM 'admin'/);
 assert.doesNotMatch(sql,/\b(?:DROP TABLE|TRUNCATE|DELETE FROM public\.|DELETE FROM auth\.)/i);
});
