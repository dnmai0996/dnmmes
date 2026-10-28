import {esc} from '../core.js';
import {GROUPS,TOP_PAGES,navGroups} from './permissions.js';
export const NAV_LABELS={
 dashboard:'작업진척 대시보드',orders:'고객 수주',sourceOrders:'수주 원본 82열',
 templates:'제품 Routing 템플릿',routeCandidates:'Routing 원문 후보',routingSetup:'수주 → Routing 초안',routing:'Routing Sheet 관리',
 instructions:'작업지시 · 배포현황',workCards:'작업일보 사전양식',touchWork:'터치 작업입력',voiceWork:'음성 작업입력',worklogs:'작업일보',
 purchase:'구매요청 · 결재',receipts:'발주 · 입고 · 반품',settlement:'정산',quality:'품질 · 출하',documents:'품질문서 대장',
 equipment:'설비관리',instruments:'계측기관리',products:'제품',materials:'자재',employees:'작업자',processes:'공정',customers:'매출처',suppliers:'매입처',assignments:'설비·작업자 연결',catalog:'공구·공급업체',
 seedData:'첨부자료 일괄등록',workforceSetup:'계정·설비 일괄연결',sourceReview:'기준정보 검토·활성화',archives:'과거 Routing 참조',notes:'공유메모',profiles:'사용자 등록·초기화',access:'사용자별 권한 · 전결',audit:'변경 이력',backup:'백업 · 운영점검',home:'공통관리 현황'
};
export function groupFor(page){return GROUPS.find(([,pages])=>pages.includes(page))?.[0]||'';}
export function firstPage(ctx){
 const pages=navGroups(ctx).flatMap(g=>g.pages);
 return pages.includes('dashboard')?'dashboard':pages.includes('touchWork')?'touchWork':pages[0]||'noAccess';
}
export function restoreMenuState(value){
 if(!value||typeof value!=='object'||Array.isArray(value))return {};
 const safe={};for(const [key,v] of Object.entries(value))if(typeof v==='boolean')safe[key]=v;
 // Keep users' preferences for unchanged groups; migrate the old combined groups only once.
 for(const key of ['수주관리','생산관리'])if(safe[key]===undefined&&safe['현장·생산']!==undefined)safe[key]=safe['현장·생산'];
 for(const key of ['구매관리','품질관리'])if(safe[key]===undefined&&safe['구매·품질']!==undefined)safe[key]=safe['구매·품질'];
 return safe;
}
export function renderNavigation(tabs,current,state={}){
 const allowed=new Set(tabs),saved=restoreMenuState(state);
 const button=page=>`<button type="button" data-tab="${esc(page)}" class="nav-link${current===page?' selected':''}"${current===page?' aria-current="page"':''}><span>${esc(page==='dashboard'?'대시보드':NAV_LABELS[page])}</span>${current===page?'<span class="nav-current-tag" aria-hidden="true">현재</span>':''}</button>`;
 const top=TOP_PAGES.filter(p=>allowed.has(p)).map(p=>`<div class="nav-home">${button(p)}</div>`).join('');
 const groups=GROUPS.map(([title,keys])=>{
  const visible=keys.filter(k=>allowed.has(k));if(!visible.length)return '';
  const active=visible.includes(current),open=active||saved[title]===true;
  return `<details class="nav-section${active?' current-group':''}" data-navgroup="${esc(title)}"${open?' open':''}><summary><span class="nav-group-name">${esc(title)}</span><span class="nav-count">${visible.length}</span></summary><div class="nav-items">${visible.map(button).join('')}</div></details>`;
 }).join('');
 return top+groups;
}
export function breadcrumbMarkup(page){
 const title=NAV_LABELS[page]||'사용권한 확인',group=groupFor(page);
 return `<span class="path-prefix">현재 위치</span>${group?`<span>${esc(group)}</span><span aria-hidden="true">›</span>`:''}<strong>${esc(title)}</strong>`;
}
/** Move only the menu's own scrollbar; never scroll the page or horizontal data tables. */
export function keepSelectedVisible(menu){
 if(!menu||!menu.clientHeight)return;
 const item=menu.querySelector('[aria-current="page"]');if(!item||!item.getClientRects().length)return;
 const bounds=menu.getBoundingClientRect(),box=item.getBoundingClientRect(),pad=8;
 const summary=item.closest('details')?.querySelector('summary');
 const inset=summary&&summary.getBoundingClientRect().top<=bounds.top+2?summary.offsetHeight:0;
 if(box.top<bounds.top+inset+pad)menu.scrollTop-=bounds.top+inset+pad-box.top;
 else if(box.bottom>bounds.bottom-pad)menu.scrollTop+=box.bottom-bounds.bottom+pad;
}
