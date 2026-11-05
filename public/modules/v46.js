import {poHistory,receiptStatus,remarkCell,bindRemarks,cancelOrder,reviseOrder} from './purchase-changes.js';
import {V44Controller} from './v44.js';
import {$,all,esc,num,clock,pill,btn,input,area,select,table,notice,message,modal,exportCSV} from './ui.js';
import {STATUS,money,qty,required} from './domain.js';
import {permit} from './permissions.js';
import {seoulDate,catalogIndex,itemSuggestions,specSuggestions,matchingCatalog,receiptQuantities,isPayment,paymentRow,filterPayments,paymentSummary,purchaseFlowState,poLabel} from './purchase-utils.js';
import {printPurchaseDocument,sharePurchaseImage} from './purchase-doc.js';
const moneyText=x=>num(Number(x||0));
const yes=(f,k)=>Object.prototype.hasOwnProperty.call(f,k)?String(f[k]):'';
const options=rows=>[...new Set(rows.map(x=>x).filter(Boolean))].sort((a,b)=>a.localeCompare(b,'ko'));
const isRead=(ctx,mod)=>permit(ctx,mod,'read');

export class V46Controller extends V44Controller{
 constructor(...a){super(...a);this.paymentFilters={from:'',to:'',supplier:''};this.purchaseCatalog=[];}
 async purchases(){
  const rows=this.filter(await this.rec('purchase'));
  if(this.page!=='purchase')return;
  const status=r=>purchaseFlowState(r)+(r.data.buyer_review&&!r.data.buyer_review.at&&['SUBMITTED','APPROVED'].includes(r.state)?' · 담당자 확인 대기':'');
  this.set(`<div class="card purchase-workflow"><div class="sectionhead"><h2>구매업무 진행순서</h2><span class="tag">구매의뢰 → 승인 → 견적(선택) → 발주</span></div><div class="purchase-steps"><span>① 구매의뢰</span><span>② 결재승인</span><span>③ 견적의뢰 <small>선택</small></span><span>④ 발주서</span><span>⑤ 품목별 입고</span><span>⑥ 업체별 지급·집계</span></div>${notice('승인한 구매의뢰 1건에서 발주서 1건을 만듭니다. 견적의뢰는 필요할 때만 작성합니다.')}</div>
  <div class="card">${this.top(this.able('purchase')?btn('newPurchase','구매의뢰서 작성','','primary'):'')}
  ${table(['구매의뢰번호','공급업체','총액(VAT 포함)','등록일','진행단계','관리'],this.pagedCells(rows,r=>[esc(r.code),esc(r.data.supplier||r.title),moneyText(r.data.total),clock(r.created_at),`<span class="purchase-status">${esc(status(r))}</span>`,btn('purchaseDetail','상세·결재·문서',r.id)]))}<div id="v4pager" class="pagination"></div></div>`);
  this.pageFooter(rows);
 }
 async purchaseDetail(id){
  const r=await this.s.one(id);this.remember([r]);
  const approvals=r.data.approvals||[],current=approvals[r.data.current_step],me=current?.user_id===this.ctx.profile.id;
  const issued=!!r.data.po_no;
  const info=issued&&isRead(this.ctx,'receipts')?await receiptStatus(this,r):{visible:false,rows:receiptQuantities(r)};
  const readReceipts=info.visible,qtyRows=info.rows;
  const editable=readReceipts&&permit(this.ctx,'receipts','update');
  const changeable=issued&&editable&&['ORDERED','PARTIAL','RECEIVED'].includes(r.state);
  const legacyCandidate=this.ctx.profile.role==='admin'&&r.state==='SUBMITTED'&&!r.data.buyer_review&&r.data.current_step===0&&approvals.length>=2;
  const canConvert=legacyCandidate&&(await this.rpc('dnm_v492_buyer',{})).user_id===approvals[0].user_id;
  const documentButtons=[btn('printPurchaseRequest','구매의뢰서 PDF·인쇄',r.id),btn('sharePurchaseRequest','구매의뢰서 이미지 공유',r.id),r.data.quote_request?.quote_no?btn('printPurchaseQuote','견적의뢰서 PDF·인쇄',r.id)+btn('sharePurchaseQuote','견적의뢰서 이미지 공유',r.id):'',r.data.po_no?btn('printPurchaseOrder','발주서 PDF·인쇄',r.id)+btn('sharePurchaseOrder','발주서 이미지 공유',r.id):''].join('');
  modal('구매업무 · '+r.code,`<div class="purchase-overview"><div><small>공급업체</small><strong>${esc(r.data.supplier||r.title)}</strong></div><div><small>현재 단계</small><strong>${esc(purchaseFlowState(r))}</strong></div><div><small>의뢰 참고금액</small><strong>${moneyText(r.data.request_terms?.total??r.data.total)}원</strong></div></div>
   ${table(['품명','규격 / 사양','수량','단위','단가','금액'],(r.data.lines||[]).map(l=>[esc(l.item),esc(l.specification),moneyText(l.qty),esc(l.unit),moneyText(l.unit_price),moneyText(l.amount)]))}
   <h3>구매담당자 확인</h3>${r.data.buyer_review?notice(r.data.buyer_review.name+' · '+(r.data.buyer_review.at?'확인 완료 '+clock(r.data.buyer_review.at):'확인 대기')):notice('기존 결재선으로 상신된 문서입니다.')}
   ${r.data.buyer_review?.user_id===this.ctx.profile.id&&!r.data.buyer_review.at&&['SUBMITTED','APPROVED'].includes(r.state)?btn('buyerReview','내용 확인',r.id,'primary'):''}
   ${r.data.po_no?notice('발주금액 '+moneyText(r.data.total)+'원 · 입고 확정금액(VAT 포함) '+(r.data.received_total!=null?moneyText(r.data.received_total):['RECEIVED','MATCHED','PAID'].includes(r.state)?moneyText(r.data.total):'이전 입고내역 참고 ')+'원'):''}
   ${canConvert?btn('convertReview','기존 첫 결재를 담당자 확인란으로 전환',r.id):''}
   <h3>결재 진행</h3>${table(['순서','결재자','필수','상태','의견'],approvals.map((a,i)=>[i+1,esc(this.person(a.user_id)),a.required?'필수':'일반',pill(a.state),esc(a.opinion||a.reason||'')]))}
   <div class="purchase-actions">${r.state==='SUBMITTED'&&me&&this.able('approve')?btn('approve','승인',r.id,'primary')+btn('delegate','전결',r.id)+btn('reject','반려',r.id):''}
   ${r.state==='APPROVED'&&permit(this.ctx,'receipts','update')?btn('purchaseQuote','견적의뢰서 작성 (선택)',r.id)+(r.data.buyer_review&&!r.data.buyer_review.at?'구매담당자 확인 대기':btn('purchaseOrder',r.data.po_history?.length?'새 발주서 작성 (재발주)':'발주서 발행',r.id,'primary')):''}
   ${['ORDERED','PARTIAL'].includes(r.state)&&permit(this.ctx,'receipts','create')?btn('receive','품목별 입고',r.id,'primary'):''}
   ${changeable?btn('revisePO','수정 발주서 발행',r.id)+(info.has_receipts||info.has_settlement?'':btn('cancelPO','발주 취소',r.id)):''}
   ${r.state==='RECEIVED'&&permit(this.ctx,'settlement','create')?btn('settle','입고·증빙 대사 (선택)',r.id):''}</div>
   ${issued&&qtyRows.length?`<h3>품목별 입고현황</h3>${table(['품목','발주수량','누적 합격','불합격','잔량','비고'],qtyRows.map(x=>[esc(x.item)+'<small> '+esc(x.specification)+'</small>',moneyText(x.ordered),readReceipts?moneyText(x.received):'—',readReceipts?moneyText(x.rejected):'—',readReceipts?`<b>${moneyText(x.remaining)}</b>`:'—',remarkCell(r,x,editable)]))}`:''}
   ${poHistory(r)}
   <h3>문서 출력 및 공유</h3><div class="purchase-actions">${documentButtons}</div>${notice('PDF: 출력 창에서 ‘PDF로 저장’을 선택하세요. 이미지 공유는 기기에서 지원하면 공유창이 열리고, 미지원 시 PNG가 저장됩니다.')}`);
  if(issued&&editable)bindRemarks(this,r,$('#v4form'));
  $('#v4form').onclick=e=>{const b=e.target.closest('[data-vaction]');if(!b||$('#v4dialog').dataset.busy==='true')return;const act=b.dataset.vaction,target=b.dataset.id;b.disabled=true;this.action(act,target).catch(x=>message(x.message)).finally(()=>{if(b.isConnected)b.disabled=false;});};
 }
 async loadCatalog(){
  const data=(await this.api.request('/rest/v1/rpc/dnm_v49_purchase_catalog',{method:'POST',body:{}})).data;
  if(!data?.ok||!Array.isArray(data.rows))throw Error('구매 품목 목록을 확인하지 못했습니다.');
  this.purchaseCatalog=catalogIndex(data.rows,[],true);return this.purchaseCatalog;
 }
 async purchaseForm(seed=null){
  this.ctx=await this.s.context();
  const buyer=await this.rpc('dnm_v492_buyer',{});
  const people=(this.ctx.people||[]).filter(x=>x.approver&&x.id!==this.ctx.profile.id&&x.id!==buyer.user_id);
  let cat=[];let lookupError='';try{cat=await this.loadCatalog();}catch(e){lookupError=e.message;}
  let lines=[{item:seed?.title||'',specification:seed?.data?.specification||'',qty:1,unit:seed?.data?.unit||'',unit_price:seed?.data?.unit_price??''}],approvals=[{user_id:'',required:false}];
  const supplier=seed?.data?.supplier||'';
  const draft=modal('구매의뢰서 작성',`<p class="muted">품명 일부를 입력하면 기존 사용품목을 추천합니다. 신규 품목·규격은 그대로 입력할 수 있습니다. 미사용·검토대기 자재는 참고 표시되며, 선택해도 기준정보 상태는 바뀌지 않습니다.</p>
  <div class="fields">${input('supplier','참고 구매처 (선택)',supplier,'text','maxlength="200"')}${input('due_date','입고 희망일','','date')}</div>
  ${lookupError?notice('품목 검색을 불러오지 못했습니다. 직접 입력은 가능합니다. '+lookupError,'warning'):''}<h3>구매 품목</h3><div id="purchaseLines"></div><button type="button" id="addPurchaseLine" class="secondary">+ 품목 추가</button>
  ${select('tax_rate','부가세',[['0.1','과세 10%'],['0','면세/영세 0%']],'0.1')}
  ${notice(buyer.active?'구매담당자 확인 · '+buyer.name+' (자동 지정)':'상신하려면 관리자가 사용자별 권한 · 전결에서 구매담당자를 지정해야 합니다.')}<h3>순차 결재선</h3>${!people.length?notice('선택 가능한 결재자가 없습니다. 관리자에게 구매 결재자 지정을 요청하세요. 본인은 결재자로 선택할 수 없습니다.','warning'):''}<div id="approvalLines"></div><button type="button" id="addApprover" class="secondary">+ 결재자 추가</button>
  ${area('note','구매 목적 / 특기사항')}${notice('결재승인 후 견적의뢰서를 작성하거나 바로 발주서를 발행할 수 있습니다.')}`,
  async(f,k)=>{read();for(const l of lines){l.item=required(l.item,'품명',200);l.specification=String(l.specification||'').trim().slice(0,200);l.unit=required(l.unit,'단위',20);l.qty=qty(l.qty,'수량',false);l.unit_price=money(l.unit_price||0);}if(approvals.some(a=>!a.user_id))throw Error('결재자를 선택하세요.');if(new Set(approvals.map(a=>a.user_id)).size!==approvals.length)throw Error('결재자 중복입니다.');await this.command('purchase_submit',{data:{...f,lines,tax_rate:Number(f.tax_rate),approvals}},k);},'결재 상신');
  const root=draft.querySelector('.modalbody');
  const read=()=>{lines=all('.purchase-line',root).map(el=>Object.fromEntries(all('[data-field]',el).map(x=>[x.dataset.field,x.value])));approvals=all('.a-line',root).map(el=>({user_id:el.querySelector('select').value,required:el.querySelector('input[type=checkbox]').checked}));};
  const fillOptions=(i,itemVal,specVal,field='item')=>{
   const el=$(`#purchaseLine-${i}`,root);if(!el)return;
   const panel=el.querySelector('[data-suggestions]');
   const names=field==='item'?itemSuggestions(cat,itemVal,40):specSuggestions(cat,itemVal,200).filter(s=>s.toLocaleLowerCase('ko').includes(String(specVal||'').trim().toLocaleLowerCase('ko')));
   panel.hidden=false;
   panel.innerHTML=names.length?`<span class="muted">${field==='item'?'품목':'규격'} 검색 결과 · 선택하거나 직접 입력</span>`+names.map((name,n)=>{
    const matches=cat.filter(x=>field==='item'?x.item===name:x.item.toLocaleLowerCase('ko')===itemVal.trim().toLocaleLowerCase('ko')&&x.specification===name);
    const ref=matches.length&&matches.every(x=>x.reference);
    return `<button type="button" data-suggestion-index="${n}">${esc(name)}${ref?' <small>미사용·검토대기 참고</small>':''}</button>`;
   }).join(''):'<span class="muted">일치하는 목록이 없습니다. 입력한 내용을 그대로 사용할 수 있습니다.</span>';
   panel.querySelectorAll('[data-suggestion-index]').forEach(b=>b.onclick=()=>{
    const input=el.querySelector(`[data-field="${field==='item'?'item':'specification'}"]`);
    input.value=names[Number(b.dataset.suggestionIndex)];input.dispatchEvent(new Event('change',{bubbles:true}));
    if(field==='item'){const spec=el.querySelector('[data-field="specification"]');spec.focus();fillOptions(i,input.value,spec.value,'specification');}
    else panel.hidden=true;
   });
  };
  const render=()=>{
   $('#purchaseLines',root).innerHTML=lines.map((l,i)=>`<div class="purchase-line" id="purchaseLine-${i}">
    <div class="purchase-line-no">${i+1}</div>
    <label class="purchase-item-name">품명 · 검색 또는 신규 입력<input data-field="item" value="${esc(l.item)}" required maxlength="200" autocomplete="off" placeholder="품명 일부 입력"></label>
    <label>규격 / 사양<input data-field="specification" value="${esc(l.specification)}" maxlength="200" autocomplete="off" placeholder="선택 또는 입력"></label>
    <label>수량<input data-field="qty" type="number" min="1" step="1" value="${esc(l.qty)}" required></label>
    <label>단위<input data-field="unit" value="${esc(l.unit)}" required maxlength="20"></label>
    <label>예상 단가<input data-field="unit_price" type="number" min="0" step="0.01" value="${esc(l.unit_price)}" placeholder="미정이면 공란"></label>
    <button type="button" class="quiet" data-remove-purchase="${i}" title="행 삭제" aria-label="${i+1}행 삭제">×</button><div data-suggestions class="purchase-suggestions" hidden></div></div>`).join('');
   $('#approvalLines',root).innerHTML=approvals.map((a,i)=>`<div class="a-line"><span class="stepnum">${i+1}</span><select required aria-label="${i+1}번째 결재자"><option value="">결재자 선택</option>${people.map(p=>`<option value="${esc(p.id)}" ${p.id===a.user_id?'selected':''}>${esc(p.name)}</option>`).join('')}</select><label class="check"><input type="checkbox" ${a.required?'checked':''}>필수 결재</label><button type="button" class="quiet" data-remove-approver="${i}" aria-label="결재자 삭제">×</button></div>`).join('');

   all('.purchase-line',root).forEach((el,i)=>{
    const item=el.querySelector('[data-field="item"]'),spec=el.querySelector('[data-field="specification"]');
    let lastItem=item.value;
    item.addEventListener('input',()=>{if(item.value!==lastItem){spec.value='';el.querySelector('[data-field="unit"]').value='';el.querySelector('[data-field="unit_price"]').value='';}fillOptions(i,item.value,spec.value);});
    item.addEventListener('focus',()=>{if(item.value)fillOptions(i,item.value,spec.value);});
    spec.addEventListener('focus',()=>fillOptions(i,item.value,spec.value,'specification'));
    for(const input of [item,spec])input.addEventListener('keydown',e=>{if(e.key==='Escape')el.querySelector('[data-suggestions]').hidden=true;});
    item.addEventListener('change',()=>{
     if(item.value!==lastItem){spec.value='';el.querySelector('[data-field="unit"]').value='';el.querySelector('[data-field="unit_price"]').value='';lastItem=item.value;}
     const suggestions=specSuggestions(cat,item.value);if(suggestions.length===1&&!spec.value)spec.value=suggestions[0];
     const found=matchingCatalog(cat,item.value,spec.value);if(found&&!found.reference){if(!el.querySelector('[data-field="unit"]').value)el.querySelector('[data-field="unit"]').value=found.unit||'';
      if(!el.querySelector('[data-field="unit_price"]').value&&found.unit_price!==null)el.querySelector('[data-field="unit_price"]').value=String(found.unit_price);}
     fillOptions(i,item.value,spec.value);
    });
    spec.addEventListener('input',()=>{el.querySelector('[data-field="unit_price"]').value='';fillOptions(i,item.value,spec.value,'specification');});
    spec.addEventListener('change',()=>{const found=matchingCatalog(cat,item.value,spec.value);if(found&&!found.reference){const unit=el.querySelector('[data-field="unit"]');if(!unit.value)unit.value=found.unit||'';const price=el.querySelector('[data-field="unit_price"]');if(!price.value&&found.unit_price!==null)price.value=String(found.unit_price);}});
   });
   all('[data-remove-purchase]',root).forEach(b=>b.onclick=()=>{read();if(lines.length>1)lines.splice(+b.dataset.removePurchase,1);render();});
   all('[data-remove-approver]',root).forEach(b=>b.onclick=()=>{read();if(approvals.length>1)approvals.splice(+b.dataset.removeApprover,1);render();});
  };
  $('#addPurchaseLine',root).onclick=()=>{read();if(lines.length<50)lines.push({item:'',specification:'',qty:1,unit:'',unit_price:''});render();};
  $('#addApprover',root).onclick=()=>{read();if(approvals.length<10)approvals.push({user_id:'',required:false});render();};
  render();
 }
 async purchaseQuote(r){
  if(r.state!=='APPROVED')throw Error('승인된 구매의뢰만 견적의뢰할 수 있습니다.');
  const q=r.data.quote_request||{},today=seoulDate();
  modal('견적의뢰서 작성 · '+r.code,`<p>${esc(r.data.supplier)} · 구매의뢰 ${esc(r.code)}</p>${notice('견적의뢰서는 선택사항입니다. 작성하지 않고 바로 발주할 수 있습니다.')}
   <div class="fields">${input('issued_date','견적 의뢰일',q.issued_date||today,'date','required')}${input('response_due','견적 회신 희망일',q.response_due||'','date')}</div>${area('note','특기사항 / 견적 문의',q.note||'')}`,
   (f,k)=>this.command('purchase_quote',{id:r.id,version:r.version,...f},k),'견적의뢰서 저장');
 }
 async purchaseOrder(r){
  if(r.state!=='APPROVED')throw Error('결재승인된 구매의뢰만 발주할 수 있습니다.');
  const dt=seoulDate(),reissue=!!r.data.po_history?.length;
  const number='PO-'+r.code.replace(/^PR-/,'')+(reissue?'-R'+(Number(r.data.po_edition||1)+1):'');
  modal((reissue?'재발주서 작성 · ':'발주서 발행 · ')+r.code,`<p><b>공급업체: ${esc(r.data.supplier)}</b> · 의뢰 참고금액 ${moneyText(r.data.total)}원</p>${notice('구매의뢰 1건당 발주서 1건만 확정됩니다. 발주할 실제 구매처와 품목별 단가를 입력하세요. 입고 때 실제 단가를 확정합니다.')}
  ${input('order_supplier','실제 발주 구매처',r.data.supplier==='미정'?'':r.data.supplier,'text','required maxlength="200"')}
  ${reissue?notice('취소한 발주서를 대신할 새 번호와 수량을 입력하세요. 공급받지 않을 품목은 수량 0으로 둘 수 있습니다.'):''}
  ${(r.data.lines||[]).map((l,i)=>(reissue?input('quantity_'+i,(i+1)+'. '+l.item+' · 재발주 수량',l.qty,'number','required min="0" max="'+Number(l.qty)+'" step="1"'):'')+input('price_'+i,(i+1)+'. '+l.item+' '+(l.specification||'')+' · 발주 단가',l.unit_price??'','number','required min="0" max="10000000000" step="0.01"')).join('')}
  <div class="fields">${input('po_no','발주번호',number,'text','required maxlength="100"')}${input('po_date','발주일',dt,'date','required')}${input('po_delivery_date','납기 요청일',r.data.due_date||'','date')}</div>${area('po_note','특기사항 / 발주조건',r.data.note||'')}`,
  (f,k)=>{const p={id:r.id,version:r.version,po_no:f.po_no,po_date:f.po_date,po_delivery_date:f.po_delivery_date,po_note:f.po_note,order_supplier:f.order_supplier,prices:r.data.lines.map((_,i)=>money(f['price_'+i]))};
   if(reissue)return this.saveRpc('dnm_v495_issue',{p:{...p,quantities:r.data.lines.map((_,i)=>qty(f['quantity_'+i],'재발주 수량'))},k});
   return this.command('purchase_order',p,k);},reissue?'새 번호로 재발주':'발주 확정');
 }
 async receipts(){
  const [prs,receipts]=await Promise.all([this.rec('purchase'),this.rec('receipt')]);
  const orders=this.filter(prs.filter(x=>['ORDERED','PARTIAL','RECEIVED','MATCHED','PAID'].includes(x.state)||(x.state==='APPROVED'&&x.data.po_history?.length)));
  if(this.page!=='receipts')return;
  this.set(`<div class="card">${this.top()}<h2>발주서별 · 품목별 입고</h2>${notice('발주서 1건 안에서 품목별로 나누어 입고할 수 있습니다. 누적 입고량과 잔량을 함께 확인하세요.')}
   ${table(['발주번호 / 의뢰번호','공급업체','품목수 / 입고진척','상태','관리'],this.pagedCells(orders,r=>{
     const q=receiptQuantities(r,receipts);const done=q.filter(x=>x.remaining===0).length;
     return [esc(poLabel(r.data)||'재발주 대기')+'<small> / '+esc(r.code)+'</small>',esc(r.data.supplier||r.title),r.data.po_no?(this.ctx.profile.role!=='admin'&&this.ctx.permissions?.receipts?.scope==='own'?'상세에서 확인':`${done} / ${q.length} 품목 완료`):'—',r.data.po_no?pill(r.state):'취소 · 재발주 대기',btn('purchaseDetail','발주·입고 상세',r.id)+(['ORDERED','PARTIAL'].includes(r.state)&&permit(this.ctx,'receipts','create')?btn('receive','품목별 입고',r.id,'primary'):'')];}))}<div id="v4pager" class="pagination"></div></div>
   <div class="card"><h2>최근 입고 / 반품 기록</h2>${table(['입고일','발주처 / 품목','품목순번','합격 / 불합격','입고단가','공급가액','상태 / 관리'],receipts.slice(0,100).map(r=>[esc(String(r.data.received_at||r.created_at).slice(0,10)),esc(r.data.supplier||'')+' / '+esc(r.title),Number(r.data.line)+1,`${moneyText(r.data.accepted)} / ${moneyText(r.data.rejected)}`,moneyText(r.data.unit_price??prs.find(p=>p.id===r.parent_id)?.data.lines?.[Number(r.data.line)]?.unit_price),moneyText(Number(r.data.accepted)*(r.data.unit_price??prs.find(p=>p.id===r.parent_id)?.data.lines?.[Number(r.data.line)]?.unit_price??0)),r.state==='CONFIRMED'&&Number(r.data.accepted)>0&&permit(this.ctx,'receipts','create')?btn('returnReceipt','반품',r.id):pill(r.state)]))}</div>`);
  this.pageFooter(orders);
 }
 async receiveForm(r){
  const status=await receiptStatus(this,r);if(!status.visible)throw Error('담당 발주서를 선택하세요.');const lines=status.rows;const live=lines.filter(x=>x.remaining>0);
  if(!live.length)throw Error('발주 품목이 모두 입고되었습니다.');
  const opts=live.map(x=>[String(x.index),`${x.index+1}. ${x.item} / ${x.specification||'규격 없음'} · 잔량 ${moneyText(x.remaining)} ${x.unit}`]);
  const d=modal('발주별 품목 입고 · '+r.data.po_no,`${notice('입고한 실제 품목과 수량을 등록합니다. 한 발주서의 여러 품목을 날짜별로 나누어 입력할 수 있습니다.')}
  ${select('line','입고 품목',opts)}<div id="receiptRemain"></div>${input('unit_price','이번 입고 확정단가','','number','required min="0" max="10000000000" step="0.01"')}<div class="fields">${input('accepted','합격 입고수량',0,'number','required min="0" step="1"')}${input('rejected','불합격 수량',0,'number','required min="0" step="1"')}</div>${area('line_remark','품목별 입고현황 비고','','maxlength="500" placeholder="예: 100개 재고 부족, 추가 납기 확인 중"')}${area('note','이번 입고검사 결과 / 증빙 메모')}`,
  (f,k)=>{const accepted=qty(f.accepted,'합격입고수량'),rejected=qty(f.rejected,'불합격수량');const selected=lines.find(x=>x.index===Number(f.line));if(accepted+rejected===0)throw Error('입고수량을 입력하세요.');if(accepted>selected.remaining)throw Error('합격 입고수량이 잔량을 초과했습니다.');const p={id:r.id,version:r.version,line:Number(f.line),accepted,rejected,unit_price:money(f.unit_price),note:f.note};if(f.line_remark!==(r.data.po_line_notes?.[p.line]||''))return this.saveRpc('dnm_v495_receive',{p:{...p,line_remark:f.line_remark},k});return this.command('purchase_receive',p,k);},'입고 등록');
  const line=d.querySelector('[name="line"]'),help=d.querySelector('#receiptRemain');
  const memo=d.querySelector('[name="line_remark"]'),drafts={...r.data.po_line_notes};memo.oninput=()=>{drafts[line.value]=memo.value;};
  const refresh=()=>{const l=lines.find(x=>x.index===Number(line.value));memo.value=drafts[l.index]||'';d.querySelector('[name="unit_price"]').value=r.data.lines[l.index].unit_price;help.innerHTML=`<p class="notice info">발주 ${moneyText(l.ordered)} / 누적 합격 ${moneyText(l.received)} / 현재 잔량 <b>${moneyText(l.remaining)} ${esc(l.unit)}</b></p>`;};line.onchange=refresh;refresh();
 }
 async settlements(){
  const [rows,prs,partners]=await Promise.all([this.rec('settlement'),this.rec('purchase'),this.api.rows('partners','select=name,category,active&limit=1000').then(r=>r.data||[]).catch(()=>[])]);
  if(this.page!=='settlement')return;
  this.settlementRows=rows;this.purchaseRows=prs;this.purchasePartners=partners;
  const paymentRows=rows.filter(isPayment).map(paymentRow);
  const suppliers=options([...paymentRows.map(x=>x.supplier),...prs.map(x=>x.data?.supplier||x.title),...partners.filter(x=>x.active!==false&&['supplier','both'].includes(x.category)).map(x=>x.name)]);
  const filter=this.paymentFilters,shown=filterPayments(paymentRows,filter),sum=paymentSummary(shown),total=shown.reduce((n,x)=>n+x.amount,0);
  this.paymentShown=shown;
  this.set(`<div class="card"><div class="sectionhead"><div><span class="eyebrow">SUPPLIER PAYMENT LEDGER</span><h2>업체별 정산 · 기간별 집계</h2></div>${permit(this.ctx,'settlement','create')?btn('addPayment','지급금액 등록','','primary'):''}</div>
  ${notice('업체별 실제 지급한 금액·날짜를 기록합니다. 은행 송금은 실행하지 않으며, 구매 증빙대사와 구분합니다.')}
  <form id="paymentFilters" class="payment-filters"><label>기간 시작<input type="date" name="from" value="${esc(filter.from)}"></label><label>기간 종료<input type="date" name="to" value="${esc(filter.to)}"></label>${select('supplier','업체',[['','전체 거래처'],...suppliers.map(x=>[x,x])],filter.supplier)}<button type="submit" class="secondary">조회</button><button id="paymentAll" type="button" class="quiet">전체</button><button id="paymentCSV" type="button" class="secondary">CSV</button></form>
  <div class="kpis payment-kpis"><article><span>조회 기간 지급합계</span><strong>${moneyText(total)}원</strong></article><article><span>입력된 지급내역</span><strong>${shown.length}건</strong></article><article><span>거래업체</span><strong>${sum.length}곳</strong></article></div>
  <h3>발주별 입고·지급 잔액 (누계)</h3>${table(['구매처','발주번호','발주금액','입고 확정액(VAT 포함)','연결 지급액','미지급 / 초과 지급(−)'],prs.filter(p=>p.data.po_no&&(!filter.supplier||p.data.supplier===filter.supplier)).map(p=>{const received=p.data.received_total??(['RECEIVED','MATCHED','PAID'].includes(p.state)?p.data.total:null),used=paymentRows.filter(x=>x.po_id===p.id).reduce((n,x)=>n+x.amount,0);return [esc(p.data.supplier),esc(p.data.po_no),moneyText(p.data.total),received==null?'이전 부분입고':moneyText(received),moneyText(used),received==null?'—':moneyText(received-used)];}))}<h3>거래처별 지급합계</h3>${table(['거래처','지급건수','지급합계'],sum.map(x=>[esc(x.supplier),`${x.count}건`,`<b>${moneyText(x.amount)}원</b>`]))}
  <h3>지급내역</h3>${table(['지급일','업체','지급액','증빙/참조','발주 연결','관리'],this.pagedCells(shown,r=>[esc(r.date),esc(r.supplier),`<b>${moneyText(r.amount)}원</b>`,esc(r.reference||'—'),esc(prs.find(p=>p.id===r.po_id)?.data?.po_no||'—'),r.legacy?'<small>이전 지급기록</small>':permit(this.ctx,'settlement','update')?btn('editPayment','수정',r.id):'조회']))}<div id="v4pager" class="pagination"></div></div>`);
  this.pageFooter(shown);
  $('#paymentFilters').onsubmit=e=>{e.preventDefault();const f=Object.fromEntries(new FormData(e.target));if(f.from&&f.to&&f.from>f.to){message('기간 시작일이 종료일보다 늦습니다.');return;}this.paymentFilters={from:f.from||'',to:f.to||'',supplier:f.supplier||''};this.pageNo=1;this.settlements().catch(x=>message(x.message));};
  $('#paymentAll').onclick=()=>{this.paymentFilters={from:'',to:'',supplier:''};this.pageNo=1;this.settlements().catch(x=>message(x.message));};
  $('#paymentCSV').onclick=()=>{exportCSV(`DNM_업체별정산_${this.paymentFilters.from||'전체'}_${this.paymentFilters.to||'전체'}.csv`,[['지급일','공급업체','지급금액','참조번호','비고','발주번호'],...this.paymentShown.map(p=>[p.date,p.supplier,p.amount,p.reference,p.note,prs.find(r=>r.id===p.po_id)?.data?.po_no||''])]);};
 }
 paymentForm(existing=null){
  const legacy=existing?.kind==='settlement'&&existing.data?.entry_type!=='payment';if(legacy)throw Error('이전 방식의 지급기록은 직접 수정할 수 없습니다.');
  const paid=existing?paymentRow(existing):null;
  const prs=(this.purchaseRows||[]).filter(x=>['ORDERED','PARTIAL','RECEIVED','MATCHED'].includes(x.state));
  const supplierList=options([...prs.map(p=>p.data.supplier),...(this.purchasePartners||[]).filter(p=>p.active!==false&&['supplier','both'].includes(p.category)).map(p=>p.name),...(this.settlementRows||[]).filter(isPayment).map(p=>paymentRow(p).supplier)]);
  const d=modal(existing?'지급내역 수정':'업체별 지급금액 등록',`<p class="muted">지급한 금액을 직접 입력합니다. 지급일은 오늘 날짜로 채워지며 수정할 수 있습니다.</p>
   <label>거래처명<input name="supplier" list="paymentSupplier" value="${esc(paid?.supplier||'')}" required maxlength="200" placeholder="업체 선택 또는 입력"><datalist id="paymentSupplier">${supplierList.map(s=>`<option value="${esc(s)}"></option>`).join('')}</datalist></label>
   <div class="fields">${input('amount','지급금액(원)',paid?.amount??'','number','required min="0.01" step="0.01"')}${input('payment_date','지급일',paid?.date||seoulDate(),'date','required')}</div>
   ${select('purchase_id','연결할 발주서 (선택)',[['','업체별 지급 · 발주 미지정'],...prs.map(p=>[p.id,`${p.data.po_no} · ${p.data.supplier} · ${moneyText(p.data.total)}원`])],paid?.po_id||'')}
   ${input('reference','증빙/참조번호',paid?.reference||'','text','maxlength="200"')}${area('note','지급 관련 메모',paid?.note||'')}
   ${existing?area('reason','수정 사유','','required minlength="2" maxlength="500"'):''}
   ${notice('이 화면의 지급 등록은 은행이체가 아닙니다. 실제 지급한 거래만 입력하십시오.')}`,
   (f,k)=>{const amount=money(f.amount);if(amount<=0)throw Error('지급금액은 0원보다 커야 합니다.');if(f.purchase_id){const p=prs.find(x=>x.id===f.purchase_id);if(!p||p.data.supplier.trim()!==f.supplier.trim())throw Error('거래처와 발주서 업체명이 다릅니다.');}
    return this.command(existing?'purchase_payment_edit':'purchase_payment_add',{...(existing?{id:existing.id,version:existing.version}:{}),...f,amount},k);},existing?'수정 저장':'지급 기록');
  const po=d.querySelector('[name="purchase_id"]'),supplier=d.querySelector('[name="supplier"]');
  po.onchange=()=>{const r=prs.find(x=>x.id===po.value);if(r){supplier.value=r.data.supplier;}};
 }
 async action(action,id){
  if(action==='goEquipmentActivation'){if(this.ctx.profile.role!=='admin')throw Error('관리자만 사용상태를 일괄 변경할 수 있습니다.');this.reviewKind='equipment';return this.go('sourceReview');}
  if(action==='convertReview'){
   const r=await this.s.one(id);
   return modal('기존 첫 결재 전환',notice(r.code+' · 첫 결재자를 구매담당 확인란으로 옮기고 후속 결재자를 첫 순번으로 변경합니다.'),async()=>{await this.rpc('dnm_v492_convert_review',{p_id:id,p_version:r.version});await this.load(this.page);},'확인 후 전환');
  }
  if(action==='buyerReview'){
   const r=await this.s.one(id);
   return modal('구매의뢰 내용 확인',notice(r.code+' · 내용을 확인한 담당자와 시각이 기록됩니다.'),async()=>{await this.rpc('dnm_v492_review',{p_id:id,p_version:r.version});await this.load(this.page);},'확인 기록');
  }
  if(action==='revisePO')return reviseOrder(this,await this.s.one(id));
  if(action==='cancelPO')return cancelOrder(this,await this.s.one(id));
  if(action==='purchaseQuote')return this.purchaseQuote(await this.s.one(id));
  if(action==='purchaseOrder')return this.purchaseOrder(await this.s.one(id));
  if(action==='addPayment')return this.paymentForm();
  if(action==='editPayment')return this.paymentForm(await this.s.one(id));
  const doc={printPurchaseRequest:['request','print'],printPurchaseQuote:['quote','print'],printPurchaseOrder:['order','print'],sharePurchaseRequest:['request','share'],sharePurchaseQuote:['quote','share'],sharePurchaseOrder:['order','share']}[action];
  if(doc){const r=await this.s.one(id);if(doc[1]==='print')return printPurchaseDocument(r,doc[0]);const result=await sharePurchaseImage(r,doc[0]);if(result==='다운로드')message('이미지 파일이 다운로드 폴더에 저장되었습니다. 이메일·메신저에서 공유하세요.','success');return;}
  return super.action(action,id);
 }
}
