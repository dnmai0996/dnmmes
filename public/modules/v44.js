import {userMessage} from './error-info.js';
import {V43Controller} from './v43.js';
import {BackupService,COLLECTION_LABELS,backupFilename,encryptBackup,decryptBackup,sha256} from './backup-core.js';
import {$,esc,table,notice,download,clock,modal,input} from './ui.js';
import {beginActivity} from './activity.js';
import {showHelp} from './help-v44.js';
const total=m=>(m?.collections||[]).reduce((n,c)=>n+c.count,0);
const formatTime=x=>clock(x);
export class V44Controller extends V43Controller{
 constructor(...args){super(...args);this.backups=new BackupService(this.api);this.loadingBackup=false;this.restorePlan=null;this.safety=null;}
 help(){return showHelp(this.page,this.ctx.profile.role,this.ctx);}
 async backup(){
  if(this.ctx.profile.role!=='admin'){this.set(notice('관리자만 사용할 수 있습니다.','warning'));return;}
  const ready=this.ctx.backup_management==='4.4.0';
  this.set(`<div class="backup-intro"><p>실수에 대비하여 현재 자료를 보관하고, 필요한 백업시점으로 되돌립니다.</p><button type="button" id="backupHelp" class="secondary">사용방법</button></div>${!ready?notice('백업 기능 업데이트가 필요합니다. 사용방법의 설치 안내를 확인하세요.','warning'):''}
  <div id="backupNotice" class="message" role="status" hidden></div>
  <div id="backupProgress" class="backup-progress" role="status" hidden><span class="activity-spinner" aria-hidden="true"></span><strong id="backupProgressText">처리 중입니다…</strong><progress id="backupBar" max="100" value="0"></progress><button type="button" id="cancelBackup" class="secondary">중단</button></div>
  <div class="backup-layout"><section class="card"><h2>1. 현재 자료 백업</h2><p>기준정보·수주·Routing·작업일보·구매·품질·업무권한을 한 번에 보관합니다.</p><form id="createBackupForm"><label>백업파일 비밀번호<input name="password" type="password" required minlength="12" maxlength="128" autocomplete="new-password" placeholder="12자 이상"></label><label>비밀번호 확인<input name="repeat" type="password" required minlength="12" maxlength="128" autocomplete="new-password"></label><p class="muted">파일을 다시 열 때 필요합니다. 로그인 비밀번호와 구분하여 보관하세요.</p><button type="submit" ${ready?'':'disabled'}>전체 업무자료 백업</button></form><p id="backupSaved" role="status"></p></section>
  <section class="card"><h2>2. 원하는 시점으로 복원</h2><form id="restoreFileForm"><label>복원할 백업파일<input name="file" type="file" accept=".dnmbak" required></label><label>선택한 파일의 비밀번호<input name="password" type="password" required minlength="12" autocomplete="off"></label><button type="submit" class="secondary" ${ready?'':'disabled'}>파일 검사 · 복원 준비</button></form><p class="muted">파일 검사만으로 현재 자료가 바뀌지는 않습니다.</p></section></div>
  <div id="restorePlan"></div><div class="card"><div class="sectionhead"><h2>백업·복원 내역</h2><button type="button" id="refreshBackups" class="secondary" ${ready?'':'disabled'}>새로고침</button></div><div id="backupHistory">${ready?'내역 확인 중…':'업데이트 후 이용할 수 있습니다.'}</div><button id="moreBackups" type="button" class="secondary" hidden>이전 내역 더 보기</button></div>
  <p class="muted">복원해도 로그인 비밀번호·계정 보안·변경이력은 되돌리지 않습니다. 외부 보관파일은 별도입니다. 자세한 범위는 사용방법에서 확인하세요.</p>`);
  $('#backupHelp').onclick=()=>this.help();
  $('#createBackupForm').onsubmit=e=>{e.preventDefault();this.createBackup(e.target).catch(e=>this.backupError(e));};
  $('#restoreFileForm').onsubmit=e=>{e.preventDefault();this.prepareRestore(e.target).catch(e=>this.backupError(e));};
  $('#refreshBackups').onclick=()=>this.history().catch(e=>this.backupError(e));
  $('#moreBackups').onclick=()=>this.history(true).catch(e=>this.backupError(e));
  $('#cancelBackup').onclick=()=>this.backupAbort?.abort();
  if(ready)try{await this.history();}catch(e){this.backupError(e);}
  if(this.restorePlan)this.renderRestorePlan();
 }
 backupError(e){const box=$('#backupNotice');if(box){box.hidden=false;box.className='message error';box.textContent=userMessage(e?.message||'처리하지 못했습니다. 다시 확인하세요.');box.scrollIntoView({block:'nearest',behavior:'smooth'});}}
 async runBackup(label,fn,{cancel=true}={}){
  if(this.loadingBackup)throw Error('현재 작업이 끝난 뒤 다시 실행하세요.');this.loadingBackup=true;this.backupAbort=new AbortController();
  const controls=[...$('#content').querySelectorAll('button,input,select,textarea')].filter(e=>e.id!=='cancelBackup');const states=controls.map(e=>e.disabled);controls.forEach(e=>e.disabled=true);
  const panel=$('#backupProgress');panel.hidden=false;$('#cancelBackup').hidden=!cancel;$('#backupNotice').hidden=true;
  const a=beginActivity(label,5);
  const progress=(text,count=0,max=0)=>{const pct=max?Math.floor(count/max*100):0;$('#backupProgressText').textContent=max?`${text} · ${count.toLocaleString()} / ${max.toLocaleString()}건`:text;$('#backupBar').value=pct;a.update($('#backupProgressText').textContent,pct);};progress(label);
  try{return await fn(progress,this.backupAbort.signal);}
  finally{a.end();this.loadingBackup=false;this.backupAbort=null;if(panel.isConnected)panel.hidden=true;controls.forEach((e,i)=>{if(e.isConnected)e.disabled=states[i];});}
 }
 async createBackup(form){
  const password=form.elements.password.value;if(password!==form.elements.repeat.value)throw Error('백업파일 비밀번호 확인값이 다릅니다.');
  if(password.length<12)throw Error('파일 비밀번호는 12자 이상 입력하세요.');
  await this.runBackup('백업 준비 중…',async(progress,signal)=>{const job=await this.backups.capture({progress,signal});const payload=await this.backups.read(job,progress);progress('파일 암호화 중…');const text=await encryptBackup(payload,password),name=backupFilename(payload.manifest);download(name,text,'application/octet-stream');$('#backupSaved').textContent=`파일 준비 완료: ${name} — 다운로드 폴더에 저장되었는지 확인하세요.`;form.reset();});
  await this.history();
 }
 async prepareRestore(form){
  const file=form.elements.file.files[0],password=form.elements.password.value;if(!file)throw Error('복원할 백업파일을 선택하세요.');if(file.size>150*1024*1024)throw Error('파일 크기가 너무 큽니다.');
  await this.runBackup('파일을 확인하고 있습니다…',async progress=>{
   const payload=await decryptBackup(await file.text(),password);const job=await this.backups.stage(payload,progress);
   this.restorePlan={id:job.id,manifest:payload.manifest,name:file.name,password};this.safety=null;form.reset();
  },{cancel:false});this.renderRestorePlan();
 }
 renderRestorePlan(){
  const p=this.restorePlan;if(!p||!$('#restorePlan'))return;
  $('#restorePlan').innerHTML=`<section class="card restore-plan"><span class="tag">검사 완료</span><h2>복원할 시점: ${esc(formatTime(p.manifest.captured_at))}</h2><p>${esc(p.name)}</p><p>전체 ${total(p.manifest).toLocaleString()}행 · 복원 시 이 시점 이후의 업무 입력·수정은 되돌아갑니다.</p>
  <h3>① 지금 자료를 먼저 보호합니다</h3><button id="makeSafety" type="button" class="secondary">현재자료 안전백업 받기</button><p id="safetySaved" role="status">${this.safety?esc(this.safety.name):'안전백업 파일은 위에서 입력한 파일 비밀번호로 보호합니다.'}</p>
  <label>② 방금 받은 안전백업 파일을 다시 선택<input id="checkSafetyFile" type="file" accept=".dnmbak" ${this.safety?'':'disabled'}></label><p id="safetyChecked" role="status">${this.safety?.verified?'안전백업 파일 검사를 완료했습니다.':''}</p>
  <h3>③ 관리자 확인 후 복원합니다</h3><form id="applyRestoreForm"><label>복원 사유<input name="reason" required minlength="2" maxlength="500" placeholder="예: 시험자료 입력 오류"></label><label>확인문구: 백업시점복원<input name="confirmation" required autocomplete="off"></label><label>관리자 본인의 현재 로그인 비밀번호<input name="password" type="password" required autocomplete="current-password"></label><label class="check"><input name="confirm" type="checkbox" required>다른 사용자의 입력을 멈췄으며, 선택 시점 이후 업무자료가 되돌아감을 확인했습니다.</label><button id="applyRestore" type="submit" class="danger" ${this.safety?.verified?'':'disabled'}>선택 시점으로 복원</button></form>
  <p class="muted">처리 중 화면을 닫지 마세요. 복원 완료 후 모든 사용자는 다시 로그인합니다.</p></section>`;
  $('#makeSafety').onclick=()=>this.makeSafety().catch(e=>this.backupError(e));
  $('#checkSafetyFile').onchange=e=>this.verifySafety(e.target.files[0]).catch(e=>this.backupError(e));
  $('#applyRestoreForm').onsubmit=e=>{e.preventDefault();this.applyRestore(e.target).catch(e=>this.backupError(e));};
 }
 async makeSafety(){
  const p=this.restorePlan;if(!p)throw Error('먼저 복원파일을 검사하세요.');
  await this.runBackup('현재자료 안전백업 중…',async(progress,signal)=>{const job=await this.backups.capture({purpose:'safety',safetyFor:p.id,progress,signal});const payload=await this.backups.read(job,progress);progress('안전백업 파일 암호화 중…');const text=await encryptBackup(payload,p.password),name=backupFilename(payload.manifest,true);download(name,text,'application/octet-stream');this.safety={id:job.id,name,hash:await sha256(text),verified:false};});this.renderRestorePlan();await this.history();
 }
 async verifySafety(file){
  if(!file||!this.safety)throw Error('방금 받은 안전백업 파일을 선택하세요.');
  await this.runBackup('안전백업 파일 확인 중…',async()=>{const text=await file.text();if(await sha256(text)!==this.safety.hash)throw Error('방금 내려받은 안전백업 파일과 다릅니다. 파일명을 확인하세요.');const x=await decryptBackup(text,this.restorePlan.password);if(x.manifest.backup_id!==this.safety.id)throw Error('안전백업 시점이 다릅니다.');await this.backups.rpc('ack_file',{id:this.safety.id,sha256:this.safety.hash});this.safety.verified=true;},{cancel:false});this.renderRestorePlan();
 }
 async applyRestore(form){
  if(!this.restorePlan||!this.safety?.verified)throw Error('안전백업 파일을 먼저 검사하세요.');const f=Object.fromEntries(new FormData(form));if(f.confirmation!=='백업시점복원'||f.confirm!=='on')throw Error('확인문구와 확인란을 확인하세요.');
  let applied=false;try{await this.runBackup('선택한 시점으로 복원 중입니다. 화면을 닫지 마세요…',async()=>{await this.backups.restore(this.restorePlan.id,this.safety.id,f.password,f.reason,f.confirmation);applied=true;},{cancel:false});}
  finally{form.elements.password.value='';}
  if(applied){this.restorePlan.password='';this.restorePlan=null;this.safety=null;this.api.keep(null);this.set('<div class="card restore-success"><h2>복원 완료</h2><p>선택한 시점의 업무자료로 돌아갔습니다. 다시 로그인하여 확인하세요.</p><button id="afterRestoreLogin" type="button">다시 로그인</button></div>');$('#afterRestoreLogin').onclick=()=>window.location.reload();}
 }
 async history(more=false){
  if(!more){this.backupHistory=[];this.historyOffset=0;}const x=await this.backups.rpc('history',{offset:this.historyOffset||0});const rows=x.items||[];this.backupHistory.push(...rows);this.historyOffset=this.backupHistory.length;
  if(!$('#backupHistory'))return;$('#backupHistory').innerHTML=table(['시각','구분','건수','상태','파일'],this.backupHistory.map(j=>[esc(formatTime(j.job_type==='restore'?j.applied_at:j.snapshot_at)),j.job_type==='restore'?'시점 복원':j.purpose==='safety'?'복원 전 안전백업':'업무 전체 백업',j.job_type==='backup'?total({collections:j.collections}).toLocaleString():'—',j.status==='applied'?'복원 완료':'백업 준비 완료',j.job_type==='backup'?`<button type="button" class="secondary" data-download-backup="${esc(j.id)}">다시 받기</button>`:'—'])).replace('자료가 없습니다. 신규 등록 또는 자료 가져오기를 진행하세요.','아직 백업 내역이 없습니다. 위에서 첫 백업을 만드세요.');$('#moreBackups').hidden=rows.length<100;for(const b of document.querySelectorAll('[data-download-backup]'))b.onclick=()=>this.redownload(b.dataset.downloadBackup);
 }
 redownload(id){
  modal('백업 파일 다시 받기',input('password','파일 비밀번호','','password','required minlength="12" autocomplete="new-password"')+input('repeat','비밀번호 확인','','password','required minlength="12" autocomplete="new-password"'),async f=>{
   if(f.password!==f.repeat)throw Error('파일 비밀번호 확인값이 다릅니다.');
   await this.runBackup('백업 파일 준비 중…',async progress=>{const job=await this.backups.rpc('inspect',{id});const payload=await this.backups.read(job,progress);const text=await encryptBackup(payload,f.password);download(backupFilename(payload.manifest,job.purpose==='safety'),text,'application/octet-stream');},{cancel:false});
  },'파일 받기');
 }

}
