export const BACKUP_VERSION='4.4.0';
export const COLLECTIONS=['profiles','products','partners','notes','records','permissions','module_access','requests','audit'];
export const COLLECTION_LABELS={profiles:'사용자 기본정보',products:'제품',partners:'거래처',notes:'공유메모',records:'기준정보·수주·생산·구매·품질',permissions:'결재·전결권한',module_access:'메뉴별 권한',requests:'중복처리 방지기록',audit:'변경이력'};
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const hash=/^[a-f0-9]{64}$/;
const enc=new TextEncoder(),dec=new TextDecoder('utf-8',{fatal:true});
export const LIMIT_BYTES=100*1024*1024;
export const hex=b=>[...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,'0')).join('');
export async function sha256(s){return hex(await globalThis.crypto.subtle.digest('SHA-256',typeof s==='string'?enc.encode(s):s));}
function base64(b){let str='';const a=new Uint8Array(b);for(let i=0;i<a.length;i+=16384)str+=String.fromCharCode(...a.subarray(i,i+16384));return btoa(str);}
function from64(s,max=LIMIT_BYTES*2){if(typeof s!=='string'||s.length>max||!s||!/^[A-Za-z0-9+/]*={0,2}$/.test(s))throw Error('백업 파일 형식이 잘못되었습니다.');const v=atob(s);return Uint8Array.from(v,x=>x.charCodeAt(0));}
export function backupFilename(manifest,safety=false){
 const d=new Date(manifest.captured_at);if(Number.isNaN(d.getTime()))throw Error('백업시각이 올바르지 않습니다.');
 const k=new Date(d.getTime()+9*3600000).toISOString().replaceAll('-','').replaceAll(':','');
 return `${k.slice(0,8)}_${k.slice(9,15)}_KST_DNM_${safety?'복원전_안전':'업무전체'}_${manifest.backup_id.slice(0,8)}.dnmbak`;
}
export function validateManifest(m){
 if(!m||m.format!=='dnm-business-snapshot-v44'||m.schema_version!==BACKUP_VERSION||!uuid.test(m.backup_id||'')||!uuid.test(m.instance_id||'')||!Number.isFinite(Date.parse(m.captured_at)))throw Error('v4.4에서 만든 업무 전체 백업 파일을 선택하세요. 이전 JSON 내보내기는 복원용이 아닙니다.');
 if(!Array.isArray(m.collections)||m.collections.length!==COLLECTIONS.length)throw Error('백업 자료 종류가 누락되었습니다.');
 const names=new Set();for(const c of m.collections){if(!COLLECTIONS.includes(c.name)||names.has(c.name)||!Number.isSafeInteger(c.count)||c.count<0||c.count>1000000||!hash.test(c.sha256||''))throw Error('백업 목록·건수를 확인하세요.');names.add(c.name);}
 return m;
}
export async function validatePayload(payload){
 const m=validateManifest(payload?.manifest);if(!payload.collections||typeof payload.collections!=='object'||Object.keys(payload.collections).some(k=>!COLLECTIONS.includes(k)))throw Error('백업 본문이 올바르지 않습니다.');
 for(const c of m.collections){const a=payload.collections[c.name];if(!Array.isArray(a)||a.length!==c.count)throw Error(`${COLLECTION_LABELS[c.name]}의 건수가 다릅니다.`);
  const seen=new Set();for(const r of a){if(!r||typeof r.key!=='string'||r.key.length>300||seen.has(r.key)||typeof r.row_json!=='string'||!hash.test(r.sha256||''))throw Error('백업에 중복·손상 행이 있습니다.');seen.add(r.key);let d;try{d=JSON.parse(r.row_json);}catch{throw Error('백업 내용이 손상되었습니다.');}if(!d||typeof d!=='object'||Array.isArray(d)||await sha256(r.row_json)!==r.sha256)throw Error('백업 항목 검증에 실패했습니다.');}
  const parts=a.slice().sort((a,b)=>a.key<b.key?-1:a.key>b.key?1:0).map(r=>r.key+':'+r.sha256).join('\n');
  if(await sha256(parts)!==c.sha256)throw Error(`${COLLECTION_LABELS[c.name]}의 무결성 검사가 실패했습니다.`);
 }
 return payload;
}
export function validateFilePassword(p){if(typeof p!=='string'||p.length<12||p.length>128)throw Error('백업파일 비밀번호를 12자 이상 입력하세요.');}
async function key(password,salt,iterations){const material=await crypto.subtle.importKey('raw',enc.encode(password),'PBKDF2',false,['deriveKey']);return crypto.subtle.deriveKey({name:'PBKDF2',salt,iterations,hash:'SHA-256'},material,{name:'AES-GCM',length:256},false,['encrypt','decrypt']);}
export async function encryptBackup(payload,password){
 validateFilePassword(password);validateManifest(payload.manifest);
 const raw=enc.encode(JSON.stringify(payload));if(raw.length>LIMIT_BYTES)throw Error('백업 크기가 100MB를 넘습니다. 관리자 전용 Help의 별도 백업 절차를 확인하세요.');
 const salt=crypto.getRandomValues(new Uint8Array(16)),iv=crypto.getRandomValues(new Uint8Array(12)),iterations=250000;
 const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:enc.encode('DNM-BACKUP-4.4')},await key(password,salt,iterations),raw);
 return JSON.stringify({format:'dnm-encrypted-backup-v44',algorithm:'PBKDF2-SHA256/AES-256-GCM',iterations,salt:base64(salt),iv:base64(iv),ciphertext:base64(ciphertext)});
}
export async function decryptBackup(text,password){
 if(typeof text!=='string'||text.length>LIMIT_BYTES*1.5)throw Error('파일 크기를 확인하세요.');
 let x;try{x=JSON.parse(text);}catch{throw Error('올바른 백업파일이 아닙니다.');}
 if(x.format!=='dnm-encrypted-backup-v44'||x.algorithm!=='PBKDF2-SHA256/AES-256-GCM'||x.iterations!==250000)throw Error('v4.4에서 내려받은 .dnmbak 파일을 선택하세요.');
 validateFilePassword(password);const salt=from64(x.salt,100),iv=from64(x.iv,100);if(salt.length!==16||iv.length!==12)throw Error('백업파일이 손상되었습니다.');
 let payload;try{const bytes=await crypto.subtle.decrypt({name:'AES-GCM',iv,additionalData:enc.encode('DNM-BACKUP-4.4')},await key(password,salt,x.iterations),from64(x.ciphertext));payload=JSON.parse(dec.decode(bytes));}catch{throw Error('파일 비밀번호가 다르거나 백업파일이 손상되었습니다.');}
 return validatePayload(payload);
}
export function chunks(rows,maxRows=50,maxBytes=1500000){const out=[];let a=[],bytes=0;for(const r of rows){const b=enc.encode(JSON.stringify(r)).length;if(b>5500000)throw Error('한 항목의 크기가 너무 큽니다. 관리자에게 확인하세요.');if(a.length&&(a.length>=maxRows||bytes+b>maxBytes)){out.push(a);a=[];bytes=0;}a.push(r);bytes+=b;}if(a.length)out.push(a);return out;}
export class BackupService{
 constructor(api){this.api=api;}
 async rpc(action,p={}){return(await this.api.request('/rest/v1/rpc/dnm_v44_backup_api',{method:'POST',body:{p_action:action,p}})).data;}
 async capture({purpose='normal',safetyFor=null,progress=()=>{},signal}={}){
  const id=crypto.randomUUID();let job;
  try{job=await this.rpc('begin',{id,purpose,safety_for:safetyFor});let calls=0;
   while(job.status==='building'){if(signal?.aborted)throw Error('백업을 중단했습니다.');if(++calls>100000)throw Error('처리 범위를 확인하세요.');const vals=Object.values(job.progress||{}),done=vals.reduce((s,x)=>s+x.count,0),total=vals.reduce((s,x)=>s+x.total,0);progress('자료 모으는 중',done,total);job=await this.rpc('step',{id});}
   if(job.status!=='ready')throw Error('백업이 완료되지 않았습니다.');return job;
  }catch(e){try{await this.rpc('cancel',{id});}catch{}throw e;}
 }
 async read(job,progress=()=>{}){
  const manifest=validateManifest(job.manifest),collections={};let count=0,total=manifest.collections.reduce((s,c)=>s+c.count,0),bytes=0;
  for(const c of manifest.collections){let after='';collections[c.name]=[];while(collections[c.name].length<c.count){const data=await this.rpc('read',{id:manifest.backup_id,collection:c.name,after});if(!Array.isArray(data.rows)||!data.rows.length)throw Error('백업자료 일부를 받지 못했습니다. 다시 내려받으세요.');for(const r of data.rows){if(r.key<=after)throw Error('백업 순서가 올바르지 않습니다.');after=r.key;bytes+=enc.encode(r.row_json).length;if(bytes>LIMIT_BYTES)throw Error('백업 크기가 100MB를 넘습니다.');}collections[c.name].push(...data.rows);count+=data.rows.length;progress('파일 준비 중',count,total);}}
  return validatePayload({manifest,collections});
 }
 async stage(payload,progress=()=>{}){
  await validatePayload(payload);const id=crypto.randomUUID();await this.rpc('stage_begin',{id,manifest:payload.manifest});let n=0;const total=payload.manifest.collections.reduce((s,c)=>s+c.count,0);
  try{for(const c of payload.manifest.collections){for(const rows of chunks(payload.collections[c.name])){await this.rpc('stage_rows',{id,collection:c.name,rows});n+=rows.length;progress('복원파일 검사 중',n,total);}}return await this.rpc('stage_verify',{id});}
  catch(e){try{await this.rpc('cancel',{id});}catch{}throw e;}
 }
 async restore(stageId,safetyId,password,reason,confirmation){
  if(!this.api.session?.access_token)throw Error('다시 로그인하세요.');if(this.api.session.expires_at<Date.now()/1000+45)await this.api.refresh();
  let r,x;try{r=await this.api.fetcher('/.netlify/functions/dnm-backups',{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+this.api.session.access_token},credentials:'omit',cache:'no-store',signal:AbortSignal.timeout(65000),body:JSON.stringify({action:'restore',project_url:this.api.c.url,stage_id:stageId,safety_id:safetyId,admin_password:password,reason,confirmation})});x=await r.json();}catch{const e=Error('복원 결과를 아직 확인하지 못했습니다. 반복 실행하지 말고 다시 로그인하여 백업·복원 내역을 확인하세요.');e.unknown=true;throw e;}
  if(!r.ok||!x?.ok){const e=Error(x?.message||'복원 요청을 처리하지 못했습니다. 관리자에게 확인하세요.');e.unknown=x?.code==='RESTORE_UNCERTAIN';throw e;}return x;
 }
}
