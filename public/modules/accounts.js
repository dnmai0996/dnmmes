// Frontend carries user JWTs only. Service-role/secret keys stay in Supabase Edge Functions.
export class AccountService{
 constructor(api){this.api=api;}
 async request(action,body={},authenticated=true){
  if(authenticated){if(!this.api.session?.access_token)throw Error('로그인이 필요합니다.');if(this.api.session.expires_at<Date.now()/1000+45)await this.api.refresh();}
  const headers={'Content-Type':'application/json',apikey:this.api.c.key};if(authenticated)headers.Authorization='Bearer '+this.api.session.access_token;
  let r,data;
  try{r=await this.api.fetcher(this.api.c.url+'/functions/v1/dnm-accounts',{method:'POST',headers,credentials:'omit',cache:'no-store',signal:AbortSignal.timeout(55000),body:JSON.stringify({action,project_url:this.api.c.url,...body})});const text=await r.text();try{data=JSON.parse(text);}catch{throw Error('NOT_JSON');}}
  catch{const e=Error('계정 처리 응답을 확인하지 못했습니다. Supabase dnm-accounts 함수 배포를 확인하고 사용자 목록을 새로고침하세요.');e.unknown=authenticated&&action!=='status';throw e;}
  if(!r.ok||!data?.ok){const e=Error(data?.message||(r.status===404?'Supabase Edge Functions의 dnm-accounts 함수가 배포되지 않았습니다.':'계정 요청을 처리하지 못했습니다.'));e.code=data?.code;e.status=r.status;throw e;}
  return data;
 }
 async list(){
  try{return(await this.api.request('/rest/v1/rpc/dnm_v47_accounts')).data;}
  catch(e){if(e.status!==404&&e.code!=='HTTP_404')throw e;return(await this.api.request('/rest/v1/rpc/dnm_v43_accounts')).data;}
 }
 loginName(login_id,password){return this.request('name_login',{login_id,password},false);}
 temporaryName(login_id,password){return this.request('name_temporary_login',{login_id,password},false);}
 temporary(email,password){return this.request('temporary_login',{email,password},false);}
 complete(ticket,password,repeat){return this.request('set_initial_password',{ticket,password,repeat},false);}
}
export function passwordIssue(value){if(typeof value!=='string'||value.length<12||new TextEncoder().encode(value).length>72||!/\p{L}/u.test(value)||!/\d/.test(value))return'새 비밀번호는 문자와 숫자를 포함하여 12자 이상으로 입력하세요. (UTF-8 72바이트 이내)';return'';}
export const ACCOUNT_STATES={unregistered:'미등록',existing:'기존 계정',provisioning:'계정 처리 중',pending:'첫 비밀번호 설정 대기',changing:'비밀번호 설정 중',ready:'사용 중',disabled:'로그인 중지',error:'초기화 재확인 필요'};
