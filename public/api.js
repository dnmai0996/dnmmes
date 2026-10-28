export class PortalApi{
 constructor(config,{storage=sessionStorage,fetcher=fetch}={}){this.c=config;this.storage=storage;this.fetcher=fetcher;this.key='dnm-portal-session:'+config.url;try{this.session=JSON.parse(storage.getItem(this.key));}catch{this.session=null;}}
 keep(s){this.session=s?{access_token:s.access_token,refresh_token:s.refresh_token,expires_at:s.expires_at||Math.floor(Date.now()/1000)+s.expires_in,user:s.user}:null;if(this.session)this.storage.setItem(this.key,JSON.stringify(this.session));else this.storage.removeItem(this.key);}
 async request(path,{method='GET',body,headers={},auth=true,retry=true}={}){
  if(auth&&(!this.session||!this.session.access_token))throw Error('로그인이 필요합니다.');
  if(auth&&this.session.expires_at<Date.now()/1000+45)await this.refresh();
  const h={apikey:this.c.key,...headers};if(auth)h.Authorization='Bearer '+this.session.access_token;if(body!==undefined)h['Content-Type']='application/json';
  let r;try{r=await this.fetcher(this.c.url+path,{method,headers:h,body:body===undefined?undefined:JSON.stringify(body),cache:'no-store',signal:AbortSignal.timeout(20000)});}catch{const e=Error(method==='GET'?'연결을 확인하고 다시 조회하세요.':'응답을 확인하지 못했습니다. 저장됐을 수 있으므로 목록을 조회한 후 다시 시도하세요.');e.unknown=method!=='GET';throw e;}
  let data=null;try{const text=await r.text();data=text?JSON.parse(text):null;}catch{const e=Error(method==='GET'?'서버 응답을 읽지 못했습니다. 다시 조회하세요.':'서버 응답을 읽지 못했습니다. 저장됐을 수 있으므로 목록을 확인하세요.');e.unknown=method!=='GET';throw e;}
  if(r.status===401&&auth&&retry){await this.refresh();return this.request(path,{method,body,headers,auth,retry:false});}
  if(!r.ok){let msg=data?.msg||data?.message||data?.error_description||'요청을 처리하지 못했습니다.';if(data?.code==='23505')msg='같은 코드가 이미 등록되어 있습니다.';if(r.status===403||data?.code==='42501')msg='사용 권한이 없습니다. 계정 활성 상태와 역할을 확인하세요.';if(r.status===400&&path.includes('/token'))msg='이메일·비밀번호 또는 계정 확인 상태를 확인하세요.';const e=Error(msg);e.status=r.status;throw e;}
  return {data,total:Number(r.headers.get('content-range')?.split('/')[1])};
 }
 async login(email,password){const {data}=await this.request('/auth/v1/token?grant_type=password',{method:'POST',body:{email,password},auth:false});this.keep(data);}
 async refresh(){if(this.refreshing)return this.refreshing;this.refreshing=(async()=>{try{if(!this.session?.refresh_token)throw Error('로그인 필요');const {data}=await this.request('/auth/v1/token?grant_type=refresh_token',{method:'POST',body:{refresh_token:this.session.refresh_token},auth:false});this.keep(data);}catch(e){this.keep(null);throw Error('로그인이 만료되었습니다. 다시 로그인하세요.');}finally{this.refreshing=null;}})();return this.refreshing;}
 async logout(){try{await this.request('/auth/v1/logout',{method:'POST'});}finally{this.keep(null);}}
 async rows(table,query='select=*'){return this.request('/rest/v1/dnm_portal_'+table+'?'+query,{headers:{Prefer:'count=exact'}});}
 async save(table,record,old){const q=old?'?id=eq.'+encodeURIComponent(old.id)+'&version=eq.'+encodeURIComponent(old.version):'';const {data}=await this.request('/rest/v1/dnm_portal_'+table+q,{method:old?'PATCH':'POST',body:record,headers:{Prefer:'return=representation'}});if(!data?.length)throw Error('다른 사용자가 수정했거나 권한이 변경됐습니다. 다시 조회하세요.');return data[0];}
 async access(body){return this.request('/rest/v1/rpc/dnm_portal_set_access',{method:'POST',body});}
}
