import {V44Controller} from './v44.js';
import {$,all,esc,num,clock,pill,btn,input,area,select,table,notice,message,modal,exportCSV} from './ui.js';
import {STATUS,money,qty,required} from './domain.js';
import {permit} from './permissions.js';
import {seoulDate,catalogIndex,itemSuggestions,specSuggestions,matchingCatalog,receiptQuantities,isPayment,paymentRow,filterPayments,paymentSummary,purchaseFlowState} from './purchase-utils.js';
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
  const status=r=>purchaseFlowState(r);
  this.set(`<div class="card purchase-workflow"><div class="sectionhead"><h2>구매업무 진행순서</h2><span class="tag">구매의뢰 → 승인 → 견적(선택) → 발주</span></div><div class="purchase-steps"><span>① 구매의뢰</span><span>② 결재승인</span><span>③ 견적의뢰 <small>선택</small></span><span>④ 발주서</span><span>⑤ 품목별 입고</span><span>⑥ 업체별 지급·집계</span></div>${notice('승인한 구매의뢰 1건에서 발주서 1건을 만듭니다. 견적의뢰는 필요할 때만 작성합니다.')}</div>
  <div class="card">${this.top(this.able('purchase')?btn('newPurchase','구매의뢰서 작성','','primary'):'')}
  ${table(['구매의뢰번호','공급업체','총액(VAT 포함)','등록일','진행단계','관리'],this.pagedCells(rows,r=>[esc(r.code),esc(r.data.supplier||r.title),moneyText(r.data.total),clock(r.created_at),`<span class="purchase-status">${esc(status(r))}</span>`,btn('purchaseDetail','상세·결재·문서',r.id)]))}<div id="v4pager" class="pagination"></div></div>`);
  this.pageFooter(rows);
 }
 async purchaseDetail(id){
  const r=await this.s.one(id);this.remember([r]);
  const approvals=r.data.approvals||[],current=approvals[r.data.current_step],me=current?.user_id===this.ctx.profile.id;
  const receiptRows=isRead(this.ctx,'receipts')?await this.rec('receipt',{parent:id}).catch(()=>[]):[];
  const qtyRows=receiptQuantities(r,receiptRows);
  const documentButtons=[btn('printPurchaseRequest','구매의뢰서 PDF·인쇄',r.id),btn('sharePurchaseRequest','구매의뢰서 이미지 공유',r.id),r.data.quote_request?.quote_no?btn('printPurchaseQuote','견적의뢰서 PDF·인쇄',r.id)+btn('sharePurchaseQuote','견적의뢰서 이미지 공유',r.id):'',r.data.po_no?btn('printPurchaseOrder','발주서 PDF·인쇄',r.id)+btn('sharePurchaseOrder','발주서 이미지 공유',r.id):''].join('');
  modal('구매업무 · '+r.code,`<div class="purchase-overview"><div><small>공급업체</small><strong>${esc(r.data.supplier||r.title)}</strong></div><div><small>현재 단계</small><strong>${esc(purchaseFlowState(r))}</strong></div><div><small>총 승인금액</small><strong>${moneyText(r.data.total)}원</strong></div></div>
   ${table(['품명','규격 / 사양','수량','단위','단가','금액'],(r.data.lines||[]).map(l=>[esc(l.item),esc(l.specification),moneyText(l.qty),esc(l.unit),moneyText(l.unit_price),moneyText(l.amount)]))}
   <h3>결재 진행</h3>${table(['순서','결재자','필수','상태','의견'],approvals.map((a,i)=>[i+1,esc(this.person(a.user_id)),a.required?'필수':'일반',pill(a.state),esc(a.opinion||a.reason||'')]))}
   <div class="purchase-actions">${r.state==='SUBMITTED'&&me&&this.able('approve')?btn('approve','승인',r.id,'primary')+btn('delegate','전결',r.id)+btn('reject','반려',r.id):''}
   ${r.state==='APPROVED'&&this.able('purchase')&&permit(this.ctx,'receipts','update')?btn('purchaseQuote','견적의뢰서 작성 (선택)',r.id)+btn('purchaseOrder','발주서 발행',r.id,'primary'):''}
   ${['ORDERED','PARTIAL'].includes(r.state)&&permit(this.ctx,'receipts','create')?btn('receive','품목별 입고',r.id,'primary'):''}
   ${r.state==='RECEIVED'&&permit(this.ctx,'settlement','create')?btn('settle','입고·증빙 대사 (선택)',r.id):''}</div>
   ${qtyRows.length?`<h3>품목별 입고현황</h3>${table(['품목','발주수량','누적 합격','불합격','잔량'],qtyRows.map(x=>[esc(x.item)+'<small> '+esc(x.specification)+'</small>',moneyText(x.ordered),moneyText(x.received),moneyText(x.rejected),`<b>${moneyText(x.remaining)}</b>`]))}`:''}
   <h3>문서 출력 및 공유</h3><div class="purchase-actions">${documentButtons}</div>${notice('PDF: 출력 창에서 ‘PDF로 저장’을 선택하세요. 이미지 공유는 기기에서 지원하면 공유창이 열리고, 미지원 시 PNG가 저장됩니다.')}`);
  $('#v4form').onclick=e=>{const b=e.target.closest('[data-vaction]');if(!b)return;const act=b.dataset.vaction,target=b.dataset.id;b.disabled=true;this.action(act,target).catch(x=>message(x.message)).finally(()=>{if(b.isConnected)b.disabled=false;});};
 }
 async loadCatalog(){
  if(!this.purchaseCatalog.length){
   const [m,c]=await Promise.all(['material_master','catalog'].map(k=>this.rec(k).catch(()=>[])));
   this.purchaseCatalog=catalogIndex(m,c);
  }
  return this.purchaseCatalog;
 }
 async purchaseForm(seed=null){
  const people=(this.ctx.people||[]).filter(x=>x.approver&&x.id!==this.ctx.profile.id);
  const cat=await this.loadCatalog();
  let lines=[{item:seed?.title||'',specification:seed?.data?.specification||'',qty:1,unit:seed?.data?.unit||'',unit_price:seed?.data?.unit_price??''}],approvals=[{user_id:'',required:false}];
  const supplier=seed?.data?.supplier||'';
  const draft=modal('구매의뢰서 작성',`<p class="muted">품명 일부를 입력하면 기존 사용품목을 추천합니다. 신규 품목·규격은 그대로 입력할 수 있습니다.</p>
  <div class="fields">${input('supplier','공급업체명',supplier,'text','required maxlength="200"')}${input('due_date','입고 희망일','','date')}</div>
  <h3>구매 품목</h3><div id="purchaseLines"></div><button type="button" id="addPurchaseLine" class="secondary">+ 품목 추가</button>
  ${select('tax_rate','부가세',[['0.1','과세 10%'],['0','면세/영세 0%']],'0.1')}
  <h3>순차 결재선</h3><div id="approvalLines"></div><button type="button" id="addApprover" class="secondary">+ 결재자 추가</button>
  ${area('note','구매 목적 / 특기사항')}${notice('결재승인 후 견적의뢰서를 작성하거나 바로 발주서를 발행할 수 있습니다.')}`,
  async(f,k)=>{read();for(const l of lines){l.item=required(l.item,'품명',200);l.specification=String(l.specification||'').trim().slice(0,200);l.unit=required(l.unit,'단위',20);l.qty=qty(l.qty,'수량',false);l.unit_price=money(l.unit_price);}if(approvals.some(a=>!a.user_id))throw Error('결재자를 선택하세요.');if(new Set(approvals.map(a=>a.user_id)).size!==approvals.length)throw Error('결재자 중복입니다.');await this.command('purchase_submit',{data:{...f,lines,tax_rate:Number(f.tax_rate),approvals}},k);},'결재 상신');
  const root=draft.querySelector('.modalbody');
  const read=()=>{lines=all('.purchase-line',root).map(el=>Object.fromEntries(all('[data-field]',el).map(x=>[x.dataset.field,x.value])));approvals=all('.a-line',root).map(el=>({user_id:el.querySelector('select').value,required:el.querySelector('input[type=checkbox]').checked}));};
  const fillOptions=(i,itemVal,specVal)=>{
   const el=$(`#purchaseLine-${i}`,root);if(!el)return;
   const items=el.querySelector('datalist[data-items]'),specs=el.querySelector('datalist[data-specs]');
   items.innerHTML=itemSuggestions(cat,itemVal).map(s=>`<option value="${esc(s)}"></option>`).join('');
   specs.innerHTML=specSuggestions(cat,itemVal).map(s=>`<option value="${esc(s)}"></option>`).join('');
  };
  const render=()=>{
   $('#purchaseLines',root).innerHTML=lines.map((l,i)=>`<div class="purchase-line" id="purchaseLine-${i}">
    <div class="purchase-line-no">${i+1}</div>
    <label class="purchase-item-name">품명 · 검색 또는 신규 입력<input data-field="item" list="purchaseItem-${i}" value="${esc(l.item)}" required maxlength="200" autocomplete="off" placeholder="품명 일부 입력"><datalist id="purchaseItem-${i}" data-items></datalist></label>
    <label>규격 / 사양<input data-field="specification" list="purchaseSpec-${i}" value="${esc(l.specification)}" maxlength="200" autocomplete="off" placeholder="선택 또는 입력"><datalist id="purchaseSpec-${i}" data-specs></datalist></label>
    <label>수량<input data-field="qty" type="number" min="1" step="1" value="${esc(l.qty)}" required></label>
    <label>단위<input data-field="unit" value="${esc(l.unit)}" required maxlength="20"></label>
    <label>예상 단가<input data-field="unit_price" type="number" min="0" step="0.01" value="${esc(l.unit_price)}" required placeholder="확인 후 입력"></label>
    <button type="button" class="quiet" data-remove-purchase="${i}" title="행 삭제" aria-label="${i+1}행 삭제">×</button></div>`).join('');
   $('#approvalLines',root).innerHTML=approvals.map((a,i)=>`<div class="a-line"><span class="stepnum">${i+1}</span><select required aria-label="${i+1}번째 결재자"><option value="">결재자 선택</option>${people.map(p=>`<option value="${esc(p.id)}" ${p.id===a.user_id?'selected':''}>${esc(p.name)}</option>`).join('')}</select><label class="check"><input type="checkbox" ${a.required?'checked':''}>필수 결재</label><button type="button" class="quiet" data-remove-approver="${i}" aria-label="결재자 삭제">×</button></div>`).join('');
   lines.forEach((l,i)=>fillOptions(i,l.item,l.specification));
   all('.purchase-line',root).forEach((el,i)=>{
    const item=el.querySelector('[data-field="item"]'),spec=el.querySelector('[data-field="specification"]');
    item.addEventListener('input',()=>fillOptions(i,item.value,spec.value));
    item.addEventListener('change',()=>{
     const suggestions=specSuggestions(cat,item.value);if(suggestions.length===1&&!spec.value)spec.value=suggestions[0];
     const found=matchingCatalog(cat,item.value,spec.value);if(found){if(!el.querySelector('[data-field="unit"]').value)el.querySelector('[data-field="unit"]').value=found.unit||'';
      if(!el.querySelector('[data-field="unit_price"]').value&&found.unit_price!==null)el.querySelector('[data-field="unit_price"]').value=String(found.unit_price);}
     fillOptions(i,item.value,spec.value);
    });
    spec.addEventListener('input',()=>fillOptions(i,item.value,spec.value));
    spec.addEventListener('change',()=>{const found=matchingCatalog(cat,item.value,spec.value);if(found){const unit=el.querySelector('[data-field="unit"]');if(!unit.value)unit.value=found.unit||'';const price=el.querySelector('[data-field="unit_price"]');if(!price.value&&found.unit_price!==null)price.value=String(found.unit_price);}});
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
  const dt=seoulDate();const number='PO-'+r.code.replace(/^PR-/,'');
  modal('발주서 발행 · '+r.code,`<p><b>공급업체: ${esc(r.data.supplier)}</b> · 승인금액 ${moneyText(r.data.total)}원</p>${notice('구매의뢰 1건당 발주서 1건만 확정됩니다. 확정 후 금액·품목 변경은 재승인 절차가 필요합니다.')}
  <div class="fields">${input('po_no','발주번호',number,'text','required maxlength="100"')}${input('po_date','발주일',dt,'date','required')}${input('po_delivery_date','납기 요청일',r.data.due_date||'','date')}</div>${area('po_note','특기사항 / 발주조건',r.data.note||'')}`,
  (f,k)=>this.command('purchase_order',{id:r.id,version:r.version,...f},k),'발주 확정');
 }
 async receipts(){
  const [prs,receipts]=await Promise.all([this.rec('purchase'),this.rec('receipt')]);
  const orders=this.filter(prs.filter(x=>['ORDERED','PARTIAL','RECEIVED','MATCHED','PAID'].includes(x.state)));
  if(this.page!=='receipts')return;
  this.set(`<div class="card">${this.top()}<h2>발주서별 · 품목별 입고</h2>${notice('발주서 1건 안에서 품목별로 나누어 입고할 수 있습니다. 누적 입고량과 잔량을 함께 확인하세요.')}
   ${table(['발주번호 / 의뢰번호','공급업체','품목수 / 입고진척','상태','관리'],this.pagedCells(orders,r=>{
     const q=receiptQuantities(r,receipts);const done=q.filter(x=>x.remaining===0).length;
     return [esc(r.data.po_no)+'<small> / '+esc(r.code)+'</small>',esc(r.data.supplier||r.title),`${done} / ${q.length} 품목 완료`,pill(r.state),['ORDERED','PARTIAL'].includes(r.state)&&permit(this.ctx,'receipts','create')?btn('receive','품목별 입고',r.id,'primary'):btn('purchaseDetail','발주·입고 상세',r.id)];}))}<div id="v4pager" class="pagination"></div></div>
   <div class="card"><h2>최근 입고 / 반품 기록</h2>${table(['입고일','발주처 / 품목','품목순번','합격 / 불합격','상태 / 관리'],receipts.slice(0,100).map(r=>[esc(String(r.data.received_at||r.created_at).slice(0,10)),esc(r.data.supplier||'')+' / '+esc(r.title),Number(r.data.line)+1,`${moneyText(r.data.accepted)} / ${moneyText(r.data.rejected)}`,r.state==='CONFIRMED'&&Number(r.data.accepted)>0&&permit(this.ctx,'receipts','create')?btn('returnReceipt','반품',r.id):pill(r.state)]))}</div>`);
  this.pageFooter(orders);
 }
 async receiveForm(r){
  const receipts=await this.rec('receipt',{parent:r.id});const lines=receiptQuantities(r,receipts);const live=lines.filter(x=>x.remaining>0);
  if(!live.length)throw Error('발주 품목이 모두 입고되었습니다.');
  const opts=live.map(x=>[String(x.index),`${x.index+1}. ${x.item} / ${x.specification||'규격 없음'} · 잔량 ${moneyText(x.remaining)} ${x.unit}`]);
  const d=modal('발주별 품목 입고 · '+r.data.po_no,`${notice('입고한 실제 품목과 수량을 등록합니다. 한 발주서의 여러 품목을 날짜별로 나누어 입력할 수 있습니다.')}
  ${select('line','입고 품목',opts)}<div id="receiptRemain"></div><div class="fields">${input('accepted','합격 입고수량',0,'number','required min="0" step="1"')}${input('rejected','불합격 수량',0,'number','required min="0" step="1"')}</div>${area('note','입고검사 결과 / 증빙 메모')}`,
  (f,k)=>{const accepted=qty(f.accepted,'합격입고수량'),rejected=qty(f.rejected,'불합격수량');const selected=lines.find(x=>x.index===Number(f.line));if(accepted+rejected===0)throw Error('입고수량을 입력하세요.');if(accepted>selected.remaining)throw Error('합격 입고수량이 잔량을 초과했습니다.');return this.command('purchase_receive',{id:r.id,version:r.version,line:Number(f.line),accepted,rejected,note:f.note},k);},'입고 등록');
  const line=d.querySelector('[name="line"]'),help=d.querySelector('#receiptRemain');
  const refresh=()=>{const l=lines.find(x=>x.index===Number(line.value));help.innerHTML=`<p class="notice info">발주 ${moneyText(l.ordered)} / 누적 합격 ${moneyText(l.received)} / 현재 잔량 <b>${moneyText(l.remaining)} ${esc(l.unit)}</b></p>`;};line.onchange=refresh;refresh();
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
  <h3>거래처별 지급합계</h3>${table(['거래처','지급건수','지급합계'],sum.map(x=>[esc(x.supplier),`${x.count}건`,`<b>${moneyText(x.amount)}원</b>`]))}
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
  if(action==='purchaseQuote')return this.purchaseQuote(await this.s.one(id));
  if(action==='purchaseOrder')return this.purchaseOrder(await this.s.one(id));
  if(action==='addPayment')return this.paymentForm();
  if(action==='editPayment')return this.paymentForm(await this.s.one(id));
  const doc={printPurchaseRequest:['request','print'],printPurchaseQuote:['quote','print'],printPurchaseOrder:['order','print'],sharePurchaseRequest:['request','share'],sharePurchaseQuote:['quote','share'],sharePurchaseOrder:['order','share']}[action];
  if(doc){const r=await this.s.one(id);if(doc[1]==='print')return printPurchaseDocument(r,doc[0]);const result=await sharePurchaseImage(r,doc[0]);if(result==='다운로드')message('이미지 파일이 다운로드 폴더에 저장되었습니다. 이메일·메신저에서 공유하세요.','success');return;}
  return super.action(action,id);
 }
}
