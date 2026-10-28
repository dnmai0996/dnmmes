import {SUPABASE_URL,SUPABASE_PUBLIC_KEY} from './config.js';
import {VERSION,esc,settings,listQuery,adminListQuery,cleanRecord} from './core.js';
import {PortalApi} from './api.js';
import {voiceFor} from './speech.js';
import {V41Controller as MesController} from './modules/v41.js';
import {MesService} from './modules/service.js';
import {can} from './modules/domain.js';
import {modal as helpModal} from './modules/ui.js';
const $=s=>document.querySelector(s),all=s=>[...document.querySelectorAll(s)];
const labels={dashboard:'작업진척 대시보드',orders:'고객 수주',sourceOrders:'수주 원본 82열',routing:'Routing · 작업지시',touchWork:'터치 작업입력',voiceWork:'음성 작업입력',worklogs:'작업일보',purchase:'구매요청 · 결재',receipts:'발주 · 입고 · 반품',settlement:'정산',quality:'품질 · 출하',documents:'품질문서 대장',products:'제품',materials:'자재',processes:'공정',customers:'매출처',suppliers:'매입처',equipment:'설비대장',instruments:'계측기대장',employees:'작업자',assignments:'설비·작업자 연결',templates:'제품 Routing 템플릿',catalog:'공구·공급업체',notes:'공유메모',profiles:'사용자 관리',access:'업무권한 · 전결',audit:'변경 이력',backup:'백업 · 운영점검',home:'공통관리 현황'};
const legacyTabs=['home','notes','profiles','audit'];
let mes,context;
const roleLabel={admin:'관리자',member:'담당자',viewer:'조회자'};
let api,me,tab='home',page=1,query='',status='active',generation=0,stopVoice=()=>{};
const clock=v=>new Date(v).toLocaleString('ko-KR',{timeZone:'Asia/Seoul'});
function message(text,error=false){const box=$('#editor').open?$('#dialogMessage'):$('#message');if(box){box.hidden=false;box.className='message'+(error?' error':'')+($('#editor').open?' dialog-message':'');box.textContent=text;}}
function fail(e){const text=e?.message||'처리 결과를 확인하지 못했습니다. 다시 조회하세요.';message(text,true);if(api&&!api.session)login(text);}
function guarded(fn){return async()=>{try{await fn();}catch(e){fail(e);}};}
function login(msg=''){
 generation++;me=null;document.body.classList.remove('tv-mode');document.querySelector('#v4dialog')?.close();stopVoice();$('#editor').close();
 $('#app').innerHTML=`<div class="login"><section class="hero"><div class="brand"><img src="assets/dnm-logo.png" alt="디엔엠"></div><div class="eyebrow">CONNECTED WORKSPACE</div><h1>어디서든 이어지는<br>우리의 업무.</h1><p>수주에서 생산·품질까지,<br>현장의 기록을 한 곳에서 연결합니다.</p></section><section class="loginbox"><div><span class="tag">클라우드 MES · ${VERSION}</span><h2>개인 계정으로 로그인</h2><p class="muted">회사에서 등록한 이메일과 비밀번호를 사용하세요.</p><form id="loginForm"><label>이메일<input name="email" type="email" autocomplete="username" required></label><label>비밀번호<input name="password" type="password" autocomplete="current-password" required></label><button class="full">로그인</button></form><div id="message" class="message${msg?' error':''}" role="status" ${msg?'':'hidden'}>${esc(msg)}</div><p class="muted">계정 발급·잠금 해제는 관리자에게 요청하세요.</p><p><a href="setup.html" target="_blank" rel="noopener">처음 설치하는 담당자 안내</a></p><small>Ollama 미연결 · 기본 업무 사용 가능</small></div></section></div>`;
 $('#message').insertAdjacentHTML('afterend',`<details id="diagnostics"><summary>Supabase 연결 진단</summary><p class="message">연결 주소: ${esc(api.c.url)}</p><button id="checkConnection" type="button" class="secondary full">연결 확인 (비밀번호 불필요)</button><div id="diagnosticResult" class="message" role="status" hidden></div></details>`);
 $('#checkConnection').onclick=async()=>{
  const button=$('#checkConnection'),box=$('#diagnosticResult');button.disabled=true;box.hidden=false;box.className='message';box.textContent='인증 서비스 연결을 확인하고 있습니다…';
  try{const result=await api.checkConnection();
   if(result.emailEnabled===false){box.className='message error';box.textContent='인증 서비스에 접속했지만 이메일 로그인이 꺼져 있습니다. Supabase Authentication → Sign In / Providers에서 Email을 확인하세요.';}
   else box.textContent='인증 서비스의 공개 설정을 정상 조회했습니다. '+(result.emailEnabled===true?'이메일 로그인도 활성화되어 있습니다. ':'이메일 로그인 활성 상태는 이 응답에서 확인되지 않았습니다. ')+'이제 로그인해 계정과 업무 DB 접근을 확인하세요.';
  }catch(x){box.className='message error';box.textContent=x.message;
   if(['CONNECTION_FAILED','TIMEOUT'].includes(x.code))box.textContent+='\n확인 순서: 위 주소를 Supabase의 실제 Project URL과 대조 → 프로젝트 실행 상태 확인 → 휴대폰 모바일 데이터로 같은 Netlify 주소에서 연결 진단. 브라우저 차단·DNS·통신 오류는 이 결과만으로 구분할 수 없습니다.';
  }finally{button.disabled=false;}
 };
 $('#loginForm').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('button');b.disabled=true;try{const f=Object.fromEntries(new FormData(e.target));await api.login(f.email.trim(),f.password);await enter();}catch(x){message(x.message,true);if(['CONNECTION_FAILED','TIMEOUT','INVALID_RESPONSE','HTTP_401'].includes(x.code)&&$('#diagnostics'))$('#diagnostics').open=true;}finally{b.disabled=false;}};
}
async function enter(){
 const {data}=await api.rows('profiles','select=*&id=eq.'+encodeURIComponent(api.session.user.id));me=data[0];
 if(!me?.active){await api.logout().catch(()=>{});login('계정 활성화 대기 중입니다. 관리자에게 사용자 등록을 요청하세요.');return;}
 try{context=await new MesService(api).context();if(context?.profile?.id!==me.id||!['4.0.0','4.1.0'].includes(context?.version))throw Error('v4 데이터베이스 응답을 확인하지 못했습니다.');}catch(e){context={profile:me,capabilities:[],schemaError:e.message};}
 mes=new MesController(api,context,(target,detail)=>{tab=target;shell();if(detail){mes.page=target;mes.detail=detail;}load().catch(fail);});
 tab=context?.version?(context.profile.role==='member'&&context.capabilities?.includes('work')&&!context.capabilities?.some(c=>['production','master','purchase','quality'].includes(c))?'touchWork':'dashboard'):'home';shell();await load();if(context.schemaError)message('기존 로그인·공통자료 기능은 유지됩니다. v4 DB 확장 연결을 확인하세요. database/04_upgrade_v4.sql 적용 및 같은 Supabase 프로젝트인지 확인하십시오. '+context.schemaError,true);
}
function navMarkup(tabs){
 const groups=[['생산업무',['dashboard','orders','sourceOrders','routing','touchWork','voiceWork','worklogs']],['구매·품질',['purchase','receipts','settlement','quality','documents']],['기준정보',['products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog']],['운영관리',['notes','profiles','access','audit','backup','home']]];
 return groups.map(([name,keys])=>{const visible=keys.filter(k=>tabs.includes(k));if(!visible.length)return '';return `<section class="nav-group"><span class="nav-group-title">${name}</span>${visible.map(k=>`<button data-tab="${k}" class="${tab===k?'selected':''}">${labels[k]}</button>`).join('')}</section>`;}).join('');
}
function shell(){
 const tabs=Object.keys(labels).filter(k=>{if(!context?.version&&!legacyTabs.includes(k))return false;if(['profiles','audit','access','backup'].includes(k))return me.role==='admin';if(k==='sourceOrders')return can(context,'production')||can(context,'master');if(['settlement','receipts'].includes(k))return can(context,'purchase');if(k==='documents')return can(context,'quality')||can(context,'production')||can(context,'master');return true;});
 $('#app').innerHTML=`<div class="app-shell"><aside class="sidebar"><div><div class="brand"><img src="assets/dnm-logo.png" alt="디엔엠"></div><small>구매·생산 통합관리</small></div><nav aria-label="업무 메뉴">${navMarkup(tabs)}</nav><footer>${VERSION}<br>공동 데이터 · Supabase<br>Ollama 연결 불필요</footer></aside><div><header class="topbar"><span id="connection" role="status">연결 확인 중</span><div class="who">${esc(me.display_name||me.email)} · ${roleLabel[me.role]}</div><div><button id="password" class="secondary">비밀번호</button> <button id="logout" class="quiet">로그아웃</button></div></header><main class="workspace"><div class="heading"><div><h1 id="title">${labels[tab]}</h1><span class="muted">PC와 휴대폰에서 같은 자료를 확인합니다.</span></div><div class="actions"><button id="vhelp" class="secondary">❔ 사용방법</button><button id="reload" class="secondary">새로고침</button></div></div><div id="message" class="message" role="status" hidden></div><div id="content"></div></main></div></div>`;
 all('[data-tab]').forEach(b=>b.onclick=guarded(async()=>{tab=b.dataset.tab;page=1;query='';status='active';shell();await load();}));
 $('#vhelp').onclick=()=>{if(!legacyTabs.includes(tab))mes.help();else helpModal(labels[tab]+' 사용방법', '<p>자료를 검색하고 신규 등록 또는 수정을 선택하세요. 변경 후 저장 결과를 확인하십시오.</p><p>사용자 계정은 Supabase Authentication에서 생성한 후 관리자 화면에서 활성화합니다. 별도의 v4 업무권한은 업무권한·전결 화면에서 지정합니다.</p>');};
 $('#reload').onclick=guarded(load);$('#logout').onclick=guarded(async()=>{try{await api.logout();}finally{login();}});
 $('#password').onclick=()=>openForm('비밀번호 변경',field('current','현재 비밀번호','','password','required autocomplete="current-password"')+field('next','새 비밀번호 (12자 이상)','','password','required minlength="12" autocomplete="new-password"')+field('repeat','새 비밀번호 확인','','password','required minlength="12" autocomplete="new-password"'),async f=>{if(f.next!==f.repeat)throw Error('새 비밀번호가 일치하지 않습니다.');if(f.current===f.next)throw Error('기존과 다른 비밀번호를 사용하세요.');await api.login(me.email,f.current);await api.request('/auth/v1/user',{method:'PUT',body:{password:f.next}});await api.logout();login('비밀번호가 변경됐습니다. 새 비밀번호로 로그인하세요.');});
}
const field=(name,label,value='',type='text',attrs='')=>`<label>${label}<input name="${name}" type="${type}" value="${esc(value)}" ${attrs}></label>`;
const empty='<div class="empty">등록된 자료가 없습니다.</div>';
function grid(headers,rows){return rows.length?`<div class="table-wrap"><table><thead><tr>${headers.map(h=>`<th>${h}</th>`).join('')}</tr></thead><tbody>${rows.map(r=>`<tr>${r.map(c=>`<td class="wrap">${c}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`:empty;}
function editable(){return me.role!=='viewer';}
async function load(){
 const ticket=++generation,kind=tab;$('#connection').textContent='조회 중…';
 try{
  if(!legacyTabs.includes(kind)){await mes.load(kind);if(ticket!==generation)return;}else if(kind==='home'){
   const counts=await Promise.all(['products','partners','notes'].map(k=>api.rows(k,'select=id&limit=1')));if(ticket!==generation)return;
   $('#content').innerHTML=`<div class="metrics">${counts.map((r,i)=>`<div class="card metric"><span>${['제품','거래처','공유메모'][i]}</span><b>${r.total||0}</b></div>`).join('')}</div><div class="card"><h2>한 곳에 저장하고, 함께 확인합니다.</h2><p class="muted">자료는 연결된 Supabase에 저장됩니다. 다른 기기의 변경은 새로고침하거나 잠시 기다리면 확인할 수 있습니다.</p><div class="flow">품목 기준정보 · 제품코드, 품명, Project, 단위<br>거래처 · 고객사와 공급업체 연락정보<br>공유메모 · 음성 또는 직접 입력 후 확인·저장</div></div><div class="card"><h2>연결 상태</h2><p>공동 DB: 연결됨</p><p>Ollama: 미연결 — 이 앱의 기본 기능에는 필요하지 않습니다.</p><small>음성 입력은 지원 브라우저에서 사용합니다. 인식 결과는 저장 전에 수정할 수 있습니다.</small></div>`;
  }else{
   let q=['products','partners','notes'].includes(kind)?listQuery(kind,page,query,status):adminListQuery(kind,page,query);
   const {data:rows,total}=await api.rows(kind,q);if(ticket!==generation)return;
   const search=['products','partners','notes','profiles','audit'].includes(kind),canAdd=['products','partners','notes'].includes(kind)&&editable();
   let html=search?`<form id="search" class="toolbar"><label class="sr" for="searchText">검색</label><input id="searchText" placeholder="${kind==='notes'?'제목 또는 내용':kind==='profiles'?'성명·이메일·역할':kind==='audit'?'대상·작업 유형':'코드 또는 명칭'} 검색" value="${esc(query)}">${['products','partners'].includes(kind)?`<select id="status" aria-label="사용 상태"><option value="active" ${status==='active'?'selected':''}>사용 중</option><option value="inactive" ${status==='inactive'?'selected':''}>사용 중지</option><option value="all" ${status==='all'?'selected':''}>전체</option></select>`:''}<button>검색</button>${canAdd?'<button id="new" type="button" class="secondary">신규 등록</button>':''}</form>`:'';
   if(kind==='products')html+=grid(['품번','품명','Project','단위','상태','관리'],rows.map(r=>[esc(r.code),esc(r.name),esc(r.project),esc(r.unit)||'미확인',r.active?'사용':'중지',editable()?`<button data-edit="${r.id}" class="secondary">수정</button>`:'조회']));
   if(kind==='partners')html+=grid(['코드','거래처명','구분','담당자 / 연락처','상태','관리'],rows.map(r=>[esc(r.code),esc(r.name),{customer:'고객사',supplier:'공급업체',both:'고객·공급'}[r.category],esc(r.contact)+'<br>'+esc(r.phone),r.active?'사용':'중지',editable()?`<button data-edit="${r.id}" class="secondary">수정</button>`:'조회']));
   if(kind==='notes')html+=rows.length?rows.map(r=>`<article class="card note-card"><h2>${esc(r.title)}</h2><div class="note-body">${esc(r.body)}</div><div class="note-meta">${clock(r.updated_at)} · v${r.version}${r.owner_id===me.id?' · 내가 작성':''}</div>${editable()&&(r.owner_id===me.id||me.role==='admin')?`<button data-edit="${r.id}" class="secondary">수정</button>`:''}</article>`).join(''):empty;
   if(kind==='profiles')html+='<p class="muted">새 계정은 Supabase Authentication → Users에서 생성한 뒤 여기서 활성화하세요.</p>'+grid(['이메일','성명','역할','상태','관리'],rows.map(r=>[esc(r.email),esc(r.display_name),roleLabel[r.role],r.active?'활성':'대기/차단',r.id===me.id?'본인':`<button data-access="${r.id}" class="secondary">권한 변경</button>`]));
   if(kind==='audit')html+=grid(['변경 시각','대상','작업','작성자 ID','자료 ID'],rows.map(r=>[clock(r.created_at),esc(r.entity),esc(r.action),esc(r.actor_id||'DB 관리자'),esc(r.record_id)]));
   html+=`<div class="pagination"><button id="prev" class="secondary" ${page===1?'disabled':''}>이전</button><span>${page} / ${Math.max(1,Math.ceil(total/25))} · 총 ${total}건</span><button id="next" class="secondary" ${page*25>=total?'disabled':''}>다음</button></div>`;
   $('#content').innerHTML='<div class="card">'+html+'</div>';
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
 d.querySelector('form').onsubmit=async e=>{e.preventDefault();const button=$('#save'),cancel=$('#close');let unknown=false;button.disabled=true;cancel.disabled=true;d.oncancel=x=>x.preventDefault();stopVoice();try{await save(Object.fromEntries(new FormData(e.target)));close();if(me){try{await load();message('저장했습니다.');}catch(x){message('저장은 완료됐지만 목록을 다시 조회하지 못했습니다. '+x.message,true);}}}catch(x){message(x.message,true);unknown=!!x.unknown;if(unknown)button.textContent='닫고 결과를 확인하세요';}finally{button.disabled=unknown;cancel.disabled=false;d.oncancel=()=>stopVoice();}};
}
function edit(kind,r){
 let body='';if(kind==='notes')body=field('title','제목',r?.title,'text','required maxlength="160"')+`<label>내용<textarea id="noteBody" name="body" required maxlength="10000">${esc(r?.body)}</textarea></label><div class="speech-row"><button id="voice" type="button" class="secondary">음성 입력</button><span id="voiceState" role="status">브라우저 음성인식은 외부 서비스에서 처리될 수 있습니다. 인식 결과를 확인한 후 저장하세요.</span></div>`;
 else{body='<div class="fields">'+field('code',kind==='products'?'제품코드 / 품번':'거래처 코드',r?.code,'text','required maxlength="100"')+field('name',kind==='products'?'품명':'거래처명',r?.name,'text','required maxlength="200"');
 if(kind==='products')body+=field('project','Project',r?.project,'text','maxlength="200"')+field('unit','단위',r?.unit,'text','maxlength="20"');
 else body+=`<label>구분<select name="category">${[['customer','고객사'],['supplier','공급업체'],['both','고객·공급']].map(([v,t])=>`<option value="${v}" ${r?.category===v?'selected':''}>${t}</option>`).join('')}</select></label>`+field('contact','담당자',r?.contact,'text','maxlength="100"')+field('phone','연락처',r?.phone,'text','maxlength="80"');
 body+='</div><label class="check"><input type="checkbox" name="active" '+(r?.active===false?'':'checked')+'>사용 중</label>';}
 openForm(labels[kind]+(r?' 수정':' 등록'),body,async f=>{await api.save(kind,cleanRecord(kind,f),r);},{voice:kind==='notes'});
}
function access(r){openForm('사용자 활성화·권한',`<p>${esc(r.email)}</p>${field('name','성명',r.display_name,'text','required maxlength="100"')}<label>역할<select name="role">${Object.entries(roleLabel).map(([v,t])=>`<option value="${v}" ${v===r.role?'selected':''}>${t}</option>`).join('')}</select></label><label class="check"><input name="active" type="checkbox" ${r.active?'checked':''}>사용 허용</label><p class="muted">관리자: 사용자 관리와 모든 자료 수정<br>담당자: 기준정보 등록·수정 및 본인 메모 수정<br>조회자: 조회만 가능</p>`,f=>api.access({p_id:r.id,p_version:r.version,p_name:f.name,p_role:f.role,p_active:f.active==='on'}));}
try{api=new PortalApi(settings(SUPABASE_URL,SUPABASE_PUBLIC_KEY));if(api.session)await enter();else login();}catch(e){if(api)login(e.message);else{$('#app').innerHTML=`<div class="login"><section class="hero"><div class="brand"><img src="assets/dnm-logo.png" alt="디엔엠"></div><h1>클라우드 업무포털</h1><p>내부 서버 없이 PC와 휴대폰을 연결합니다.</p></section><section class="loginbox"><div><span class="tag off">연결 설정 필요</span><h2>두 값을 입력하면 시작할 수 있습니다.</h2><p>${esc(e.message)}</p><ol><li>Supabase DB 초기 설정</li><li>config.js의 URL·공개용 키 입력</li><li>Netlify에 public 폴더 배포</li></ol><p>아직 DB에 연결되지 않았습니다. 로그인이나 저장이 된 것처럼 표시하지 않습니다.</p><a href="setup.html">실제 설치 순서 열기</a></div></section></div>`;}}
setInterval(()=>{if(!me||!['dashboard','orders','routing','touchWork','voiceWork','worklogs','purchase','receipts','settlement','quality'].includes(tab)||document.hidden||($('#editor').open||document.querySelector('#v4dialog')?.open)||['INPUT','SELECT','TEXTAREA'].includes(document.activeElement?.tagName))return;load().catch(fail);},15000);
