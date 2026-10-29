// Pure v4.1 domain helpers; no network, no automatic database mutations.
export const ORDER_FIELDS=[['po_no','PO 번호'],['part_no','자재코드'],['part_name','자재명'],['grade_code','등급코드'],['qty','발주수량'],['received_qty','입고수량'],['unit_price','발주단가'],['order_amount','발주금액'],['order_date','발주일자'],['due_date','납기일자'],['production_no','생산오더'],['project','Project내역']];
const collator=new Intl.Collator('ko',{numeric:true,sensitivity:'base'});
export function routingSort(a,b){return collator.compare(a.data?.part_no||a.code||'',b.data?.part_no||b.code||'')||String(a.data?.due_date||'9999-12-31').localeCompare(b.data?.due_date||'9999-12-31')||collator.compare(a.code||'',b.code||'');}
export function routeBucket(r){return r.state==='DONE'?'closed':['DRAFT','RELEASED'].includes(r.state)?'open':'history';}
export function templateMatch(order,templates){
 const part=String(order.data?.part_no||order.part_no||'').trim();
 const matched=templates.filter(t=>(t.data?.part_no||t.code)===part && t.state!=='INACTIVE' && t.data?.active!==false);
 const verified=matched.filter(t=>t.data?.review_required===false && Array.isArray(t.data?.steps)&&t.data.steps.length);
 if(verified.length===1)return {mode:'repeat',label:'양산 · 템플릿 매칭',template:verified[0]};
 if(verified.length>1)return {mode:'ambiguous',label:'템플릿 중복 검토',template:null};
 if(matched.length)return {mode:'review',label:'템플릿 검토 필요',template:matched[0]};
 return {mode:'new',label:'신규 · 제품 Routing 등록',template:null};
}
export function routeProgress(route,operations){const ops=operations.filter(o=>o.parent_id===route.id).sort((a,b)=>a.data.seq-b.data.seq);const done=ops.filter(o=>o.state==='DONE').length;const pending=ops.filter(o=>o.state==='PENDING').length;const ratio=ops.length?ops.reduce((s,o)=>s+Math.min(1,Math.max(0,Number(o.data.confirmed_qty||0)/Math.max(1,Number(o.data.qty||1)))),0)/ops.length:0;return{ops,done,pending,percent:Math.round(ratio*100),complete:ops.length>0&&done===ops.length&&!pending};}
export function keywordMatch(row,q){const needle=String(q||'').trim().toLocaleLowerCase();if(!needle)return true;const flatten=(v,depth=0)=>{if(depth>4)return '';if(Array.isArray(v))return v.map(x=>flatten(x,depth+1)).join(' ');if(v&&typeof v==='object')return Object.entries(v).filter(([k])=>k!=='source'&&k!=='values'&&k!=='columns').map(([,x])=>flatten(x,depth+1)).join(' ');return String(v??'');};return flatten(row).toLocaleLowerCase().includes(needle);}
export function assignedWork(routes,operations,profileId,scope='mine'){const ids=new Set(routes.filter(r=>r.state==='RELEASED').map(r=>r.id));return operations.filter(o=>ids.has(o.parent_id)&&!['DONE','CANCELLED'].includes(o.state)&&(scope==='all'||o.data.profile_id===profileId||o.data.profile_ids?.includes(profileId))).sort(routingSort);}
// A work order may span multiple dates, workers and machines. A person's status is
// derived from their own log segments, not solely from the shared operation state.
export const WORK_STATES={ASSIGNED:'지시됨',ACTIVE:'작업 중',PAUSED:'일시중지',PENDING:'수량확인',PARTIAL:'부분완료',DONE:'공정완료'};
export function workerTaskStatus(op,logs,profileId){
 const mine=logs.filter(l=>l.parent_id===op.id && l.state!=='CANCELLED' && l.data?.profile_id===profileId)
  .sort((a,b)=>String(a.data?.end_at||a.data?.start_at||a.updated_at||'').localeCompare(String(b.data?.end_at||b.data?.start_at||b.updated_at||'')));
 const active=[...mine].reverse().find(l=>l.state==='ACTIVE')||null;
 const pending=[...mine].reverse().find(l=>l.state==='PENDING')||null;
 const last=mine.at(-1)||null;
 const pauses=mine.filter(l=>l.state==='PAUSED');
 const confirmed=mine.filter(l=>l.state==='CONFIRMED');
 const personalQty=confirmed.reduce((n,l)=>n+Number(l.data?.total||0),0);
 const code=op.state==='DONE'?'DONE':active?'ACTIVE':pending?'PENDING':last?.state==='PAUSED'?'PAUSED':confirmed.length?'PARTIAL':'ASSIGNED';
 return {code,label:WORK_STATES[code],active,pending,last,logs:mine,personalQty,days:[...new Set(mine.map(l=>l.data?.work_date).filter(Boolean))].length,pausedCount:pauses.length};
}
export function workerAssignedOperations(routes,operations,profileId,scope='mine'){
 const visible=new Set(routes.filter(r=>['RELEASED','DONE'].includes(r.state)).map(r=>r.id));
 return operations.filter(op=>visible.has(op.parent_id) && (scope==='all' || op.data?.profile_id===profileId || op.data?.profile_ids?.includes(profileId)))
 .sort((a,b)=>String(a.data?.due_date||'').localeCompare(String(b.data?.due_date||''))||routingSort(a,b));
}
export function blankStep(i=1){return{code:String(i*10).padStart(3,'0'),name:'',kind:'WORK',note:'',inspection_code:'M',equipment_id:'',employee_id:'',equipment_label:''};}
export function validateSteps(steps){if(!Array.isArray(steps)||!steps.length||steps.length>60)throw Error('공정은 1~60개로 작성하세요.');return steps.map((s,i)=>{const code=String(s.code||'').trim(),name=String(s.name||'').trim();if(!code||!name)throw Error(`${i+1}번째 공정번호·공정명을 입력하세요.`);if(!['WORK','MATERIAL','INSPECTION','OUTSOURCE','PACK'].includes(s.kind))throw Error('공정 유형을 확인하세요.');if(!['','M','I','V'].includes(s.inspection_code||''))throw Error('검사코드는 M / I / V 또는 공란입니다.');const ids=Array.isArray(s.employee_ids)?s.employee_ids.filter(Boolean):(s.employee_id?[s.employee_id]:[]);if(ids.length>20||ids.length!==new Set(ids).size)throw Error(`${i+1}번째 작업자는 중복 없이 20명 이하로 선택하세요.`);return {...s,employee_ids:ids,employee_id:ids[0]||'',seq:i+1,code,name,note:String(s.note||'').trim(),inspection_code:s.inspection_code||''};});}
export function parseVoiceCommand(input){
 const original=String(input||'').trim();const hasStart=/시작/.test(original),hasFinish=/완료/.test(original),hasEnd=/종료|중지/.test(original);
 const result={original,action:hasStart?'start':hasFinish?'complete':hasEnd?'stop':'unknown',total:null,defect:null,needsConfirmation:true,error:''};
 if(hasStart&&(hasFinish||hasEnd)){result.error='시작과 종료가 함께 들렸습니다. 한 동작씩 말씀해 주세요.';return result;}
 if(result.action==='unknown')result.error='작업 시작, 작업 종료, 공정 완료 중 하나를 말씀해 주세요.';
 for(const [k,re] of [['total',/(?:총(?:\s*수량)?|생산\s*수량|작업\s*수량)\s*[:：]?\s*(\d[\d,]*)\s*(?:개|EA)?/gi],['defect',/불량(?:\s*수량)?\s*[:：]?\s*(\d[\d,]*)\s*(?:개|EA)?/gi]]){const nums=[...original.matchAll(re)].map(m=>Number(m[1].replace(/,/g,'')));if(nums.length>1){result.error='같은 수량이 여러 번 언급되었습니다. 문장을 정리해 다시 확인하세요.';}else if(nums.length===1)result[k]=nums[0];}
 if(result.total!==null&&result.defect!==null&&result.defect>result.total)result.error='불량수량이 총수량보다 큽니다. 다시 확인하세요.';
 if(/대략|정도|쯤|아마|아니|취소/.test(original))result.error='정정·추정 표현이 포함되어 있습니다. 정확한 동작과 수량을 다시 입력하세요.';
 return result;
}
