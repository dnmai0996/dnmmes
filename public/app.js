import {userMessage} from './modules/error-info.js';
import {SUPABASE_URL,SUPABASE_PUBLIC_KEY} from './config.js';
import {VERSION,esc,settings,listQuery,adminListQuery,cleanRecord} from './core.js';
import {PortalApi} from './api.js';
import {voiceFor} from './speech.js';
import {V46Controller as MesController} from './modules/v46.js';
import {beginActivity} from './modules/activity.js';
import {showHelp} from './modules/help-v44.js';
import {AccountService,passwordIssue} from './modules/accounts.js';
import {pageAllowed,permit} from './modules/permissions.js';
import {MesService} from './modules/service.js';
import {NAV_LABELS as labels,renderNavigation,breadcrumbMarkup,firstPage,restoreMenuState,keepSelectedVisible} from './modules/navigation.js';
import {can} from './modules/domain.js';
import {modal as helpModal} from './modules/ui.js';
import {canSortHeader,indicateSort} from './modules/table-sort.js';
const $=s=>document.querySelector(s),all=(s,root=document)=>[...root.querySelectorAll(s)];

const legacyTabs=['home','notes','audit'];
let mes,context;
const roleLabel={admin:'관리자',member:'담당자',viewer:'조회자'};
let api,me,tab='home',page=1,query='',status='active',generation=0,stopVoice=()=>{};
const adminColumnSort={};const auditSortFields=['created_at','entity','action','actor_id','record_id'];
const clock=v=>new Date(v).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'});
function message(text,error=false){if(error)text=userMessage(text);const box=$('#editor').open?$('#dialogMessage'):$('#message');if(box){box.hidden=false;box.className='message'+(error?' error':'')+($('#editor').open?' dialog-message':'');box.textContent=text;}}
function fail(e){const text=e?.message||'처리 결과를 확인하지 못했습니다. 다시 조회하세요.';message(text,true);if(api&&!api.session)login(text);}
function guarded(fn){return async()=>{try{await fn();}catch(e){fail(e);}};}
function login(msg='',success=false){
 generation++;me=null;document.body.classList.remove('tv-mode','nav-drawer-open');document.querySelector('#v4dialog')?.close();stopVoice();$('#editor').close();
 $('#app').innerHTML=`<div class="login"><section class="hero"><div class="brand"><img src="assets/dnm-logo.png" alt="디엔엠"></div><div class="eyebrow">CONNECTED WORKSPACE</div><h1>어디서든 이어지는<br>우리의 업무.</h1><p>수주에서 생산·품질까지,<br>현장의 기록을 한 곳에서 연결합니다.</p></section><section class="loginbox"><div><span class="tag">클라우드 MES · ${VERSION}</span><h2>개인 계정으로 로그인</h2><p class="muted">관리자가 등록한 본인 이메일로 로그인하세요. 초기번호를 받은 경우 먼저 본인 비밀번호를 설정합니다.</p><form id="loginForm"><label>이메일<input name="email" type="email" autocomplete="username" required></label><label>비밀번호<input name="password" type="password" autocomplete="current-password" required></label><button class="full">로그인</button></form><div id="message" class="message${msg&&!success?' error':''}" role="status" ${msg?'':'hidden'}>${esc(msg)}</div><p class="muted">계정 발급·잠금 해제는 관리자에게 요청하세요.</p><p><a href="setup.html" target="_blank" rel="noopener">처음 설치하는 담당자 안내</a></p></div></section></div>`;
 $('#message').insertAdjacentHTML('afterend',`<details id="diagnostics"><summary>로그인 도움말 · 연결 확인</summary><p class="message">연결 주소: ${esc(api.c.url)}</p><button id="checkConnection" type="button" class="secondary full">연결 확인 (비밀번호 불필요)</button><div id="diagnosticResult" class="message" role="status" hidden></div></details>`);
 $('#checkConnection').onclick=async()=>{
  const button=$('#checkConnection'),box=$('#diagnosticResult');button.disabled=true;box.hidden=false;box.className='message';box.textContent='인증 서비스 연결을 확인하고 있습니다…';
  try{const result=await api.checkConnection();
   if(result.emailEnabled===false){box.className='message error';box.textContent='인증 서비스에 접속했지만 이메일 로그인이 꺼져 있습니다. Supabase Authentication → Sign In / Providers에서 Email을 확인하세요.';}
   else box.textContent='인증 서비스의 공개 설정을 정상 조회했습니다. '+(result.emailEnabled===true?'이메일 로그인도 활성화되어 있습니다. ':'이메일 로그인 활성 상태는 이 응답에서 확인되지 않았습니다. ')+'이제 로그인해 계정과 업무 DB 접근을 확인하세요.';
  }catch(x){box.className='message error';box.textContent=x.message;
   if(['CONNECTION_FAILED','TIMEOUT'].includes(x.code))box.textContent+='\n확인 순서: 위 주소를 Supabase의 실제 Project URL과 대조 → 프로젝트 실행 상태 확인 → 휴대폰 모바일 데이터로 같은 Netlify 주소에서 연결 진단. 브라우저 차단·DNS·통신 오류는 이 결과만으로 구분할 수 없습니다.';
  }finally{button.disabled=false;}
 };
 $('#loginForm').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('button');b.disabled=true;const activity=beginActivity('로그인 중입니다…');try{const f=Object.fromEntries(new FormData(e.target));const email=f.email.trim().toLowerCase();if(f.password==='1111'){const result=await new AccountService(api).temporary(email,f.password);api.keep(null);initialPassword(result);return;}await api.login(email,f.password);await enter();}catch(x){message(x.message,true);if(['CONNECTION_FAILED','TIMEOUT','INVALID_RESPONSE','HTTP_401'].includes(x.code)&&$('#diagnostics'))$('#diagnostics').open=true;}finally{b.disabled=false;activity.end();}};
}
function initialPassword(setup){
 me=null;generation++;document.body.classList.remove('tv-mode','nav-drawer-open');
 $('#app').innerHTML=`<section class="card password-setup"><div class="brand"><img src="assets/dnm-logo.png" alt="디엔엠"></div><span class="tag">첫 로그인 · 비밀번호 설정</span><h1>본인 비밀번호를 정해주세요</h1><p>${esc(setup.email)}</p><p class="muted">초기번호는 업무용 비밀번호가 아닙니다. 이 화면은 최대 5분간 유효하며, 설정 전에는 업무자료를 조회하거나 등록할 수 없습니다.</p><form id="initialPasswordForm"><label>새 비밀번호<input name="password" type="password" minlength="12" autocomplete="new-password" required></label><label>새 비밀번호 확인<input name="repeat" type="password" minlength="12" autocomplete="new-password" required></label><small>문자와 숫자를 포함한 12자 이상 (UTF-8 72바이트 이내)</small><button type="submit">비밀번호 설정 완료</button><button type="button" class="secondary" id="cancelInitialPassword">로그인으로 돌아가기</button></form><div id="message" class="message" role="status" hidden></div></section>`;
 $('#cancelInitialPassword').onclick=()=>{setup.ticket='';login();};
 $('#initialPasswordForm').onsubmit=async e=>{
  e.preventDefault();const f=Object.fromEntries(new FormData(e.target));const issue=passwordIssue(f.password);if(issue){message(issue,true);return;}if(f.password!==f.repeat){message('새 비밀번호와 확인값이 다릅니다.',true);return;}
  const buttons=[...e.target.querySelectorAll('button')];buttons.forEach(b=>b.disabled=true);
  try{await new AccountService(api).complete(setup.ticket,f.password,f.repeat);setup.ticket='';login('비밀번호를 설정했습니다. 본인의 이메일과 새 비밀번호로 로그인하세요.',true);}
  catch(err){message(err.message,true);}
  finally{buttons.forEach(b=>b.disabled=false);}
 };
}
async function enter(){
 const {data}=await api.rows('profiles','select=*&id=eq.'+encodeURIComponent(api.session.user.id));me=data[0];
 if(!me?.active){let state;try{state=(await api.request('/rest/v1/rpc/dnm_v43_my_account_status')).data;}catch{}await api.logout().catch(()=>{});login(state?.managed?'로그인 사용이 중지되었거나 비밀번호 설정이 필요합니다. 관리자에게 확인하고 초기번호를 받은 경우 1111로 접속하세요.':'계정 활성화 대기 중입니다. 관리자에게 프로그램 내 사용자 등록을 요청하세요.');return;}
 try{context=await new MesService(api).context();if(context?.profile?.id!==me.id||!['4.0.0','4.1.0','4.2.0'].includes(context?.version))throw Error('v4 데이터베이스 응답을 확인하지 못했습니다.');}catch(e){context={profile:me,capabilities:[],schemaError:e.message};}
 mes=new MesController(api,context,(target,detail)=>{navigate(target,detail).catch(fail);});
 tab=context.version==='4.2.0'?firstPage(context):'home';shell({resetPage:true});await load();if(context.version!=='4.2.0')message('업데이트 설치를 확인해야 합니다. 관리자에게 문의하세요.',true);
}
const menuKey=()=>`dnm-menu:${me?.id||'none'}`;
function menuState(){try{return restoreMenuState(JSON.parse(localStorage.getItem(menuKey())||'{}'));}catch{return{};}}
function saveMenu(state){try{localStorage.setItem(menuKey(),JSON.stringify(state));}catch{}}
function permittedTabs(){return Object.keys(labels).filter(k=>context?.version==='4.2.0'?pageAllowed(context,k):me.role==='admin'&&legacyTabs.includes(k));}
let sidebarScroll=0,navigationBusy=false;

async function refreshContext(){const c=await new MesService(api).context();if(!c?.profile?.active||c.profile.id!==me.id){await api.logout();login('권한 또는 계정 상태가 변경되었습니다. 다시 로그인하세요.');return false;}context=c;me=c.profile;mes.setContext(c);return true;}
async function navigate(target,detail){
 if(mes.loadingImport||mes.loadingBackup){message('처리 중에는 현재 화면을 유지하세요.',true);return;}
 if(navigationBusy)return;
 navigationBusy=true;const pending=beginActivity('화면을 여는 중입니다…');
 try{
  if(!await refreshContext())return;
  const oldTab=tab;
  tab=target;page=1;query='';status='active';
  if(context.version==='4.2.0'&&!pageAllowed(context,tab))tab=firstPage(context);
  document.body.classList.remove('tv-mode');
  shell({resetPage:true});
  // Internal links (e.g. an order card) use the same navigation and ACL checks.
  if(detail&&tab===target){mes.page=target;mes.search='';mes.pageNo=1;mes.detail=detail;}
  else if(oldTab===target)mes.detail=null;
  await load();
 }finally{navigationBusy=false;pending.end();}
}
function setMobileMenu(open){
 const shell=document.querySelector('.app-shell'),nav=$('#sideNav'),button=$('#mobileNav'),main=document.querySelector('.main-pane'),veil=$('#navBackdrop');
 if(!shell||!nav||!button)return;
 shell.classList.toggle('nav-open',open);document.body.classList.toggle('nav-drawer-open',open);
 button.setAttribute('aria-expanded',String(open));if(veil)veil.hidden=!open;
 if(main)main.inert=open;
 if(open)requestAnimationFrame(()=>{keepSelectedVisible($('#sideMenu'));const active=nav.querySelector('[aria-current="page"]')||$('#closeNav');active?.focus({preventScroll:true});});
 else button.focus({preventScroll:true});
}
function shell({resetPage=false}={}){
 const oldMenu=$('#sideMenu');if(oldMenu)sidebarScroll=oldMenu.scrollTop;
 const tabs=permittedTabs();
 document.body.classList.remove('nav-drawer-open');
 $('#app').innerHTML=`<div class="app-shell"><aside class="sidebar" id="sideNav" aria-label="디엔엠 업무 탐색"><div class="sidebar-brand"><div><div class="brand"><img src="assets/dnm-logo.png" alt="디엔엠"></div><small>구매·생산 통합관리</small></div><button type="button" id="closeNav" class="nav-close" aria-label="업무 메뉴 닫기">✕</button></div><nav id="sideMenu" aria-label="업무 메뉴">${renderNavigation(tabs,tab,menuState())}</nav><footer>${VERSION}<br>DNM 업무관리</footer></aside><button id="navBackdrop" type="button" class="nav-backdrop" aria-label="업무 메뉴 닫기" tabindex="-1" hidden></button><div class="main-pane"><header class="topbar"><button type="button" id="mobileNav" class="secondary mobile-nav" aria-expanded="false" aria-controls="sideNav">☰ 메뉴</button><span id="connection" role="status">연결 확인 중</span><div class="who">${esc(me.display_name||me.email)} · ${roleLabel[me.role]}</div><div><button id="password" class="secondary">비밀번호 변경</button> <button id="logout" class="quiet">로그아웃</button></div></header><main class="workspace"><div class="heading"><div><div class="page-path" aria-label="현재 위치">${breadcrumbMarkup(tab)}</div><h1 id="title" tabindex="-1">${labels[tab]||'사용권한 확인'}</h1><span class="muted"></span></div><div class="actions"><button id="vhelp" class="secondary">❔ 사용방법</button><button id="reload" class="secondary">새로고침</button></div></div><div id="message" class="message" role="status" hidden></div><div id="content"></div></main></div></div>`;
 all('[data-tab]').forEach(b=>b.onclick=guarded(()=>navigate(b.dataset.tab)));
 for(const d of all('[data-navgroup]'))d.addEventListener('toggle',()=>{const state=menuState();state[d.dataset.navgroup]=d.open;saveMenu(state);});
 const menu=$('#sideMenu');menu.scrollTop=sidebarScroll;
 menu.addEventListener('scroll',()=>{sidebarScroll=menu.scrollTop;},{passive:true});
 if(resetPage)window.scrollTo({top:0,left:0,behavior:'instant'});
 requestAnimationFrame(()=>{if(menu.isConnected){keepSelectedVisible(menu);sidebarScroll=menu.scrollTop;}});
 $('#mobileNav').onclick=()=>setMobileMenu(!document.querySelector('.app-shell').classList.contains('nav-open'));
 $('#closeNav').onclick=$('#navBackdrop').onclick=()=>setMobileMenu(false);
 $('#sideNav').onkeydown=e=>{
  if(!document.querySelector('.app-shell').classList.contains('nav-open'))return;
  if(e.key==='Escape'){e.preventDefault();setMobileMenu(false);return;}
  if(e.key==='Tab'){
   const focusables=all('button:not([disabled]),summary', $('#sideNav')).filter(x=>x.getClientRects().length);
   const first=focusables[0],last=focusables.at(-1);
   if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}
   else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}
  }
 };
 $('#vhelp').onclick=()=>showHelp(tab,me.role,context);
 $('#reload').onclick=guarded(()=>navigate(tab));$('#logout').onclick=guarded(async()=>{if(mes.loadingImport||mes.loadingBackup)throw Error('처리가 끝난 후 로그아웃하세요.');try{await api.logout();}finally{login();}});
 $('#password').onclick=()=>openForm('비밀번호 변경',field('current','현재 비밀번호','','password','required autocomplete="current-password"')+field('next','새 비밀번호 (12자 이상)','','password','required minlength="12" autocomplete="new-password"')+field('repeat','새 비밀번호 확인','','password','required minlength="12" autocomplete="new-password"'),async f=>{
  if(f.next!==f.repeat)throw Error('새 비밀번호가 일치하지 않습니다.');if(f.current===f.next)throw Error('기존과 다른 비밀번호를 사용하세요.');const issue=passwordIssue(f.next);if(issue)throw Error(issue);
  if(context?.account_management==='4.3.0')await new AccountService(api).request('change_password',{current:f.current,password:f.next,repeat:f.repeat});
  else{await api.login(me.email,f.current);await api.request('/auth/v1/user',{method:'PUT',body:{password:f.next,current_password:f.current}});}
  await api.logout().catch(()=>{});login('비밀번호가 변경됐습니다. 새 비밀번호로 로그인하세요.',true);
 });
}

const field=(name,label,value='',type='text',attrs='')=>`<label>${label}<input name="${name}" type="${type}" value="${esc(value)}" ${attrs}></label>`;
const empty='<div class="empty">등록된 자료가 없습니다.</div>';
function grid(headers,rows){return rows.length?`<div class="table-wrap"><table><thead><tr>${headers.map((h,i)=>`<th>${canSortHeader(h)?`<button type="button" class="table-sort-button" data-table-sort="${i}" aria-label="${esc(h)} 기준 정렬">${esc(h)} <span class="sort-indicator" aria-hidden="true">⇅</span></button>`:esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.map(r=>`<tr>${r.map(c=>`<td class="wrap">${c}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`:empty;}
function editable(action='update'){return permit(context,tab,action);}
async function load(){
 const ticket=++generation,kind=tab;$('#connection').textContent='조회 중…';
 try{
  if(kind==='noAccess'){document.querySelector('#content').innerHTML='<div class="card"><h2>사용 가능한 메뉴가 없습니다.</h2><p>관리자에게 개인별 업무권한 지정을 요청하세요.</p></div>';document.querySelector('#connection').textContent='로그인됨 · 업무권한 대기';return;}
  if(context?.version==='4.2.0'&&!pageAllowed(context,kind))throw Error('조회권한이 변경되었습니다. 새로고침하세요.');
  if(!legacyTabs.includes(kind)){await mes.load(kind);if(ticket!==generation)return;}else if(kind==='home'){
   const counts=await Promise.all(['products','partners','notes'].map(k=>api.rows(k,'select=id&limit=1')));if(ticket!==generation)return;
   $('#content').innerHTML=`<div class="metrics">${counts.map((r,i)=>`<div class="card metric"><span>${['제품','거래처','공유메모'][i]}</span><b>${r.total||0}</b></div>`).join('')}</div><div class="card"><h2>한 곳에 저장하고, 함께 확인합니다.</h2><p class="muted">자료는 회사 업무시스템에 함께 저장됩니다. 다른 기기의 변경은 새로고침하거나 잠시 기다리면 확인할 수 있습니다.</p><div class="flow">품목 기준정보 · 제품코드, 품명, Project, 단위<br>거래처 · 고객사와 공급업체 연락정보<br>공유메모 · 음성 또는 직접 입력 후 확인·저장</div></div><div class="card"><h2>연결 상태</h2><p>업무시스템에 연결되어 있습니다.</p><small>음성 입력은 지원 브라우저에서 사용합니다. 인식 결과는 저장 전에 수정할 수 있습니다.</small></div>`;
  }else{
   let q=['products','partners','notes'].includes(kind)?listQuery(kind,page,query,status):adminListQuery(kind,page,query);
   if(kind==='audit'&&adminColumnSort.audit){const x=new URLSearchParams(q),sort=adminColumnSort.audit;x.set('order',auditSortFields[sort.col]+'.'+sort.dir);q=x.toString();}
   const {data:rows,total}=await api.rows(kind,q);if(ticket!==generation)return;
   const search=['products','partners','notes','profiles','audit'].includes(kind),canAdd=['products','partners','notes'].includes(kind)&&editable('create');
   let html=search?`<form id="search" class="toolbar"><label class="sr" for="searchText">검색</label><input id="searchText" placeholder="${kind==='notes'?'제목 또는 내용':kind==='profiles'?'성명·이메일·역할':kind==='audit'?'대상·작업 유형':'코드 또는 명칭'} 검색" value="${esc(query)}">${['products','partners'].includes(kind)?`<select id="status" aria-label="사용 상태"><option value="active" ${status==='active'?'selected':''}>사용 중</option><option value="inactive" ${status==='inactive'?'selected':''}>사용 중지</option><option value="all" ${status==='all'?'selected':''}>전체</option></select>`:''}<button>검색</button>${canAdd?'<button id="new" type="button" class="secondary">신규 등록</button>':''}</form>`:'';
   if(kind==='products')html+=grid(['품번','품명','Project','단위','상태','관리'],rows.map(r=>[esc(r.code),esc(r.name),esc(r.project),esc(r.unit)||'미확인',r.active?'사용':'중지',editable()?`<button data-edit="${r.id}" class="secondary">수정</button>`:'조회']));
   if(kind==='partners')html+=grid(['코드','거래처명','구분','담당자 / 연락처','상태','관리'],rows.map(r=>[esc(r.code),esc(r.name),{customer:'고객사',supplier:'공급업체',both:'고객·공급'}[r.category],esc(r.contact)+'<br>'+esc(r.phone),r.active?'사용':'중지',editable()?`<button data-edit="${r.id}" class="secondary">수정</button>`:'조회']));
   if(kind==='notes')html+=rows.length?rows.map(r=>`<article class="card note-card"><h2>${esc(r.title)}</h2><div class="note-body">${esc(r.body)}</div><div class="note-meta">${clock(r.updated_at)} · v${r.version}${r.owner_id===me.id?' · 내가 작성':''}</div>${editable()&&(r.owner_id===me.id||me.role==='admin')?`<button data-edit="${r.id}" class="secondary">수정</button>`:''}</article>`).join(''):empty;
   if(kind==='profiles')html+='<p class="muted">작업자 로그인 사용자 관리에서 계정을 등록하세요.</p>'+grid(['이메일','성명','역할','상태','관리'],rows.map(r=>[esc(r.email),esc(r.display_name),roleLabel[r.role],r.active?'활성':'대기/차단',r.id===me.id?'본인':`<button data-access="${r.id}" class="secondary">권한 변경</button>`]));
   if(kind==='audit')html+=grid(['변경 시각','대상','작업','작성자 ID','자료 ID'],rows.map(r=>[clock(r.created_at),esc(r.entity),esc(r.action),esc(r.actor_id||'DB 관리자'),esc(r.record_id)]));
   html+=`<div class="pagination"><button id="prev" class="secondary" ${page===1?'disabled':''}>이전</button><span>${page} / ${Math.max(1,Math.ceil(total/25))} · 총 ${total}건</span><button id="next" class="secondary" ${page*25>=total?'disabled':''}>다음</button></div>`;
   $('#content').innerHTML='<div class="card">'+html+'</div>';
   const sort=adminColumnSort[kind];if(sort)indicateSort($('#content table'),sort.col,sort.dir);
   $('#content').onclick=e=>{const b=e.target.closest('[data-table-sort]');if(!b||kind!=='audit')return;e.preventDefault();const col=Number(b.dataset.tableSort),prev=adminColumnSort.audit;adminColumnSort.audit={col,dir:prev?.col===col&&prev.dir==='asc'?'desc':'asc'};page=1;load().catch(fail);};
   $('#search')?.addEventListener('submit',e=>{e.preventDefault();query=$('#searchText').value.trim();status=$('#status')?.value||'all';page=1;load().catch(fail);});
   if(kind==='products'&&can(context,'master')){$('#new')?.insertAdjacentHTML('afterend','<button type="button" id="importProducts" class="secondary">품목 Excel 가져오기</button>');$('#importProducts')?.addEventListener('click',()=>mes.importForm('products'));}
   if($('#searchText')){let delay;$('#searchText').oninput=e=>{clearTimeout(delay);const text=e.target.value,pos=e.target.selectionStart;delay=setTimeout(async()=>{query=text;page=1;try{await load();const box=$('#searchText');if(box&&box.value===text){box.focus();box.setSelectionRange(pos,pos);}}catch(x){fail(x);}},320);};}
   $('#new')?.addEventListener('click',()=>edit(kind));all('[data-edit]').forEach(b=>b.onclick=()=>edit(kind,rows.find(r=>r.id===b.dataset.edit)));
   all('[data-access]').forEach(b=>b.onclick=()=>access(rows.find(r=>r.id===b.dataset.access)));
   $('#prev').onclick=guarded(async()=>{page--;await load();});$('#next').onclick=guarded(async()=>{page++;await load();});
  }
  $('#connection').textContent='● 연결됨 · '+new Date().toLocaleTimeString('ko-KR',{timeZone:'Asia/Seoul'});
 }catch(e){if(ticket===generation){$('#connection').textContent='연결 확인 필요';throw e;}}
}
function openForm(title,body,save,{voice=false}={}){
 stopVoice();const d=$('#editor');d.innerHTML=`<form><div class="dialog-head"><h2>${title}</h2></div><div class="dialog-body">${body}</div><div id="dialogMessage" class="message dialog-message" role="alert" hidden></div><div class="dialog-footer"><button type="button" id="close" class="secondary">닫기</button><button id="save">저장</button></div></form>`;d.showModal();
 const close=()=>{stopVoice();d.close();};$('#close').onclick=close;d.oncancel=()=>stopVoice();
 if(voice)stopVoice=voiceFor($('#noteBody'),$('#voice'),$('#voiceState'));
 d.querySelector('form').addEventListener('invalid',()=>message('필수 항목과 입력 형식을 확인하세요. 표시된 입력란을 수정한 후 저장하세요.',true),true);
 d.querySelector('form').onsubmit=async e=>{e.preventDefault();const button=$('#save'),cancel=$('#close');let unknown=false;button.disabled=true;cancel.disabled=true;const wait=beginActivity('저장 중입니다…');d.oncancel=x=>x.preventDefault();stopVoice();try{await save(Object.fromEntries(new FormData(e.target)));close();if(me){try{await load();message('저장했습니다.');}catch(x){message('저장은 완료됐지만 목록을 다시 조회하지 못했습니다. '+x.message,true);}}}catch(x){message(x.message,true);unknown=!!x.unknown;if(unknown)button.textContent='닫고 결과를 확인하세요';}finally{wait.end();button.disabled=unknown;cancel.disabled=false;d.oncancel=()=>stopVoice();}};
}
function edit(kind,r){
 let body='';if(kind==='notes')body=field('title','제목',r?.title,'text','required maxlength="160"')+`<label>내용<textarea id="noteBody" name="body" required maxlength="10000">${esc(r?.body)}</textarea></label><div class="speech-row"><button id="voice" type="button" class="secondary">음성 입력</button><span id="voiceState" role="status">브라우저 음성인식은 외부 서비스에서 처리될 수 있습니다. 인식 결과를 확인한 후 저장하세요.</span></div>`;
 else{body='<div class="fields">'+field('code',kind==='products'?'제품코드 / 품번':'거래처 코드',r?.code,'text','required maxlength="100"')+field('name',kind==='products'?'품명':'거래처명',r?.name,'text','required maxlength="200"');
 if(kind==='products')body+=field('project','Project',r?.project,'text','maxlength="200"')+field('unit','단위',r?.unit,'text','maxlength="20"');
 else body+=`<label>구분<select name="category">${[['customer','고객사'],['supplier','공급업체'],['both','고객·공급']].map(([v,t])=>`<option value="${v}" ${r?.category===v?'selected':''}>${t}</option>`).join('')}</select></label>`+field('contact','담당자',r?.contact,'text','maxlength="100"')+field('phone','연락처',r?.phone,'text','maxlength="80"');
 body+='</div><label class="check"><input type="checkbox" name="active" '+(r?.active===false?'':'checked')+'>사용 중</label>';}
 openForm(labels[kind]+(r?' 수정':' 등록'),body,async f=>{await api.save(kind,cleanRecord(kind,f),r);},{voice:kind==='notes'});
}
function access(r){openForm('사용자 활성화·권한',`<p>${esc(r.email)}</p>${field('name','성명',r.display_name,'text','required maxlength="100"')}<label>역할<select name="role">${Object.entries(roleLabel).map(([v,t])=>`<option value="${v}" ${v===r.role?'selected':''}>${t}</option>`).join('')}</select></label><label class="check"><input name="active" type="checkbox" ${r.active?'checked':''}>사용 허용</label><p class="muted">관리자: 사용자 관리와 모든 자료 수정<br>담당자: 사용자별 메뉴·조회·등록·수정 권한 별도 지정 필요<br>조회자: 허용된 메뉴의 조회만 가능</p>`,f=>api.access({p_id:r.id,p_version:r.version,p_name:f.name,p_role:f.role,p_active:f.active==='on'}));}
try{api=new PortalApi(settings(SUPABASE_URL,SUPABASE_PUBLIC_KEY));if(api.session)await enter();else login();}catch(e){if(api)login(e.message);else{$('#app').innerHTML=`<div class="login"><section class="hero"><div class="brand"><img src="assets/dnm-logo.png" alt="디엔엠"></div><h1>클라우드 업무포털</h1><p>내부 서버 없이 PC와 휴대폰을 연결합니다.</p></section><section class="loginbox"><div><span class="tag off">연결 설정 필요</span><h2>두 값을 입력하면 시작할 수 있습니다.</h2><p>${esc(e.message)}</p><ol><li>Supabase DB 초기 설정</li><li>config.js의 URL·공개용 키 입력</li><li>Netlify에 public 폴더 배포</li></ol><p>아직 DB에 연결되지 않았습니다. 로그인이나 저장이 된 것처럼 표시하지 않습니다.</p><a href="setup.html">실제 설치 순서 열기</a></div></section></div>`;}}
setInterval(()=>{if(!me||navigationBusy||mes?.loadingImport||mes?.loadingBackup||!['dashboard','orders','routing','instructions','touchWork','voiceWork','worklogs','purchase','receipts','settlement','quality'].includes(tab)||document.hidden||($('#editor').open||document.querySelector('#v4dialog')?.open)||['INPUT','SELECT','TEXTAREA'].includes(document.activeElement?.tagName))return;(async()=>{const contextSignature=c=>JSON.stringify([c?.profile?.role,c?.permissions,c?.capabilities]);const before=contextSignature(context);if(!await refreshContext())return;if(before!==contextSignature(context)){if(!pageAllowed(context,tab))tab=firstPage(context);shell();}await load();})().catch(fail);},15000);
window.addEventListener('beforeunload',e=>{if(mes?.loadingImport||mes?.loadingBackup){e.preventDefault();e.returnValue='';}});

window.addEventListener('resize',()=>{
 if(!me)return;
 if(window.matchMedia('(min-width:901px)').matches&&document.querySelector('.app-shell.nav-open'))setMobileMenu(false);
 const menu=$('#sideMenu');if(menu)keepSelectedVisible(menu);
},{passive:true});
