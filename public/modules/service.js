export class MesService{
 constructor(api){this.api=api;}
 async context(){return (await this.api.request('/rest/v1/rpc/dnm_v4_context')).data;}
 async records(kind,{parent='',state='',limit=500,offset=0,q=''}={}){
  const p=new URLSearchParams({select:'*',kind:'eq.'+kind,order:'updated_at.desc',limit:String(limit),offset:String(offset)});
  if(parent)p.set('parent_id','eq.'+parent);if(state)p.set('state','eq.'+state);
  if(q){const t='"*'+q.replace(/\\/g,'\\\\').replace(/"/g,'\\"')+'*"';p.set('or',`(code.ilike.${t},title.ilike.${t})`);}
  return this.api.request('/rest/v1/dnm_v4_records?'+p,{headers:{Prefer:'count=exact'}});
 }
 async all(kind,options={}){let out=[];for(let offset=0;offset<20000;offset+=500){const r=await this.records(kind,{...options,limit:500,offset});out.push(...r.data);if(r.data.length<500||out.length>=r.total)return out;}throw Error('조회 범위가 20,000건을 넘습니다. 관리자 백업/기간별 조회가 필요합니다.');}
 async one(id){const p=new URLSearchParams({select:'*',id:'eq.'+id,limit:'1'});const r=await this.api.request('/rest/v1/dnm_v4_records?'+p);if(!r.data?.length)throw Error('대상 자료가 없거나 조회 권한이 없습니다.');return r.data[0];}
 async command(action,payload,key){
  const p={p_action:action,p_payload:payload,p_key:key};
  try{const r=await this.api.request('/rest/v1/rpc/dnm_v4_command',{method:'POST',body:p});if(r.data?.ok!==true){const e=Error('저장 결과 형식을 확인하지 못했습니다. 목록을 조회하거나 같은 요청번호로 재확인하세요.');e.unknown=true;throw e;}return r.data;}
  catch(e){if(e.status>=500)e.unknown=true;throw e;}
 }
 async permissions(){return (await this.api.request('/rest/v1/dnm_v4_permissions?select=*')).data;}
 async backup(){return (await this.api.request('/rest/v1/rpc/dnm_v4_backup')).data;}
}
