import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {catalogIndex,itemSuggestions,specSuggestions,matchingCatalog,receiptQuantities,isPayment,paymentRow,filterPayments,paymentSummary,purchaseFlowState,seoulDate} from '../public/modules/purchase-utils.js';
import {purchaseDocData,purchaseDocName,purchaseDocumentMarkup} from '../public/modules/purchase-doc.js';
const material=(id,item,spec,active=true,unit='EA')=>({id,code:id,title:item,kind:'material_master',state:active?'OPEN':'INACTIVE',data:{active,specification:spec,unit}});
const pur={id:'p1',code:'PR-111',title:'㈜부품공급',kind:'purchase',state:'APPROVED',created_at:'2026-10-29T07:12:00Z',data:{supplier:'㈜부품공급',due_date:'2026-11-07',tax:100,subtotal:1000,total:1100,lines:[{item:'샤프트',specification:'S1',unit:'EA',qty:6,unit_price:100,amount:600},{item:'부싱',specification:'B2',unit:'EA',qty:4,unit_price:100,amount:400}],approvals:[{user_id:'a',state:'APPROVED'}]}};
const receipt=(id,line,accepted,rejected=0)=>({id,parent_id:'p1',data:{line,accepted,rejected}});
test('catalog lookup matches substrings but keeps item and specification independent',()=>{
 const rows=[material('m1','초경 드릴','Ø8'),material('m2','초경 드릴','Ø10'),material('m3','마이크로 드릴','Ø8')];const cat=catalogIndex(rows,[]);
 assert.deepEqual(itemSuggestions(cat,'드릴'),['마이크로 드릴','초경 드릴']);
 assert.deepEqual(specSuggestions(cat,'초경 드릴'),['Ø8','Ø10']);
 assert.equal(matchingCatalog(cat,'초경 드릴','Ø10')?.code,'m2');
 assert.equal(matchingCatalog(cat,'초경 드릴','미등록'),null);
});
test('inactive material is not silently recommended for new purchase',()=>{
 assert.equal(catalogIndex([material('inactive','퇴출공구','D',false)],[]).length,0);
});
test('a previously unseen item/spec remains a legal typed value at the editor',()=>{
 assert.equal(matchingCatalog([], '신규자재', 'M12'),null);
});
test('partially received purchase lines aggregate separately including returns',()=>{
 const q=receiptQuantities(pur,[receipt('r1',0,2),receipt('r2',0,3,1),receipt('r3',1,4),receipt('return',0,-1)]);
 assert.equal(q[0].ordered,6);assert.equal(q[0].received,4);assert.equal(q[0].remaining,2);assert.equal(q[0].rejected,1);
 assert.equal(q[1].remaining,0);
});
test('payment period and supplier filtering includes boundaries and sorts descending',()=>{
 const p=[{supplier:'A',date:'2026-10-28',amount:100,code:'1'},{supplier:'A',date:'2026-10-29',amount:200,code:'2'},{supplier:'B',date:'2026-10-29',amount:400,code:'3'}];
 const v=filterPayments(p,{from:'2026-10-29',to:'2026-10-29',supplier:'A'});assert.equal(v.length,1);assert.equal(v[0].amount,200);
 assert.deepEqual(paymentSummary(p).map(x=>[x.supplier,x.count,x.amount]),[['B',1,400],['A',2,300]]);
});
test('old paid settlement remains represented as read-only legacy payment',()=>{
 const r={id:'settle',code:'ST-123',title:'㈜부품공급',kind:'settlement',state:'PAID',parent_id:'p1',data:{paid_at:'2026-10-29T14:30:00Z',payment_reference:'REF1',amount:400}};
 assert.equal(isPayment(r),true);assert.equal(paymentRow(r).legacy,true);assert.equal(paymentRow(r).amount,400);
});
test('purchase workflow distinguishes optional quote before order',()=>{
 assert.match(purchaseFlowState(pur),/승인 완료/);
 assert.match(purchaseFlowState({...pur,data:{...pur.data,quote_request:{quote_no:'RQ-1'}}}),/견적의뢰 완료/);
 assert.match(purchaseFlowState({...pur,state:'PARTIAL',data:{...pur.data,po_no:'PO-1'}}),/부분입고/);
});
test('documents populate approved values from real purchase record and preserve special text safely',()=>{
 const p={...pur,data:{...pur.data,quote_request:{quote_no:'RQ-999',issued_date:'2026-10-29',response_due:'2026-11-03'},po_no:'PO-999',po_date:'2026-10-29'}};
 assert.equal(purchaseDocData(p,'request').number,'PR-111');
 assert.equal(purchaseDocData(p,'quote').number,'RQ-999');
 assert.equal(purchaseDocData(p,'order').number,'PO-999');
 assert.match(purchaseDocumentMarkup(p,'order'),/발주서/);assert.match(purchaseDocumentMarkup(p,'quote'),/견적의뢰서/);
 assert.match(purchaseDocName(p,'order'),/PO-999/);
 assert.throws(()=>purchaseDocData(pur,'quote'),/발행된 문서/);
 const unsafe={...p,data:{...p.data,supplier:'<img src=x onerror=alert(1)>'}};
 const html=purchaseDocumentMarkup(unsafe,'request');assert.ok(!html.includes('<img src=x'));
});
test('Seoul date avoids UTC midnight rollover',()=>{
 assert.equal(seoulDate(new Date('2026-10-28T16:00:00Z')),'2026-10-29');
});
const sql=readFileSync(new URL('../database/16_upgrade_v4_6_purchase.sql',import.meta.url),'utf8');
const app=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const ui=readFileSync(new URL('../public/modules/v46.js',import.meta.url),'utf8');
const editor=readFileSync(new URL('../public/modules/step-editor.js',import.meta.url),'utf8');
test('migration is additive and routes optional quote/order and supplier payments',()=>{
 assert.match(sql,/BEGIN;[\s\S]*COMMIT;/);assert.doesNotMatch(sql.replace(/^--.*$/gm,''),/\b(?:DROP\s+TABLE|TRUNCATE|DELETE\s+FROM)\b/i);
 for(const action of ['purchase_quote','purchase_order','purchase_payment_add','purchase_payment_edit'])assert.ok(sql.includes("'"+action+"'"),action);
 assert.match(sql,/old\.state<>'APPROVED'/);assert.match(sql,/IF used\+amount>/);
});
test('migration keeps authorization and idempotency checks on server',()=>{
 assert.match(sql,/dnm_private\.need\(m,a\)/);assert.match(sql,/p_key IS NULL/);
 assert.match(sql,/prev\.payload_hash<>hash/);assert.match(sql,/public\.dnm_v4_need\('purchase'\)/);
 assert.match(sql,/target_id uuid/);assert.doesNotMatch(sql,/\(id IS NULL OR x\.id<>id\)/);
});
test('existing purchase_submit and receipt commands remain in delegated v4.5 implementation',()=>{
 assert.match(sql,/RETURN dnm_private\.dnm_v41_command_impl/);
 assert.match(ui,/purchase_submit/);assert.match(ui,/purchase_receive/);
});
test('route UI explains missing equipment and offers admin activation',()=>{
 assert.match(editor,/설비.*사용 중/);assert.match(editor,/기준정보 검토·활성화/);
 assert.match(ui,/goEquipmentActivation/);
 assert.match(app,/V46Controller/);
});
