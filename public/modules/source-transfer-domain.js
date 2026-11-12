import {compareSourceRows,sourceRows} from './source-review.js';

export const currentStates=[['','확인대기'],['NOT_STARTED','미착수'],['IN_PROGRESS','작업 중'],['COMPLETED','완료·납품 (전환 제외)']];
export const transferLabels={PENDING:'보완대기',READY:'전환 검토 가능',CONVERTED:'전환 완료',EXCLUDED:'제외',RETURNED:'전환 LOT 삭제·취소',MISSING:'원문 미등록',AMBIGUOUS:'동일 LOT 원문 확인'};
const activeRoute=r=>!['CANCELLED','SUPERSEDED'].includes(r.state)&&r.data?.deleted!==true;
export function reviewValues(source,file=source){
 const d=file?.data||{},review=source?.data?.mes_transfer?.review||{};
 return {lot:d.lot||file?.title||'',part_no:d.part_no||d.part_revision||'',part_name:d.part_name||'',part_type:d.part_type||'',
  shop_order_no:d.shop_order_no||d.so_raw||'',heat_code:d.heat_code||'',qty:d.qty??null,input_date:d.input_date||'',
  current_state:d.delivery_date?'COMPLETED':'',note:d.note||'',...review};
}
export function reviewProblems(values){
 const p=[];if(!String(values.part_no||'').trim())p.push('품번 미기재');if(!String(values.part_name||'').trim())p.push('품명 미기재');
 if(!Number.isSafeInteger(Number(values.qty))||Number(values.qty)<=0)p.push('LOT 수량 확인');
 if(!['NOT_STARTED','IN_PROGRESS'].includes(values.current_state))p.push(values.current_state==='COMPLETED'?'완료·납품 자료':'현재 진행상태 확인');
 return p;
}
export function transferRows(stored,routes,bundle,resolved=new Map()){
 const linked=new Map();for(const route of routes)if(route.data?.source_routing_id&&activeRoute(route))linked.set(route.data.source_routing_id,route);
 const matches=sourceRows(bundle).length?compareSourceRows(bundle,stored).rows:stored.map(source=>({source,matches:[source]}));
 return matches.map(match=>{
  const key=match.source.code,selected=match.matches.find(r=>r.id===resolved.get(key));
  const proven=match.matches.filter(r=>linked.has(r.id));
  const source=selected||(proven.length===1?proven[0]:match.matches.length===1?match.matches[0]:null),values=reviewValues(source,match.source);
  const meta=source?.data?.mes_transfer||{},route=source?linked.get(source.id):null;
  const problems=reviewProblems(values);
  let status=!source?(match.matches.length?'AMBIGUOUS':'MISSING'):route?'CONVERTED':meta.status==='EXCLUDED'?'EXCLUDED':meta.status==='CONVERTED'?'RETURNED':problems.length?'PENDING':'READY';
  if(source&&!route&&!['EXCLUDED','RETURNED'].includes(status)&&routes.some(r=>activeRoute(r)&&[r.code,r.data?.lot,r.data?.source_lot].includes(values.lot))){problems.push('기존 운영 LOT 연결 확인');status='PENDING';}
  return {id:key,code:values.lot,title:values.part_name,data:values,source,matches:match.matches,route,status,problems,lastError:meta.last_error||'',file:match.source};
 });
}
export function sourceProcessSteps(bundle,type){
 const rows=bundle?.sources?.R?.process_templates?.[type];if(!Array.isArray(rows))return [];
 return rows.flatMap(row=>{
  if(!Array.isArray(row))return [];
  const code=String(row[2]||row[1]||'').replaceAll('*','').trim(),name=String(row[3]||'').trim();
  if(!/^[\w.-]{1,40}$/.test(code)||!name||/OPER NAME|공정명/.test(name))return [];
  const kind=/외주|코팅|Coating/i.test(name)?'OUTSOURCE':/검사|Inspection/i.test(name)?'INSPECTION':/포장|Package/i.test(name)?'PACK':'WORK';
  return [{code,name,kind,skl_op_no:String(row[0]||'').trim(),inspection_code:['M','I','V'].includes(row[6])?row[6]:'',
   equipment_label:String(row[4]||'').trim(),equipment_id:'',employee_id:'',employee_ids:[],independent:false,note:String(row[5]||'').trim()}];
 });
}
export function assertTransferGroup(rows){
 if(!rows.length||rows.length>500)throw Error('전환할 원문을 1~500건 선택하세요.');
 if(rows.some(row=>!row.source))throw Error('원문 미등록·동일 LOT 여러 건 자료를 먼저 확인하세요.');
 if(rows.some(row=>['CONVERTED','EXCLUDED','RETURNED'].includes(row.status)))throw Error('전환 완료·제외·삭제 이력 자료는 먼저 확인하거나 재검토로 돌리세요.');
 if(new Set(rows.map(row=>row.data.part_no)).size!==1||new Set(rows.map(row=>row.data.part_type)).size!==1)throw Error('품번과 TYPE이 같은 자료끼리 선택하세요.');
 if(!rows[0].data.part_no)throw Error('품번을 먼저 보완하세요.');
 return {part:rows[0].data.part_no,type:rows[0].data.part_type};
}
