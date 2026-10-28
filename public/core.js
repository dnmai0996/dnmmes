export const VERSION='4.1.0';
export const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function settings(url,key){
 url=String(url??'').trim();key=String(key??'').trim();
 if(!url||!key)throw Error('config.js에 Supabase URL과 공개용 키를 입력하세요.');
 let u;try{u=new URL(url);}catch{throw Error('Supabase URL 형식을 확인하세요.');}
 if(u.protocol!=='https:'||!u.hostname.endsWith('.supabase.co')||u.username||u.password||u.search||u.hash||!['','/'].includes(u.pathname))throw Error('Project URL은 https://프로젝트번호.supabase.co 형식이어야 합니다.');
 if(key.startsWith('sb_secret_'))throw Error('Secret key를 사용할 수 없습니다. Publishable key로 바꾸세요.');
 if(!/^[\x21-\x7e]+$/.test(key))throw Error('공개용 키에 공백·줄바꿈·한글 등이 포함되어 있습니다. 실제 Publishable key 전체를 다시 복사하세요.');
 if(!key.startsWith('sb_publishable_')){
  let p;try{p=JSON.parse(atob(key.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));}catch{throw Error('Publishable key 또는 기존 anon public 키를 입력하세요.');}
  if(p.role!=='anon')throw Error('이 키는 브라우저에서 사용할 수 없습니다. anon public 키만 허용합니다.');
 }
 return {url:u.origin,key};
}
export function listQuery(kind,page,search,status){
 const q=new URLSearchParams({select:'*',order:kind==='notes'?'updated_at.desc':'code.asc',limit:'25',offset:String(Math.max(0,page-1)*25)});
 if(kind!=='notes'&&status!=='all')q.set('active','eq.'+(status==='active'));
 if(search){const term='"*'+search.replace(/\\/g,'\\\\').replace(/"/g,'\\"')+'*"';q.set('or',kind==='notes'?`(title.ilike.${term},body.ilike.${term})`:`(code.ilike.${term},name.ilike.${term})`);}
 return q.toString();
}
export function cleanRecord(kind,f){
 const get=(k,max,required=false)=>{const s=String(f[k]??'').trim();if(required&&!s)throw Error('필수 항목을 입력하세요.');if(s.length>max)throw Error('입력 길이를 줄여주세요: '+k);return s;};
 if(kind==='notes')return {title:get('title',160,true),body:get('body',10000,true)};
 const x={code:get('code',100,true),name:get('name',200,true),active:f.active==='on'};
 if(kind==='products')return {...x,project:get('project',200),unit:get('unit',20)};
 const category=get('category',20,true);if(!['customer','supplier','both'].includes(category))throw Error('거래처 구분 오류');
 return {...x,category,contact:get('contact',100),phone:get('phone',80)};
}

export function adminListQuery(kind,page,search=''){
 const q=new URLSearchParams({select:'*',order:kind==='audit'?'created_at.desc':'email.asc',limit:'25',offset:String(Math.max(0,page-1)*25)});
 if(search){const term='"*'+String(search).slice(0,160).replace(/\\/g,'\\\\').replace(/"/g,'\\"')+'*"';const fields=kind==='audit'?['entity','action']:['email','display_name','role'];q.set('or','('+fields.map(k=>k+'.ilike.'+term).join(',')+')');}
 return q.toString();
}
