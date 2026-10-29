import {V421Controller} from './v421.js';
import {AccountService,ACCOUNT_STATES,workerLoginStatus} from './accounts.js';
import {employeeSort} from './permissions.js';
import {$,all,esc,input,area,select,table,notice,modal,message,btn,clock} from './ui.js';
export class V43Controller extends V421Controller{
 constructor(...a){super(...a);this.accounts=new AccountService(this.api);this.loginWorkers=[];}
 async load(page){
  if(page==='profiles'){
   if(this.ctx.profile.role!=='admin'){this.set(notice('관리자 전용 메뉴입니다.','warning'));return;}
   if(this.page!==page){this.page=page;this.search='';this.pageNo=1;}
   return this.userAccounts();
  }
  const result=await super.load(page);
  if(page==='employees'&&this.ctx.profile.role==='admin'){
   $('#content').insertAdjacentHTML('afterbegin','<div class="card account-shortcut"><strong>작업자 사용·로그인 관리</strong><p>직원은 이름(ID)으로 로그인합니다. 이메일 입력은 필요 없습니다.</p><button type="button" id="goWorkerLogin" class="primary">작업자 로그인 관리</button></div>');
   $('#goWorkerLogin').onclick=()=>this.go('profiles');
  }
  return result;
 }
 async userAccounts(){
  try{await this.syncActiveWorkers();}catch(e){
   const rows=await this.rec('employee');this.set(notice('로그인 연결 기능을 확인하지 못했습니다. 작업자 명부는 보존되어 있습니다. '+e.message,'warning')+table(['사번','성명','사용상태'],rows.map(r=>[esc(r.code),esc(r.title),r.data.active?'사용':'미사용'])));return;
  }
  const data=await this.accounts.list();
  this.loginWorkers=(data.workers||[]).sort((a,b)=>employeeSort({title:a.name,data:a},{title:b.name,data:b}));
  const q=this.search.trim().toLowerCase();
  const filtered=this.loginWorkers.filter(w=>!q||[w.name,w.login_id,w.code,w.department,w.position,workerLoginStatus(w)].some(v=>String(v||'').toLowerCase().includes(q)));
  const active=this.loginWorkers.filter(w=>w.employee_active).length;
  const ready=this.loginWorkers.filter(w=>w.employee_active&&w.enabled&&w.profile_active&&w.state==='ready').length;
  this.set(`<div class="card"><div class="sectionhead"><div><h2>작업자 사용·로그인 관리</h2><p class="muted">작업자 기준정보와 같은 목록을 사용합니다. 사용·중지 시 계정 접근도 함께 변경됩니다.</p></div><button id="accountHealth" type="button" class="secondary">연결 확인</button></div>
  ${notice('직원 ID는 본인 이름입니다. 신규 직원은 초기번호 1111로 처음 접속하여 본인 비밀번호를 설정합니다. 동명이인은 이름-2로 구분합니다.')}
  ${data.name_login?'':notice('이름 로그인 설정(SQL 18)을 먼저 확인해야 합니다.','warning')}
  <div class="account-stats"><span>등록 작업자 <b>${this.loginWorkers.length}</b>명</span><span>사용 <b>${active}</b>명</span><span>비밀번호 설정 완료 <b>${ready}</b>명</span></div>
  ${this.syncErrorHtml()}${this.top()}${btn('syncWorkers','계정 연결 재시도')}<div id="accountServiceState" role="status"></div>
  ${table(['작업자 사용','작업자 / 로그인 ID','사번 / 부서','로그인 상태','관리'],this.pagedCells(filtered,w=>{
   const protectedUser=w.protected||w.profile_id===this.ctx.profile.id;
   return [
    `<label class="check account-check"><input type="checkbox" data-account-check="${esc(w.id)}" ${w.employee_active?'checked':''} ${protectedUser?'disabled':''} aria-label="${esc(w.name)} 사용/중지"> ${w.employee_active?'사용':'중지'}</label>`,
    `<strong>${esc(w.name)}</strong><br><span class="login-id">${esc(w.login_id||w.name||'미등록')}</span>`,
    esc(w.code)+'<br>'+esc(w.department),
    `<span class="pill">${esc(workerLoginStatus(w))}</span>`,
    protectedUser?'관리자 계정 보호':(!w.employee_active?'사용 전환 후 발급·초기화':!w.profile_id?btn('accountEnroll','1111 계정 발급',w.id,'primary'):btn('accountReset','1111 초기화',w.id))
   ];
  }))}<div id="v4pager" class="pagination"></div>
  <p class="muted">퇴직자 사용중지 후에도 작업일보·작업배정 이력은 삭제되지 않습니다. 사용 중인 직원의 계정은 자동 연결됩니다. 오류가 표시되면 연결 재시도를 실행하세요.</p></div>`);
  this.pageFooter(filtered);
  const searchInput=$('#v4search');if(searchInput)searchInput.placeholder='이름·사번·부서 검색';
  all('[data-account-check]').forEach(c=>c.onchange=()=>{
   const w=this.loginWorkers.find(x=>x.id===c.dataset.accountCheck),enable=c.checked;
   c.checked=!!w.employee_active;
   this.workerStatusDialog(w,enable);
  });
  $('#accountHealth').onclick=async()=>{const el=$('#accountServiceState');el.textContent='연결 확인 중…';try{await this.accounts.request('status');el.innerHTML=notice('직원 로그인 서버에 연결되었습니다.');}catch(e){el.innerHTML=notice(e.message,'warning');}};
 }
 workerStatusDialog(w,active){
  if(!w||w.protected||w.profile_id===this.ctx.profile.id)throw Error('관리자 계정은 이 화면에서 변경할 수 없습니다.');
  modal(active?'작업자 사용':'작업자 사용중지',`<p><strong>${esc(w.name)}</strong> · ${esc(w.code)}</p>${notice(active?'작업자 사용으로 변경합니다. 기존 비밀번호와 업무권한은 보존합니다.':'작업자를 사용중지합니다. 로그인을 차단하지만 과거 작업기록은 보존합니다.')}${area('reason','변경 사유',active?'사용 재개':'퇴직·장기휴직 등 사용중지 사유','required minlength="2" maxlength="1000"')}`,async f=>{
   await this.rpc('dnm_v48_set_worker_active',{p_employee:w.id,p_active:active,p_reason:f.reason});await this.userAccounts();
  },active?'사용으로 변경':'사용중지');
 }
 accountDialog(w,action){
  if(!w||w.protected||w.profile_id===this.ctx.profile.id)throw Error('관리자 계정은 이 기능으로 변경할 수 없습니다.');
  const registering=action==='provision';
  if(!w.employee_active)throw Error('먼저 작업자를 사용으로 전환하세요.');
  const title=registering?'이름(ID) 로그인 계정 발급':'초기번호 1111 재발급';
  const dlg=modal(title,`<p><strong>${esc(w.name)}</strong> · ${esc(w.code)}</p>${notice(registering?'본인 이름과 초기번호 1111로 첫 로그인 후 비밀번호를 변경하게 됩니다.':'비밀번호를 잊은 직원에게 초기번호 1111을 다시 발급합니다.')} ${area('reason','변경 사유',registering?'재직자 확인 후 로그인 계정 발급':'비밀번호 분실','required minlength="2" maxlength="1000"')}${registering?'':input('admin_password','관리자 본인의 현재 비밀번호','','password','required autocomplete="current-password"')}<label class="check"><input type="checkbox" name="confirm_owner" required>재직자 본인을 확인했습니다.</label><p class="muted">이메일을 입력할 필요가 없습니다. 초기번호 1111은 최초 개인 비밀번호 설정 전까지 사용하며, 설정 완료 후에는 사용할 수 없습니다.</p>`,async(f,key)=>{
   const result=await this.accounts.request(action,{employee_id:w.id,version:w.version,email:registering?'':w.email,request_id:key,reason:f.reason,admin_password:f.admin_password,confirm_owner:f.confirm_owner==='on'});
   await this.userAccounts();const el=$('#accountServiceState');if(el)el.innerHTML=notice(result.message);
  },registering?'계정 발급':'초기화');
  dlg.classList.add('account-dialog');
 }
 async syncActiveWorkers(){
  if(this._workerSync)return this._workerSync;
  this._workerSync=(async()=>{
   this.set(notice('사용 중인 작업자의 로그인 계정을 확인하고 있습니다. 잠시 기다려 주세요.'));
   const result=await this.accounts.ensureActive((done,total)=>this.set(notice(`작업자 로그인 자동 연결 ${done} / ${total}명`)));
   this.workerSyncErrors=result.failures;
   this.ctx=await this.s.context();
   return result;
  })();
  try{return await this._workerSync;}finally{this._workerSync=null;}
 }
 async access(){
  await this.syncActiveWorkers();
  const [data,perms,acl]=await Promise.all([this.accounts.list(),this.s.permissions(),this.api.request('/rest/v1/dnm_v42_module_access?select=*')]);
  this.permissions=perms;this.aclRows=acl.data;
  const workers=data.workers||[],linked=new Set(workers.map(w=>w.profile_id).filter(Boolean));
  // Include stopped profiles in admin editor; the server remains authoritative for permissions.
  for(const w of workers)if(w.profile_id&&!this.ctx.people.some(x=>x.id===w.profile_id))this.ctx.people.push({id:w.profile_id,name:w.name,role:w.role});
  const rows=workers.map(w=>({name:w.name,code:w.code,id:w.profile_id,role:w.role,status:workerLoginStatus(w),active:w.employee_active}));
  for(const a of this.ctx.people||[])if(!linked.has(a.id))rows.push({name:a.name,code:'기존 로그인 계정',id:a.id,role:a.role,status:'기존 계정 유지',active:true});
  const q=this.search.trim().toLowerCase();
  this.set(`<div class="card">${this.top()}${notice('작업자 명부 전체를 표시합니다. 사용 중인 작업자는 자동으로 계정을 연결합니다. 구매 결재자는 권한 설정에서 지정하세요.')}${this.syncErrorHtml()}${table(['성명 / 사번','로그인 상태','역할','구매 결재','권한'],rows.filter(r=>!q||[r.name,r.code,r.status].join(' ').toLowerCase().includes(q)).map(r=>{
   const approval=perms.find(a=>a.profile_id===r.id)?.capabilities?.includes('approve');
   return [esc(r.name)+'<br>'+esc(r.code),esc(r.status),esc(r.role||'미발급'),approval?'지정':'미지정',r.id?(r.role==='admin'?btn('adminApprover','구매 결재자 지정/해제',r.id):btn('moduleAccess','조회·등록·수정·결재 지정',r.id)):'자동 연결 확인 필요'];
  }))}</div>`);this.bindSearch();
 }
 syncErrorHtml(){return (this.workerSyncErrors||[]).length?notice('자동 연결 미완료: '+this.workerSyncErrors.map(x=>x.name+' — '+x.message).join(' / '),'warning'):'';}
 async command(action,payload,key){
  const result=await super.command(action,payload,key);
  if(this.ctx.profile.role==='admin'&&((action==='save_master'&&payload.kind==='employee')||action==='import_masters')){
   await this.syncActiveWorkers();await this.load(this.page);
  }
  return result;
 }
 async action(action,id){
  if(action==='syncWorkers')return this.userAccounts();
  if(action==='adminApprover'){const old=this.permissions.find(p=>p.profile_id===id)?.capabilities?.includes('approve');return modal('관리자 구매 결재권',notice(old?'구매 결재자 지정을 해제합니다.':'관리자를 구매 결재자 목록에 포함합니다.')+area('reason','변경 사유','','required'),async f=>{await this.rpc('dnm_v49_set_admin_approver',{p_user:id,p_enabled:!old,p_reason:f.reason});await this.access();});}
  if(action==='accountEnroll')return this.accountDialog(this.loginWorkers.find(x=>x.id===id),'provision');
  if(action==='accountReset')return this.accountDialog(this.loginWorkers.find(x=>x.id===id),'reset');
  return super.action(action,id);
 }
 help(){if(this.page==='profiles')return modal('작업자 로그인 사용방법','<ol class="help-list"><li>관리자는 작업자 목록에서 현재 재직자의 사용 상태를 선택합니다.</li><li>로그인 계정이 없는 직원은 1111 계정 발급을 한 번 실행합니다. 이메일 입력은 필요 없습니다.</li><li>직원은 본인 이름(ID)과 초기번호 1111로 첫 로그인 후 새 비밀번호를 정합니다.</li><li>동명이인은 이름-2 등 화면에 표시된 로그인 ID를 사용합니다.</li><li>비밀번호 분실 시 관리자가 1111 초기화를 실행합니다.</li><li>사용중지해도 과거 작업실적은 삭제되지 않습니다.</li><li>업무권한은 사용자별 권한 메뉴에서 조회자/일반사용자를 선택합니다.</li></ol>');return super.help();}
}
