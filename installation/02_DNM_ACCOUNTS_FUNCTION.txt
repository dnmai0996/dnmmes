import {randomBytes,createHash,scrypt as scryptCallback,timingSafeEqual} from 'node:crypto';
import {promisify} from 'node:util';
const scrypt=promisify(scryptCallback);
const sha=s=>createHash('sha256').update(s).digest('hex');
const EMAIL=/^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const WORKER_ID=/^[\p{L}\p{N}._ ()-]{1,80}$/u;
export function normalizeWorkerId(value){const s=String(value||'').trim();if(!WORKER_ID.test(s))throw new AccountError('작업자 성명(ID)을 확인하세요.');return s;}
export class AccountError extends Error{constructor(message,status=400,code='ACCOUNT_ERROR'){super(message);this.status=status;this.code=code;}}
export function normalizeEmail(value){const s=String(value||'').trim().toLowerCase();if(s.length>254||!EMAIL.test(s))throw new AccountError('본인의 정확한 이메일 주소를 입력하세요.');return s;}
export function validateNewPassword(value){
 if(typeof value!=='string'||value.length<12||Buffer.byteLength(value,'utf8')>72||!/\p{L}/u.test(value)||!/\d/.test(value))throw new AccountError('새 비밀번호는 문자와 숫자를 포함한 12자 이상, UTF-8 72바이트 이하로 입력하세요.');
 return value;
}
export async function initialHash(code='1111',salt=randomBytes(16).toString('hex')){return{salt,hash:(await scrypt(code,salt,64)).toString('hex')};}
export async function initialMatches(code,salt,hash){
 if(typeof code!=='string'||code.length>128||!/^([a-f0-9]{32})$/.test(salt||'')||!/^([a-f0-9]{128})$/.test(hash||''))return false;
 const result=await scrypt(code,salt,64);return timingSafeEqual(result,Buffer.from(hash,'hex'));
}
const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json;charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'}});
function configuration(env){
 const url=String(env.DNM_SUPABASE_URL||'').trim().replace(/\/$/,'');
 const key=String(env.DNM_SUPABASE_SECRET_KEY||'').trim();
 if(!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(url)||!key)throw new AccountError('MES 계정 서버에 연결되지 않았습니다. 관리자에게 확인하세요.',503,'SETUP_REQUIRED');
 if(!key.startsWith('sb_secret_')){
  try{const x=JSON.parse(Buffer.from(key.split('.')[1],'base64url').toString());if(x.role!=='service_role')throw Error();}
  catch{throw new AccountError('서버 환경변수에는 Publishable/anon 키가 아닌 Secret key 또는 service_role 키가 필요합니다.',503,'SETUP_REQUIRED');}
 }
 return{url,key};
}
// No user passwords, secret keys, tokens or Supabase raw errors are logged.
export class AccountBackend{
 constructor(env,fetcher=globalThis.fetch){this.c=configuration(env);this.fetcher=(...a)=>fetcher(...a);}
 async call(path,{method='GET',body,token,service=true}={}){
  const headers={apikey:this.c.key,'Content-Type':'application/json'};
  // Modern secret keys work through apikey; legacy service_role also needs its JWT bearer.
  if(token)headers.Authorization='Bearer '+token;else if(!this.c.key.startsWith('sb_secret_'))headers.Authorization='Bearer '+this.c.key;
  let r,text;try{r=await this.fetcher(this.c.url+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000),cache:'no-store'});text=await r.text();}
  catch{throw new AccountError('계정 서버의 응답을 확인하지 못했습니다. 목록을 새로고침하여 상태를 확인하세요.',503,'UPSTREAM_UNAVAILABLE');}
  let data;try{data=text?JSON.parse(text):{};}catch{throw new AccountError('계정 서버 응답을 확인하지 못했습니다.',502,'INVALID_RESPONSE');}
  if(!r.ok){
   if(path.includes('/rpc/dnm_v47_login_lookup')&&(data.code==='PGRST202'||r.status===404))throw new AccountError('이름 로그인 기능 설치가 필요합니다. 관리자에게 확인하세요.',503,'MIGRATION_REQUIRED');
   if(path.includes('/rpc/dnm_v43_service')){
    const msg=data.message||'';
    if(data.code==='PGRST202'||msg.includes('Could not find'))throw new AccountError('Supabase SQL 10_upgrade_v4_3.sql 적용을 확인하세요.',503,'MIGRATION_REQUIRED');
    // Business errors generated in our SQL contain no submitted credentials.
    if(data.code==='P0001'||data.code==='42501')throw new AccountError(msg,409,'ACCOUNT_STATE');
   }
   if(path.startsWith('/auth/v1/token'))throw new AccountError('현재 비밀번호 또는 계정 상태를 확인하세요.',401,'CREDENTIALS_INVALID');
   if(path.startsWith('/auth/v1/admin/')&&r.status===422)throw new AccountError('이메일 중복 또는 비밀번호 정책을 확인하세요. 계정 목록을 새로고침한 후 처리하세요.',409,'AUTH_CONFLICT');
   if(r.status===401||r.status===403)throw new AccountError('로그인 권한 또는 서버 전용 키 설정을 확인하세요.',401,'UNAUTHORIZED');
   if(r.status===429)throw new AccountError('요청 횟수가 많습니다. 잠시 후 다시 시도하세요.',429,'RATE_LIMIT');
   throw new AccountError('계정 서비스가 요청을 처리하지 못했습니다. Supabase 설정과 함수 실행기록을 확인하세요.',502,'UPSTREAM_ERROR');
  }
  return data;
 }
 async rpc(action,p={}){return this.call('/rest/v1/rpc/dnm_v43_service',{method:'POST',body:{p_action:action,p}});}
 async identity(token,admin=false){
  if(!token||token.length>8192)throw new AccountError('관리자 또는 사용자 로그인이 필요합니다.',401,'LOGIN_REQUIRED');
  const user=await this.call('/auth/v1/user',{token});
  if(!UUID.test(user.id||''))throw new AccountError('로그인을 다시 진행하세요.',401,'LOGIN_REQUIRED');
  const ctx=await this.call('/rest/v1/rpc/dnm_v4_context',{token});
  if(ctx?.profile?.id!==user.id||!ctx.profile.active||(admin&&ctx.profile.role!=='admin'))throw new AccountError('이 작업을 수행할 권한이 없습니다.',403,'FORBIDDEN');
  return{user,ctx};
 }
 async throttle(bucket,limit,seconds){if(!(await this.rpc('rate',{bucket,limit,seconds}))?.allowed)throw new AccountError('반복 요청이 제한되었습니다. 잠시 후 다시 시도하거나 관리자에게 확인하세요.',429,'RATE_LIMIT');}
 async reauthenticate(user,password){
  if(typeof password!=='string'||!password||password.length>256)throw new AccountError('현재 비밀번호를 입력하세요.');
  const s=await this.call('/auth/v1/token?grant_type=password',{method:'POST',body:{email:user.email,password}});
  if(s.user?.id!==user.id||!s.access_token)throw new AccountError('계정 확인에 실패했습니다.',401,'CREDENTIALS_INVALID');
  return s;
 }
 async revokeLocal(token){if(token)try{await this.call('/auth/v1/logout?scope=local',{method:'POST',token});}catch{/* no token logging */}}
}
export function createHandler({env=process.env,fetcher=globalThis.fetch,backendFactory}={}){
 return async(request,context={})=>{
  try{
   if(request.method!=='POST')return json({ok:false,message:'POST 요청만 지원합니다.'},405);
   const origin=request.headers.get('origin'),url=new URL(request.url);
   if(!origin||origin!==url.origin)throw new AccountError('같은 사이트에서만 계정 요청을 보낼 수 있습니다.',403,'ORIGIN_DENIED');
   if(!request.headers.get('content-type')?.startsWith('application/json'))throw new AccountError('JSON 형식이 필요합니다.',415,'CONTENT_TYPE');
   if(Number(request.headers.get('content-length')||0)>12000)throw new AccountError('입력 크기를 확인하세요.',413);
   const raw=await request.text();if(Buffer.byteLength(raw)>12000)throw new AccountError('입력 크기를 확인하세요.',413);
   let p;try{p=JSON.parse(raw);}catch{throw new AccountError('입력 형식을 확인하세요.');}
   if(!p||Array.isArray(p)||typeof p!=='object')throw new AccountError('입력 형식을 확인하세요.');
   const b=backendFactory?backendFactory():new AccountBackend(env,fetcher);
   if(p.project_url&&String(p.project_url).replace(/\/$/,'')!==b.c.url)throw new AccountError('프로그램과 계정 서버의 Supabase 프로젝트가 다릅니다.',503,'PROJECT_MISMATCH');
   const token=request.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
   const publicAction=['temporary_login','name_temporary_login','name_login','set_initial_password','public_status'].includes(p.action);
   if(publicAction){
    const ip=context.ip; // trusted Netlify context, never x-forwarded-for from the user
    if(!ip)throw new AccountError('접속환경 확인에 실패했습니다. 회사 MES 주소에서 사용하세요.',503,'CLIENT_IP_REQUIRED');
    const allowed=String(env.DNM_INITIAL_LOGIN_ALLOWED_IPS||'').split(',').map(x=>x.trim()).filter(Boolean);
    if(p.action!=='name_login'&&allowed.length&&!allowed.includes(ip))throw new AccountError('초기 비밀번호 설정은 관리자가 허용한 회사 네트워크에서 진행하세요.',403,'NETWORK_RESTRICTED');
    await b.throttle('ip:'+sha(ip),ip==='supabase-edge'?1200:120,900);
   }
   if(p.action==='public_status'){await b.rpc('health');return json({ok:true,version:'4.9.0'});}
   if(p.action==='name_login'||p.action==='name_temporary_login'){
    const loginId=normalizeWorkerId(p.login_id);
    await b.throttle('worker-id:'+sha(loginId.toLowerCase()),p.action==='name_login'?20:5,900);
    const info=await b.call('/rest/v1/rpc/dnm_v47_login_lookup',{method:'POST',body:{p_login:loginId}});
    if(p.action==='name_login'){
     if(!info?.email||info.state!=='ready'||info.enabled!==true||!UUID.test(info.profile_id||''))throw new AccountError('로그인 ID 또는 비밀번호를 확인하세요.',401,'CREDENTIALS_INVALID');
     if(typeof p.password!=='string'||!p.password||p.password.length>256)throw new AccountError('로그인 ID 또는 비밀번호를 확인하세요.',401,'CREDENTIALS_INVALID');
     let session;
     try{session=await b.call('/auth/v1/token?grant_type=password',{method:'POST',body:{email:info.email,password:p.password}});}
     catch(e){if(e.code==='CREDENTIALS_INVALID'||e.status===401)throw new AccountError('로그인 ID 또는 비밀번호를 확인하세요.',401,'CREDENTIALS_INVALID');throw e;}
     if(!session?.access_token||!session?.refresh_token||session.user?.id!==info.profile_id)throw new AccountError('로그인 ID 또는 비밀번호를 확인하세요.',401,'CREDENTIALS_INVALID');
     const identity=await b.identity(session.access_token);
     if(identity.user.id!==info.profile_id||identity.ctx.profile.role==='admin')throw new AccountError('이 계정은 사용할 수 없습니다.',403,'ACCOUNT_DISABLED');
     return json({ok:true,session}); // Supabase-issued worker token only. Never a service key.
    }
    const email=info?.state==='pending'&&info.enabled===true&&info.email?info.email:null;
    if(!email)throw new AccountError('초기 로그인 정보를 확인할 수 없습니다. 관리자에게 초기화를 요청하세요.',401,'INITIAL_LOGIN_INVALID');
    await b.throttle('email:'+sha(email),5,900);
    const c=await b.rpc('probe',{email});
    const valid=await initialMatches(String(p.password||''),c?.salt||'0'.repeat(32),c?.hash||'0'.repeat(128));
    if(!c.valid||!valid||c.profile_id!==info.profile_id)throw new AccountError('초기 로그인 정보를 확인할 수 없습니다. 관리자에게 초기화를 요청하세요.',401,'INITIAL_LOGIN_INVALID');
    const ticket=randomBytes(32).toString('base64url');
    const result=await b.rpc('issue_ticket',{profile_id:c.profile_id,generation:c.generation,hash:sha(ticket)});
    return json({ok:true,requires_password_change:true,ticket,login_id:info.login_id,expires_at:result.expires_at});
   }
   if(p.action==='temporary_login'){
    const email=normalizeEmail(p.email);await b.throttle('email:'+sha(email),5,900);
    const c=await b.rpc('probe',{email});
    // Run a comparable hash for unknown users; no account existence oracle in the reply.
    const valid=await initialMatches(String(p.password||''),c?.salt||'0'.repeat(32),c?.hash||'0'.repeat(128));
    if(!c.valid||!valid)throw new AccountError('초기 로그인 정보를 확인할 수 없습니다. 관리자에게 사용자 등록 또는 초기화를 요청하세요.',401,'INITIAL_LOGIN_INVALID');
    const ticket=randomBytes(32).toString('base64url');
    const result=await b.rpc('issue_ticket',{profile_id:c.profile_id,generation:c.generation,hash:sha(ticket)});
    return json({ok:true,requires_password_change:true,ticket,email,expires_at:result.expires_at});
   }
   if(p.action==='set_initial_password'){
    validateNewPassword(p.password);
    if(p.password!==p.repeat)throw new AccountError('새 비밀번호와 확인값이 다릅니다.');
    if(typeof p.ticket!=='string'||!/^[-_a-zA-Z0-9]{43}$/.test(p.ticket))throw new AccountError('초기 로그인부터 다시 진행하세요.',401,'TICKET_INVALID');
    const hash=sha(p.ticket);const c=await b.rpc('begin_change',{hash});
    try{
     await b.call('/auth/v1/admin/users/'+c.profile_id,{method:'PUT',body:{password:p.password}});
     await b.rpc('finish_change',{hash});
     return json({ok:true,message:'비밀번호를 설정했습니다. 본인 이름(ID)과 새 비밀번호로 로그인하세요.'});
    }catch(e){try{await b.rpc('change_failed',{hash});}catch{}throw new AccountError('설정 완료를 확인하지 못했습니다. 새 비밀번호로 로그인해 보고, 차단되면 관리자에게 초기화를 다시 요청하세요.',503,'PASSWORD_SETUP_UNCERTAIN');}
   }
   if(p.action==='change_password'){
    const {user}=await b.identity(token);validateNewPassword(p.password);
    if(p.password!==p.repeat)throw new AccountError('새 비밀번호 확인값이 다릅니다.');
    if(p.current===p.password)throw new AccountError('기존과 다른 비밀번호를 사용하세요.');
    await b.throttle('self:'+user.id,5,900);
    let s;
    try{
     s=await b.reauthenticate(user,p.current);
     await b.call('/auth/v1/user',{method:'PUT',token:s.access_token,body:{password:p.password,current_password:p.current}});
     await b.rpc('self_changed',{profile_id:user.id});
     return json({ok:true,message:'비밀번호를 변경했습니다. 모든 기기에서 새 비밀번호로 다시 로그인하세요.'});
    }finally{await b.revokeLocal(s?.access_token);}
   }
   const {user,ctx}=await b.identity(token,true);
   let automaticEnrollment=false;
   if(p.action==='ensure_worker'){
    automaticEnrollment=true;
    if(!UUID.test(p.employee_id||''))throw new AccountError('작업자를 확인하세요.');
    const list=await b.call('/rest/v1/rpc/dnm_v49_accounts',{method:'POST',body:{},token});
    if(list.worker_management!=='4.9.0')throw new AccountError('작업자 자동계정 SQL 설치가 필요합니다.',503,'MIGRATION_REQUIRED');
    const w=(list.workers||[]).find(w=>w.id===p.employee_id);
    if(!w)throw new AccountError('등록되지 않은 작업자입니다.');
    if(!w.employee_active||w.protected||w.profile_id)return json({ok:true,skipped:true,employee_id:w.id});
    p.action='provision';p.version=w.version;p.request_id=crypto.randomUUID();p.email='';
    p.reason='사용 작업자 자동 로그인 계정 연결';p.confirm_owner=true;
   }
   if(p.action==='status'){await b.rpc('health');return json({ok:true,version:'4.9.0',project_url:b.c.url});}
   if(!['provision','reset','disable'].includes(p.action))throw new AccountError('지원하지 않는 계정 작업입니다.');
   if(!UUID.test(p.employee_id||'')||!UUID.test(p.request_id||'')||!Number.isInteger(p.version))throw new AccountError('작업자 목록을 새로고침한 후 다시 선택하세요.');
   const email=p.action==='provision'&&!String(p.email||'').trim() ? 'worker-'+p.employee_id.toLowerCase()+'@dnm.example' : normalizeEmail(p.email);
   if(p.confirm_owner!==true)throw new AccountError('실제 작업자 재직상태를 확인하세요.');
   if(typeof p.reason!=='string'||p.reason.trim().length<2||p.reason.length>1000)throw new AccountError('변경 사유를 입력하세요.');
   await b.throttle('admin:'+user.id,100,900);
   // Resets/disables require the administrator to re-enter their own password.
   if(p.action!=='provision'){const s=await b.reauthenticate(user,p.admin_password);await b.revokeLocal(s.access_token);}
   const details={auto_provision:automaticEnrollment,actor_id:user.id,employee_id:p.employee_id,request_id:p.request_id,action:p.action,email,version:p.version,reason:p.reason};
   const plan=await b.rpc('prepare',details);
   if(plan.done)return json(plan.result);
   try{
    const randomPassword='Dn!'+randomBytes(36).toString('base64url')+'7a';
    let uid=plan.profile_id;
    if(plan.new_user){const created=await b.call('/auth/v1/admin/users',{method:'POST',body:{email:plan.email,password:randomPassword,email_confirm:true,user_metadata:{display_name:plan.name,dnm_employee_id:plan.employee_id}}});uid=created.id||created.user?.id;}
    else {
     if(automaticEnrollment){const existing=await b.call('/auth/v1/admin/users/'+uid);if((existing.user_metadata||existing.user?.user_metadata)?.dnm_employee_id!==p.employee_id)throw new AccountError('동일한 내부 ID의 기존 계정이 있습니다. 기존 비밀번호는 변경하지 않았습니다. 관리자 확인이 필요합니다.',409,'ACCOUNT_CONFLICT');}
     await b.call('/auth/v1/admin/users/'+uid,{method:'PUT',body:{password:randomPassword,email_confirm:true}});
    }
    if(!UUID.test(uid||''))throw new AccountError('계정 생성 결과를 확인하지 못했습니다.',502);
    const code=await initialHash();
    const result=await b.rpc('finish',{actor_id:user.id,request_id:p.request_id,profile_id:uid,...code});
    try{await b.rpc('clear_rate',{email_hash:sha(email)});}catch{/* account creation succeeded; optional counter cleanup must not make it fail */}
    return json({...result,message:'계정이 준비되었습니다. 본인 이름(ID)과 초기번호 1111로 로그인하도록 안내하세요.'});
   }catch(e){try{await b.rpc('failed',{actor_id:user.id,request_id:p.request_id});}catch{}throw new AccountError(e.message+' 계정이 부분 생성되었을 수 있습니다. 목록 새로고침 후 상태를 확인하고 다시 등록·초기화하세요.',e.status||503,'ACCOUNT_OPERATION_FAILED');}
  }catch(e){
   return json({ok:false,code:e instanceof AccountError?e.code:'ACCOUNT_INTERNAL_ERROR',message:e instanceof AccountError?e.message:'계정 처리 중 오류가 발생했습니다. 관리자에게 확인하세요.'},e instanceof AccountError?e.status:500);
  }
 };
}

// Supabase-hosted worker authentication server. Never expose server secret to public.
const ALLOWED_ORIGINS=new Set(['https://dnmmes.netlify.app','http://localhost:3000','http://localhost:4173','http://127.0.0.1:3000','http://127.0.0.1:4173']);
function cors(origin){return{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Max-Age':'600','Vary':'Origin'};}
function getSecret(){
 const raw=Deno.env.get('SUPABASE_SECRET_KEYS');
 if(raw){try{const keys=JSON.parse(raw);if(keys.default)return keys.default;}catch{}}
 return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||'';
}
Deno.serve(async request=>{
 const origin=request.headers.get('origin')||'';
 if(!ALLOWED_ORIGINS.has(origin))return Response.json({ok:false,message:'허용되지 않은 사이트입니다.'},{status:403});
 if(request.method==='OPTIONS')return new Response(null,{status:204,headers:cors(origin)});
 if(request.method!=='POST')return Response.json({ok:false,message:'지원하지 않는 요청입니다.'},{status:405,headers:cors(origin)});
 const env={DNM_SUPABASE_URL:Deno.env.get('SUPABASE_URL')||'',DNM_SUPABASE_SECRET_KEY:getSecret(),DNM_INITIAL_LOGIN_ALLOWED_IPS:''};
 const handler=createHandler({env});
 const adapted=new Request(origin+'/.netlify/functions/dnm-accounts',{method:request.method,headers:request.headers,body:await request.text()});
 // Shared IP bucket deliberately avoids trusting arbitrary client-sent proxy-IP headers.
 // Per-worker and per-email buckets add separate rate limits in database.
 const response=await handler(adapted,{ip:'supabase-edge'});
 const headers=new Headers(response.headers);Object.entries(cors(origin)).forEach(([k,v])=>headers.set(k,v));
 return new Response(response.body,{status:response.status,headers});
});
