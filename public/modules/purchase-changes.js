import {$,all,esc,num,clock,modal,notice,table,input,area,busy,message} from './ui.js';
import {qty} from './domain.js';
import {receiptQuantities} from './purchase-utils.js';

export async function receiptStatus(controller,r){
 const status=await controller.rpc('dnm_v495_po_status',{p_id:r.id});
 if(status.visible&&status.version!==r.version)throw Error('발주서 내용이 변경되었습니다. 다시 조회하세요.');
 const rows=receiptQuantities(r).map(line=>{
  const [received,rejected]=status.totals?.[line.index]||[0,0];
  return {...line,received,rejected,remaining:Math.max(0,line.ordered-received)};
 });
 return {...status,rows};
}
export function poHistory(r){
 const history=r.data.po_history||[];
 if(!history.length)return '';
 const entries=[...history].reverse().map(h=>{
  const lines=(h.lines||[]).map((l,i)=>esc(l.item)+' '+num(l.qty)+' '+esc(l.unit)+(h.remarks?.[i]?' · '+esc(h.remarks[i]):'')).join('<br>');
  return [esc(h.number)+' · '+num(h.edition)+'차',h.kind==='cancel'?'전체 취소':'수정 전',esc(h.supplier),lines,num(h.total)+'원',esc(h.reason),esc(h.by_name||'')+'<br>'+esc(clock(h.at))];
 });
 return '<details><summary>이전 발주서 및 변경 사유 ('+history.length+'건)</summary>'+table(['발주번호 / 차수','처리','구매처','당시 품목 / 수량','당시 발주금액','사유','처리자 / 시각'],entries)+'</details>';
}
export function remarkCell(r,line,editable){
 const note=r.data.po_line_notes?.[line.index]||'';
 if(!editable)return '<span class="po-remark-text">'+esc(note||'—')+'</span>';
 return '<div class="po-remark"><textarea rows="2" maxlength="500" data-line-remark="'+line.index+'" aria-label="'+esc(line.item)+' 입고 비고">'+esc(note)+'</textarea>'+
  '<button type="button" class="secondary" data-save-remark="'+line.index+'">비고 저장</button></div>';
}
export function bindRemarks(controller,r,root){
 let saving=false;
 const pending=new Map();
 root.addEventListener('click',async e=>{
  const button=e.target.closest('[data-save-remark]');
  if(!button||saving)return;
  const index=Number(button.dataset.saveRemark),field=root.querySelector('[data-line-remark="'+index+'"]');
  const note=field.value.trim();
  let attempt=pending.get(index);
  if(!attempt||attempt.note!==note)attempt={note,version:r.version,k:crypto.randomUUID()};
  pending.set(index,attempt);
  saving=true;button.disabled=true;field.readOnly=true;busy(true);
  try{
   const result=await controller.rpc('dnm_v495_change_po',{act:'note',p:{id:r.id,version:attempt.version,line:index,line_remark:note},k:attempt.k});
   r.version=result.version;r.data.po_line_notes={...r.data.po_line_notes,[index]:note};field.value=note;
   pending.delete(index);message('품목 비고를 저장했습니다.','success');
  }catch(err){if(!err.unknown)pending.delete(index);message(err.message);}
  finally{field.readOnly=false;button.disabled=false;saving=false;busy(false);}
 });
}
export function cancelOrder(controller,r){
 return modal('발주 취소 · '+r.data.po_no,notice('입고·반품·지급 이력이 없는 발주서를 취소합니다. 승인된 의뢰에서 새 번호로 재발주할 수 있습니다.')+
  area('reason','취소 사유','','required maxlength="500"'),(f,k)=>controller.saveRpc('dnm_v495_change_po',{act:'cancel',p:{id:r.id,version:r.version,reason:f.reason},k}),'발주 취소 확정');
}
export async function reviseOrder(controller,r){
 const status=await receiptStatus(controller,r);
 if(!status.visible)throw Error('담당 발주서를 선택하세요.');
 const rows=status.rows,limits=r.data.request_terms?.lines||r.data.lines;
 const form=modal('수정 발주서 · '+r.data.po_no,notice('변경 후 총 발주수량을 입력하세요. 이미 합격 입고한 수량부터 구매의뢰 승인 수량까지 입력할 수 있습니다.')+
  table(['품목 / 규격','현재 발주','누적 합격','변경 후 총 발주수량'],rows.map((l,i)=>[
   esc(l.item)+'<br>'+esc(l.specification),num(l.ordered),num(l.received),
   input('quantity_'+i,l.unit||'수량',l.ordered,'number','required min="'+l.received+'" max="'+Number(limits[i].qty)+'" step="1"')
  ]))+(status.has_receipts?'<button type="button" id="closeRemaining" class="secondary">전 품목 잔량 취소 수량 채우기</button>':'')+
  '<p id="amendedTotal" aria-live="polite"></p>'+area('reason','변경 사유','','required maxlength="500"'),
  (f,k)=>controller.saveRpc('dnm_v495_change_po',{act:'revise',p:{id:r.id,version:r.version,quantities:rows.map((_,i)=>qty(f['quantity_'+i],'발주수량')),reason:f.reason},k}),'수정 발주서 발행');
 const fields=all('[name^="quantity_"]',form);
 const preview=()=>{
  const sub=fields.reduce((sum,el,i)=>sum+Number(el.value)*Number(r.data.lines[i].unit_price),0);
  $('#amendedTotal',form).textContent='변경 후 발주금액 (부가세 포함) '+num(sub+Math.round(sub*Number(r.data.tax_rate||0)*100)/100)+'원';
 };
 for(const field of fields)field.oninput=preview;
 const close=$('#closeRemaining',form);
 if(close)close.onclick=()=>{fields.forEach((el,i)=>{el.value=rows[i].received;});preview();};
 preview();
}
