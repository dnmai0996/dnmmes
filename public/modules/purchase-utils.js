// DNM purchase workflow v4.6 — pure, testable projections; no privileged writes.
export const seoulDate=(when=new Date())=>new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit'}).format(when);
export const cleanText=s=>String(s??'').trim();
export function catalogIndex(materials=[],catalog=[]){
 const seen=new Map();
 for(const r of [...materials,...catalog]){
  if(r?.state==='INACTIVE'||r?.data?.active===false||r?.data?.review_required===true)continue;
  const item=cleanText(r.data?.item||r.title),spec=cleanText(r.data?.specification),code=cleanText(r.code),unit=cleanText(r.data?.unit),price=r.data?.unit_price;
  if(!item)continue;
  const key=[item,spec,unit].join('\u0000').toLocaleLowerCase('ko');
  if(!seen.has(key))seen.set(key,{item,specification:spec,unit,code,unit_price:Number.isFinite(Number(price))&&price!==''&&price!=null?Number(price):null,supplier:cleanText(r.data?.supplier)});
 }
 return [...seen.values()].sort((a,b)=>a.item.localeCompare(b.item,'ko'));
}
export function itemSuggestions(catalog,query,limit=12){
 const q=cleanText(query).toLocaleLowerCase('ko');if(!q)return [];
 const vals=new Map();for(const x of catalog){if(x.item.toLocaleLowerCase('ko').includes(q)&&!vals.has(x.item.toLocaleLowerCase('ko')))vals.set(x.item.toLocaleLowerCase('ko'),x.item);}
 return [...vals.values()].sort((a,b)=>(a.toLocaleLowerCase('ko').startsWith(q)?0:1)-(b.toLocaleLowerCase('ko').startsWith(q)?0:1)||a.localeCompare(b,'ko')).slice(0,limit);
}
export function specSuggestions(catalog,item,limit=20){const name=cleanText(item).toLocaleLowerCase('ko');return [...new Set(catalog.filter(x=>x.item.toLocaleLowerCase('ko')===name).map(x=>x.specification).filter(Boolean))].slice(0,limit);}
export function matchingCatalog(catalog,item,spec){const name=cleanText(item).toLocaleLowerCase('ko'),s=cleanText(spec).toLocaleLowerCase('ko');const matches=catalog.filter(x=>x.item.toLocaleLowerCase('ko')===name);const exact=matches.find(x=>x.specification.toLocaleLowerCase('ko')===s);return exact||(matches.length===1?matches[0]:null);}
export function receiptQuantities(purchase,receipts=[]){
 return (purchase?.data?.lines||[]).map((l,i)=>{
  const received=receipts.filter(r=>r.parent_id===purchase.id&&Number(r.data?.line)===i).reduce((n,r)=>n+Number(r.data?.accepted||0),0);
  const rejected=receipts.filter(r=>r.parent_id===purchase.id&&Number(r.data?.line)===i).reduce((n,r)=>n+Number(r.data?.rejected||0),0);
  const ordered=Number(l.qty||0);return {index:i,item:l.item,specification:l.specification,unit:l.unit,ordered,received,rejected,remaining:Math.max(0,ordered-received)};
 });
}
export const isPayment=r=>r?.kind==='settlement'&&(r.data?.entry_type==='payment'||(r.state==='PAID'&&!!r.data?.paid_at&&!!r.data?.payment_reference));
export function paymentRow(r){const legacy=r.data?.entry_type!=='payment';return {id:r.id,version:r.version,supplier:cleanText(r.data?.supplier||r.title),date:cleanText(legacy?String(r.data?.paid_at||'').slice(0,10):r.data?.payment_date),amount:Number(r.data?.amount??r.data?.invoice_amount??0),reference:cleanText(legacy?r.data?.payment_reference:r.data?.reference),note:cleanText(r.data?.note),legacy,po_id:r.parent_id||'',code:r.code};}
export function filterPayments(rows,{from='',to='',supplier=''}={}){return rows.filter(r=>(!from||r.date>=from)&&(!to||r.date<=to)&&(!supplier||r.supplier===supplier)).sort((a,b)=>b.date.localeCompare(a.date)||b.code.localeCompare(a.code));}
export function paymentSummary(rows){const out=new Map();for(const r of rows){if(!Number.isFinite(r.amount)||r.amount<0)continue;const name=r.supplier||'미지정';const z=out.get(name)||{supplier:name,count:0,amount:0};z.count++;z.amount+=r.amount;out.set(name,z);}return [...out.values()].sort((a,b)=>b.amount-a.amount||a.supplier.localeCompare(b.supplier,'ko'));}
export function purchaseFlowState(r){if(r.state==='SUBMITTED')return '결재 진행 중';if(r.state==='APPROVED')return r.data?.quote_request?'견적의뢰 완료 · 발주 대기':'승인 완료 · 발주 대기';if(['ORDERED','PARTIAL','RECEIVED','MATCHED','PAID'].includes(r.state))return `${r.data?.po_no||'발주번호 없음'} · ${({ORDERED:'입고 대기',PARTIAL:'부분입고',RECEIVED:'입고완료',MATCHED:'증빙대사',PAID:'지급기록'})[r.state]}`;return r.state;}
