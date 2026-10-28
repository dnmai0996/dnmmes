import {V421Controller} from './v421.js';
import {AccountService,ACCOUNT_STATES} from './accounts.js';
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
   $('#content').insertAdjacentHTML('afterbegin','<div class="card account-shortcut"><strong>작업자를 로그인 사용자로 등록</strong><p>재직자와 본인 이메일을 확인한 뒤 로그인 사용자 체크로 계정을 발급할 수 있습니다.</p><button type="button" id="goWorkerLogin" class="primary">로그인 사용자 등록·초기화</button></div>');
   $('#goWorkerLogin').onclick=()=>this.go('profiles');
  }
  return result;
 }
 async userAccounts(){
  if(this.ctx.account_management!=='4.3.0'){
   this.set(notice('사용자 등록 기능을 위해 Supabase에 10_upgrade_v4_3.sql을 먼저 적용하고, Netlify 서버 환경변수 2개 설정 후 배포하세요. 기존 자료는 초기화하지 않습니다.','warning'));return;
  }
  const [data,profiles]=await Promise.all([this.accounts.list(),this.api.rows('profiles','select=*&order=display_name.asc&limit=1000')]);
  this.loginWorkers=(data.workers||[]).sort((a,b)=>employeeSort({title:a.name,data:a},{title:b.name,data:b}));
  this.loginProfiles=profiles.data||[];
  const q=this.search.trim().toLowerCase();const filtered=this.loginWorkers.filter(x=>!q||[x.name,x.code,x.department,x.position,x.email,ACCOUNT_STATES[x.state]].some(s=>String(s||'').toLowerCase().includes(q)));
  const registered=this.loginWorkers.filter(x=>x.profile_id).length;
  this.set(`<div class="card"><div class="sectionhead"><div><span class="eyebrow">WORKER LOGIN ACCOUNTS</span><h2>작업자 로그인 사용자 관리</h2></div><button id="accountHealth" type="button" class="secondary">계정 서버 연결 확인</button></div>${notice('직원은 Supabase에 가입하지 않습니다. 아래 로그인 사용자 체크 → 본인 이메일 확인 → 등록 순서입니다. 신규 작업자는 본인 작업 조회·등록·수정 권한으로 시작하며 기존 계정의 권한은 보존합니다.')}<div class="account-warning">초기번호 1111은 공용번호입니다. 당사자가 접속할 때 발급하고 30분 안에 본인 비밀번호로 바꾸게 하십시오. 변경 전 업무자료는 차단되지만, 초기번호를 아는 타인이 먼저 설정할 위험은 남습니다.</div><div class="account-stats"><span>작업자 <b>${this.loginWorkers.length}</b>명</span><span>연결 계정 <b>${registered}</b>명</span><span>미등록 <b>${this.loginWorkers.length-registered}</b>명</span></div>${this.top()}<div id="accountServiceState" role="status"></div>${table(['로그인 사용자','사번 / 성명','부서 / 직책','본인 이메일','계정 상태','관리'],this.sliced(filtered).map(w=>{
   const protectedUser=w.protected||w.profile_id===this.ctx.profile.id;
   return[`<label class="check account-check"><input type="checkbox" data-account-check="${esc(w.id)}" ${w.enabled?'checked':''} ${protectedUser?'disabled':''} aria-label="${esc(w.name)} 로그인 사용자"> 사용</label>`,esc(w.code)+'<br><strong>'+esc(w.name)+'</strong>',esc(w.department)+'<br>'+esc(w.position),esc(w.email||'등록 시 입력'),`<span class="pill">${esc(ACCOUNT_STATES[w.state]||w.state)}</span>${w.state==='pending'?'<br><small>유효기한 '+esc(clock(w.expires_at))+'</small>':''}`,protectedUser?'관리자 계정 보호':(!w.profile_id?btn('accountEnroll','등록',w.id,'primary'):btn('accountReset','1111 초기화',w.id))];
  }))}<div id="v4pager" class="pagination"></div><p class="muted">계정을 삭제하지 않고 사용을 중지하므로 과거 작업일보·승인·변경이력은 보존됩니다. 이메일 연결 이후 주소 변경은 이 화면에서 지원하지 않습니다.</p></div><div class="card"><h2>기존 계정 및 역할</h2><p class="muted">본인의 비밀번호는 화면 상단 ‘비밀번호 변경’에서 바꿉니다. 관리자 역할 승격·업무 메뉴 권한은 기존 기능을 유지합니다.</p>${table(['이메일','성명','역할','상태','관리'],this.loginProfiles.map(p=>[esc(p.email),esc(p.display_name),esc(p.role),p.active?'활성':'차단',p.id===this.ctx.profile.id?'본인':btn('accountRole','역할·활성',p.id)]))}</div>`);
  this.pageFooter(filtered);
  const searchInput=$('#v4search');if(searchInput)searchInput.placeholder='성명·사번·부서·이메일 검색';
  all('[data-account-check]').forEach(c=>c.onchange=()=>{const w=this.loginWorkers.find(x=>x.id===c.dataset.accountCheck);const enable=c.checked;c.checked=!!w.enabled;this.accountDialog(w,enable?(w.profile_id?'reset':'provision'):'disable');});
  $('#accountHealth').onclick=async()=>{const el=$('#accountServiceState');el.textContent='계정 서버 확인 중…';try{await this.accounts.request('status');el.innerHTML=notice('계정 서버·DB 확장 연결을 확인했습니다.');}catch(e){el.innerHTML=notice(e.message,'warning');}};
 }
 accountDialog(w,action){
  if(!w||w.protected||w.profile_id===this.ctx.profile.id)throw Error('본인·관리자 계정은 이 기능으로 초기화하지 않습니다.');
  const registering=action==='provision',disabling=action==='disable';
  const title=registering?'로그인 사용자 등록':disabling?'로그인 사용 중지':'초기번호 1111로 재설정';
  const d=modal(title,`<p><b>${esc(w.name)}</b> · ${esc(w.code)} · ${esc(w.department)}</p>${input('email','로그인 ID — 직원 본인 이메일',w.email,'email','required maxlength="254" autocomplete="off" '+(registering?'':'readonly'))}${registering?'<label class="check"><input type="checkbox" name="login_user" required checked>로그인 사용자로 등록</label>':''}${notice(disabling?'즉시 업무자료 접근을 차단합니다. 계정과 과거 작업기록은 삭제하지 않습니다.':'초기번호: 1111 / 유효시간: 30분 / 첫 화면에서 본인 비밀번호 필수 설정. 기존 세션은 차단됩니다. 단순히 직원 이름만 보고 메일을 추정하지 마십시오.')}${area('reason','변경 사유',registering?'재직자 확인 후 로그인 사용자 등록':'','required minlength="2" maxlength="1000"')}${registering?'':input('admin_password','현재 관리자 본인의 비밀번호','','password','required autocomplete="current-password"')}<label class="check"><input type="checkbox" name="confirm_owner" required>실제 재직자 및 이메일 소유자를 확인했습니다.</label><p class="muted">동일 이메일의 기존 일반계정이 있으면 새 계정을 중복 생성하지 않고 연결합니다. 기존 역할·메뉴 권한은 보존하며, 신규 계정만 현장 작업자 기본권한으로 생성합니다.</p>`,async(f,key)=>{
   const result=await this.accounts.request(action,{employee_id:w.id,version:w.version,email:f.email,request_id:key,reason:f.reason,admin_password:f.admin_password,confirm_owner:f.confirm_owner==='on'});
   this.lastAccountResult=result.message;await this.userAccounts();
   const state=$('#accountServiceState');if(state)state.innerHTML=notice(result.message);
  },disabling?'사용 중지':registering?'계정 등록':'1111로 초기화');
  d.classList.add('account-dialog');
 }
 roleDialog(p){
  if(!p||p.id===this.ctx.profile.id)throw Error('본인 권한은 여기서 변경하지 않습니다.');
  modal('역할·계정 활성 상태',`<p>${esc(p.email)}</p>${input('name','성명',p.display_name,'text','required maxlength="100"')}${select('role','역할',[['admin','관리자'],['member','담당자'],['viewer','조회자']],p.role)}<label class="check"><input type="checkbox" name="active" ${p.active?'checked':''}>사용 허용</label>${notice('초기화 대기·로그인 중지 상태는 이 설정만으로 해제되지 않습니다. 작업자 목록에서 등록·초기화를 진행하세요. 관리자 지정은 전체 권한을 부여하므로 승인된 담당자에게만 적용하십시오.')}`,async f=>{await this.api.access({p_id:p.id,p_version:p.version,p_name:f.name,p_role:f.role,p_active:f.active==='on'});await this.userAccounts();});
 }
 async action(action,id){
  if(action==='accountEnroll')return this.accountDialog(this.loginWorkers.find(x=>x.id===id),'provision');
  if(action==='accountReset')return this.accountDialog(this.loginWorkers.find(x=>x.id===id),'reset');
  if(action==='accountRole')return this.roleDialog(this.loginProfiles.find(x=>x.id===id));
  return super.action(action,id);
 }
 help(){if(this.page==='profiles')return modal('로그인 사용자 관리 사용방법','<ol class="help-list"><li>관리자가 로그인한 후 실제 재직자·메일 소유자를 확인합니다.</li><li>작업자의 로그인 사용자 체크를 선택하고 본인 이메일을 입력합니다.</li><li>직원은 같은 DNM 사이트에서 본인 이메일과 초기번호 1111로 접속합니다.</li><li>30분 안에 새 비밀번호를 설정합니다. 설정 화면은 5분간 유효하며 업무자료는 제공하지 않습니다.</li><li>설정 후 이메일과 새 비밀번호로 다시 로그인합니다.</li><li>비밀번호 분실 시 관리자가 본인 비밀번호를 재입력하고 1111 초기화 버튼으로 재발급합니다.</li><li>사용 체크 해제는 업무자료 접근 중지이며 직원·실적 삭제가 아닙니다.</li><li>작업배정·메뉴별 권한은 기존 기능을 사용합니다.</li></ol>');return super.help();}
}
