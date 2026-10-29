import {userMessage} from './error-info.js';
import {beginActivity} from './activity.js';
import {esc} from '../core.js';
import {STATUS,csv} from './domain.js';
import {canSortHeader,localHeaderSort} from './table-sort.js';
export {esc};
export const $=(s,root=document)=>root.querySelector(s),all=(s,root=document)=>[...root.querySelectorAll(s)];
export const num=x=>Number(x||0).toLocaleString('ko-KR');
export const clock=s=>s?new Date(s).toLocaleString('ko-KR',{timeZone:'Asia/Seoul',hour12:false}):'—';
export const pill=s=>`<span class="pill p-${esc(s)}">${esc(STATUS[s]||s||'—')}</span>`;
export const btn=(action,label,id='',cls='secondary')=>`<button type="button" class="${cls}" data-vaction="${action}" data-id="${esc(id)}">${esc(label)}</button>`;
export const input=(name,label,value='',type='text',extra='')=>`<label>${esc(label)}<input name="${esc(name)}" type="${type}" value="${esc(value)}" ${extra}></label>`;
export const area=(name,label,value='',extra='')=>`<label>${esc(label)}<textarea name="${esc(name)}" ${extra}>${esc(value)}</textarea></label>`;
export const select=(name,label,options,value='',extra='')=>`<label>${esc(label)}<select name="${esc(name)}" ${extra}>${options.map(([v,l])=>`<option value="${esc(v)}" ${String(v)===String(value)?'selected':''}>${esc(l)}</option>`).join('')}</select></label>`;
export const table=(heads,rows)=>`<div class="table-wrap"><table><thead><tr>${heads.map((h,i)=>`<th>${canSortHeader(h)?`<button type="button" class="table-sort-button" data-table-sort="${i}" aria-label="${esc(h)} 기준 정렬">${esc(h)} <span class="sort-indicator" aria-hidden="true">⇅</span></button>`:esc(h)}</th>`).join('')}</tr></thead><tbody>${rows.length?rows.map(r=>`<tr>${r.map(x=>`<td>${x??''}</td>`).join('')}</tr>`).join(''):`<tr><td colspan="${heads.length}" class="empty">자료가 없습니다. 신규 등록 또는 자료 가져오기를 진행하세요.</td></tr>`}</tbody></table></div>`;
export const notice=(s,kind='info')=>`<div class="notice ${kind}">${esc(s)}</div>`;
export function message(s,kind='error'){if(kind==='error')s=userMessage(s);
 const d=$('#v4dialog');let e=d?.open?$('#v4message'):$('#message');if(!e)return;e.hidden=!s;e.className='message '+kind;e.textContent=s;e.setAttribute('role',kind==='error'?'alert':'status');e.setAttribute('aria-live',kind==='error'?'assertive':'polite');
}
let cleanup=()=>{};
export function closeModal(){const d=$('#v4dialog');if(d?.dataset.busy==='true')return;cleanup();cleanup=()=>{};d?.close();}
export function onModalClose(f){cleanup=f;}
export function modal(title,body,onSubmit=null,label='저장'){
 let d=$('#v4dialog');if(!d){d=document.createElement('dialog');d.id='v4dialog';document.body.append(d);}if(!d.dataset.sortAttached){d.addEventListener('click',e=>{const b=e.target.closest('[data-table-sort]');if(b&&d.contains(b)){e.preventDefault();localHeaderSort(b);}});d.dataset.sortAttached='true';}if(d.open)closeModal();d.dataset.busy='false';
 d.innerHTML=`<form id="v4form"><header><div><small>DNM 업무관리 4.9.0</small><h2>${esc(title)}</h2></div><button type="button" id="v4dismiss" class="quiet" aria-label="닫기">✕</button></header><section class="modalbody">${body}</section><div id="v4message" class="message" hidden role="alert"></div><footer><button type="button" id="v4cancel" class="secondary">닫기</button>${onSubmit?`<button id="v4submit">${esc(label)}</button>`:''}</footer></form>`;
 $('#v4cancel').onclick=$('#v4dismiss').onclick=closeModal;d.oncancel=e=>{if(d.dataset.busy==='true'){e.preventDefault();return;}cleanup();cleanup=()=>{};};d.showModal();
 let key=crypto.randomUUID(),frozen=null;
 $('#v4form').addEventListener('invalid',()=>message('필수 항목과 입력 형식을 확인하세요.'),true);
 $('#v4form').onsubmit=async e=>{e.preventDefault();if(!onSubmit||d.dataset.busy==='true')return;const f=frozen||Object.fromEntries(new FormData(e.target));busy(true);message('처리 중입니다. 중복 클릭하지 마세요.','info');
  try{await onSubmit(f,key);frozen=null;busy(false);closeModal();}
  catch(err){if(err.unknown){frozen=f;all('.modalbody input,.modalbody select,.modalbody textarea',d).forEach(x=>x.disabled=true);$('#v4submit').textContent='같은 요청 다시 확인';message(err.message+'\n입력값을 유지했습니다. 같은 요청번호로 재확인하거나 닫고 목록을 확인하세요.');}
   else{key=crypto.randomUUID();frozen=null;all('.modalbody input,.modalbody select,.modalbody textarea',d).forEach(x=>x.disabled=false);$('#v4submit').textContent=label;message(err.message);}}
  finally{busy(false);}
 };
 return d;
}
let modalActivity=null;
export function busy(v){if(v&&!modalActivity)modalActivity=beginActivity('처리 중입니다…',3);if(!v&&modalActivity){modalActivity.end();modalActivity=null;}const d=$('#v4dialog');d.dataset.busy=String(v);for(const id of ['#v4cancel','#v4dismiss','#v4submit'])if($(id))$(id).disabled=v;$('#v4form')?.setAttribute('aria-busy',String(v));}
export function download(name,content,type='application/json'){const blob=new Blob([content],{type}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);}
export function exportCSV(name,rows){download(name,csv(rows),'text/csv;charset=utf-8');}
export function printSheet(title,body){
 let p=$('#printArea');if(p)p.remove();p=document.createElement('section');p.id='printArea';p.innerHTML=`<header><strong>㈜디엔엠</strong><h1>${esc(title)}</h1><p>출력시각 ${esc(clock(new Date().toISOString()))} · 시스템 기록 사본</p></header>${body}<footer>이 출력물은 시스템 기록의 사본입니다. 공식 고객 제출 양식·서명·승인 여부는 담당자가 확인하십시오.</footer>`;document.body.append(p);window.print();
}
export function pager(page,total,size,callback){const p=$('#v4pager');if(!p)return;p.innerHTML=`<button type="button" class="secondary" id="vprev" ${page<=1?'disabled':''}>이전</button><span>${page} / ${Math.max(1,Math.ceil(total/size))} · ${num(total)}건</span><button type="button" class="secondary" id="vnext" ${page*size>=total?'disabled':''}>다음</button>`;$('#vprev').onclick=()=>callback(page-1);$('#vnext').onclick=()=>callback(page+1);}
