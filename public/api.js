function responseFailure(path, method, code){
 const write=path.startsWith('/rest/v1/')&&method!=='GET';
 const password=path==='/auth/v1/user'&&method==='PUT';
 let text;
 if(write)text='응답을 확인하지 못했습니다. 저장됐을 수 있으므로 목록을 조회한 후 다시 시도하세요.';
 else if(password)text='비밀번호 변경 결과를 확인하지 못했습니다. 변경한 비밀번호로 다시 로그인해 확인하세요.';
 else if(path.startsWith('/auth/v1/token'))text='로그인 서버의 응답을 받지 못했습니다. 아래 Supabase 연결 확인을 실행하세요. 현재 문구만으로 비밀번호 오류를 판단할 수 없습니다.';
 else text='Supabase 응답을 확인하지 못했습니다. 프로젝트 주소·프로젝트 실행 상태·인터넷 연결을 확인하세요.';
 if(code==='TIMEOUT')text+=' 요청 시간이 초과되었습니다.';
 if(code==='INVALID_RESPONSE')text+=' 올바른 JSON 응답이 아닙니다.';
 const e=Error(text+' ['+code+']');e.code=code;e.unknown=write||password;return e;
}

export class PortalApi{
 constructor(config,{storage=sessionStorage,fetcher=fetch}={}){
  this.c=config;this.storage=storage;this.fetcher=fetcher;this.key='dnm-portal-session:'+config.url;
  try{this.session=JSON.parse(storage.getItem(this.key));}catch{this.session=null;}
 }
 keep(s){
  this.session=s?{access_token:s.access_token,refresh_token:s.refresh_token,expires_at:s.expires_at||Math.floor(Date.now()/1000)+s.expires_in,user:s.user}:null;
  if(this.session)this.storage.setItem(this.key,JSON.stringify(this.session));else this.storage.removeItem(this.key);
 }
 async request(path,{method='GET',body,headers={},auth=true,retry=true}={}){
  if(auth&&!this.session?.access_token)throw Error('로그인이 필요합니다.');
  if(auth&&this.session.expires_at<Date.now()/1000+45)await this.refresh();
  const h={apikey:this.c.key,...headers};
  if(auth)h.Authorization='Bearer '+this.session.access_token;
  if(body!==undefined)h['Content-Type']='application/json';
  const controller=new AbortController();
  const timeout=setTimeout(()=>controller.abort(),20000);
  let r,text;
  try{
   r=await this.fetcher(this.c.url+path,{method,headers:h,body:body===undefined?undefined:JSON.stringify(body),cache:'no-store',signal:controller.signal});
   text=await r.text();
  }catch(cause){
   throw responseFailure(path,method,controller.signal.aborted||cause?.name==='TimeoutError'?'TIMEOUT':'CONNECTION_FAILED');
  }finally{clearTimeout(timeout);}
  let data=null,invalid=false;
  try{data=text?JSON.parse(text):null;}catch{invalid=true;}
  if(r.status===401&&auth&&retry){await this.refresh();return this.request(path,{method,body,headers,auth,retry:false});}
  if(!r.ok){
   let msg=data?.msg||data?.message||data?.error_description||'요청을 처리하지 못했습니다.';
   if(data?.code==='23505')msg='같은 코드가 이미 등록되어 있습니다.';
   if(r.status===403||data?.code==='42501')msg='사용 권한이 없습니다. 계정 활성 상태와 역할을 확인하세요.';
   if(path.startsWith('/auth/v1/')){
    if(r.status===401&&!auth)msg='Supabase 공개용 키가 거부됐습니다. config.js의 URL과 Publishable key를 같은 프로젝트에서 복사했는지 확인하세요.';
    else if(r.status===400&&path.includes('/token'))msg='이메일·비밀번호 또는 계정 확인 상태를 확인하세요.';
    else if(r.status===404)msg='Supabase 인증 경로를 찾지 못했습니다. Project URL을 확인하세요.';
    else if(r.status===429)msg='요청이 너무 많습니다. 잠시 후 다시 시도하세요.';
    else if(r.status>=500)msg='Supabase 서비스가 오류를 반환했습니다. 프로젝트 실행 상태를 확인하고 다시 시도하세요.';
   }
   const e=Error(msg+' [HTTP '+r.status+']');e.status=r.status;e.code='HTTP_'+r.status;throw e;
  }
  if(invalid)throw responseFailure(path,method,'INVALID_RESPONSE');
  return {data,total:Number(r.headers.get('content-range')?.split('/')[1])};
 }
 async checkConnection(){
  const {data}=await this.request('/auth/v1/settings',{auth:false});
  if(!data?.external||typeof data.external!=='object')throw responseFailure('/auth/v1/settings','GET','INVALID_RESPONSE');
  return {url:this.c.url,emailEnabled:typeof data.external.email==='boolean'?data.external.email:null};
 }
 async login(email,password){
  const {data}=await this.request('/auth/v1/token?grant_type=password',{method:'POST',body:{email,password},auth:false});
  if(!data?.access_token||!data?.refresh_token||!data?.user?.id)throw responseFailure('/auth/v1/token','POST','INVALID_RESPONSE');
  this.keep(data);
 }
 async refresh(){
  if(this.refreshing)return this.refreshing;
  if(!this.session?.refresh_token){this.keep(null);throw Error('로그인이 만료되었습니다. 다시 로그인하세요.');}
  this.refreshing=(async()=>{
   try{const {data}=await this.request('/auth/v1/token?grant_type=refresh_token',{method:'POST',body:{refresh_token:this.session.refresh_token},auth:false});this.keep(data);}
   catch{this.keep(null);throw Error('로그인이 만료되었거나 세션을 갱신하지 못했습니다. 다시 로그인하세요.');}
   finally{this.refreshing=null;}
  })();return this.refreshing;
 }
 async logout(){try{await this.request('/auth/v1/logout',{method:'POST'});}finally{this.keep(null);}}
 async rows(table,query='select=*'){return this.request('/rest/v1/dnm_portal_'+table+'?'+query,{headers:{Prefer:'count=exact'}});}
 async save(table,record,old){
  const q=old?'?id=eq.'+encodeURIComponent(old.id)+'&version=eq.'+encodeURIComponent(old.version):'';
  const {data}=await this.request('/rest/v1/dnm_portal_'+table+q,{method:old?'PATCH':'POST',body:record,headers:{Prefer:'return=representation'}});
  if(!data?.length)throw Error('다른 사용자가 수정했거나 권한이 변경됐습니다. 다시 조회하세요.');return data[0];
 }
 async access(body){return this.request('/rest/v1/rpc/dnm_portal_set_access',{method:'POST',body});}
}
