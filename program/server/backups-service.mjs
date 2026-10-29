import {AccountBackend,AccountError} from './accounts-service.mjs';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const reply=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json;charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
export function createBackupHandler({env=process.env,fetcher=globalThis.fetch,backendFactory}={}){
 return async request=>{
  let b,reauth;
  try{
   if(request.method!=='POST')return reply({ok:false,message:'프로그램의 복원 버튼을 이용하세요.'},405);
   if(request.headers.get('origin')!==new URL(request.url).origin)throw new AccountError('같은 사이트에서만 복원할 수 있습니다.',403);
   if(!request.headers.get('content-type')?.startsWith('application/json'))throw new AccountError('입력 형식을 확인하세요.',415);
   if(Number(request.headers.get('content-length')||0)>6000)throw new AccountError('입력 크기를 확인하세요.',413);
   const raw=await request.text();if(Buffer.byteLength(raw)>6000)throw new AccountError('입력 크기를 확인하세요.',413);
   let p;try{p=JSON.parse(raw);}catch{throw new AccountError('입력 형식을 확인하세요.');}
   if(p?.action!=='restore'||!UUID.test(p.stage_id||'')||!UUID.test(p.safety_id||'')||p.confirmation!=='백업시점복원'||typeof p.reason!=='string'||p.reason.trim().length<2||p.reason.length>500)throw new AccountError('검사한 파일·확인문구·복원 사유를 확인하세요.');
   b=backendFactory?backendFactory():new AccountBackend(env,fetcher);
   if(String(p.project_url||'').replace(/\/$/,'')!==b.c.url)throw new AccountError('회사 연결설정을 확인하세요.',503,'PROJECT_MISMATCH');
   const token=request.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
   const {user}=await b.identity(token,true);
   await b.throttle('restore:'+user.id,5,900);
   reauth=await b.reauthenticate(user,p.admin_password);
   const headers={apikey:b.c.key,'Content-Type':'application/json'};if(!b.c.key.startsWith('sb_secret_'))headers.Authorization='Bearer '+b.c.key;
   let r,x;try{
    r=await fetcher(b.c.url+'/rest/v1/rpc/dnm_v44_restore_apply',{method:'POST',headers,cache:'no-store',signal:AbortSignal.timeout(40000),body:JSON.stringify({p_actor:user.id,p_stage:p.stage_id,p_safety:p.safety_id,p_reason:p.reason.trim(),p_confirmation:p.confirmation})});x=await r.json();
   }catch{throw new AccountError('복원 결과를 아직 확인하지 못했습니다. 반복 실행하지 말고 다시 로그인하여 백업·복원 내역을 확인하세요.',503,'RESTORE_UNCERTAIN');}
   if(!r.ok){
    if(['P0001','42501'].includes(x?.code))throw new AccountError(x.message,409,'RESTORE_NOT_APPLIED');
    if(x?.code==='57014'||x?.code==='55P03')throw new AccountError('처리시간 초과 또는 다른 작업과 충돌하여 복원이 취소되었습니다. 업무자료는 복원 전 상태로 유지됩니다. 담당자에게 Help의 점검사항을 전달하세요.',409,'RESTORE_NOT_APPLIED');
    if(x?.code==='PGRST202')throw new AccountError('백업 업데이트 설치를 완료한 뒤 다시 시도하세요. Help의 설치 안내를 확인하세요.',503,'MIGRATION_REQUIRED');
    throw new AccountError('복원 검증을 통과하지 못하여 적용하지 않았습니다. 관리자에게 확인하세요.',409,'RESTORE_NOT_APPLIED');
   }
   if(x?.applied!==true)throw new AccountError('복원 결과를 확인하지 못했습니다. 다시 로그인하여 처리 내역을 확인하세요.',503,'RESTORE_UNCERTAIN');
   return reply({...x,ok:true});
  }catch(e){return reply({ok:false,code:e instanceof AccountError?e.code:'RESTORE_ERROR',message:e instanceof AccountError?e.message:'복원 요청을 처리하지 못했습니다.'},e instanceof AccountError?e.status:500);}
  finally{if(b&&reauth?.access_token)await b.revokeLocal(reauth.access_token);}
 };
}
