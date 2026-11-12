import test from 'node:test';
import assert from 'node:assert/strict';
import {civilOrderChoices,isDeletedOrder} from '../public/modules/civil-domain.js';
import {assertTransferGroup,reviewValues,reviewProblems,sourceProcessSteps,transferRows} from '../public/modules/source-transfer-domain.js';
import {actionAllowed,pageAllowed,permissionPreset} from '../public/modules/permissions.js';
const row=(id,lot='LOT-'+id,extra={})=>({id,kind:'source_routing',code:'SRC-'+id,title:lot,state:'REFERENCE',version:1,data:{lot,part_no:'P1',part_name:'부싱',part_type:'F',qty:null,...extra}});
const bundle=rows=>({format:'dnm-seed-bundle-v42',bundle_id:'TEST',rows});
const order=(id,state='OPEN',data={})=>({id,code:id,kind:'order',state,data:{order_type:'CIVIL',...data}});
test('deleted state and soft-delete flag are both excluded from Shop Order choices',()=>{
 const orders=[order('a'),order('b','CANCELLED'),order('c','OPEN',{deleted:true}),order('d','CLOSED')];
 assert.deepEqual(civilOrderChoices(orders).map(r=>r.id),['a','d']);
 assert.deepEqual(civilOrderChoices(orders,[],{openOnly:true}).map(r=>r.id),['a']);
 assert.equal(isDeletedOrder(orders[2]),true);
});
test('legacy civil routing does not reintroduce a deleted parent order',()=>{
 const orders=[order('a','OPEN',{order_type:''}),order('b','CANCELLED',{order_type:''}),order('c','OPEN',{order_type:'DEFENSE'})];
 const routes=['a','b'].map(parent_id=>({kind:'routing',parent_id,data:{daily:true}}));
 assert.deepEqual(civilOrderChoices(orders,routes).map(r=>r.id),['a']);
});
test('Shop Order choices sort naturally and never mutate the original order array',()=>{
 const orders=[order('b','OPEN',{shop_order_no:'S10'}),order('a','OPEN',{shop_order_no:'S2'})];
 assert.deepEqual(civilOrderChoices(orders).map(r=>r.id),['a','b']);assert.equal(orders[0].id,'b');
});
test('unknown quantity and current status remain unknown',()=>{
 const v=reviewValues(row('a'));assert.equal(v.qty,null);assert.equal(v.current_state,'');assert.equal(reviewProblems(v).length,2);
});
test('stored review overrides file fields without changing either original',()=>{
 const source=row('a','LOT-A',{mes_transfer:{review:{qty:40,current_state:'IN_PROGRESS',part_no:'CORRECTED'}}}),file=row('b','LOT-A');
 const before=JSON.stringify([source,file]),v=reviewValues(source,file);
 assert.equal(v.qty,40);assert.equal(v.part_no,'CORRECTED');assert.equal(reviewProblems(v).length,0);assert.equal(JSON.stringify([source,file]),before);
});
test('delivered source defaults to completed and cannot silently become ongoing work',()=>{
 const v=reviewValues(row('a','L',{delivery_date:'2026-01-01',qty:10}));assert.equal(v.current_state,'COMPLETED');assert.match(reviewProblems(v).join(),/완료/);
});
test('zero, negative, fractional and unsafe quantities require review',()=>{
 for(const qty of [null,'',0,-1,1.5,'abc',Number.MAX_SAFE_INTEGER+1])assert.ok(reviewProblems({part_no:'P',part_name:'N',current_state:'IN_PROGRESS',qty}).length);
});
test('active conversion lineage survives renamed internal route number',()=>{
 const source=row('a'),route={id:'r',kind:'routing',code:'2611-1234',state:'RELEASED',data:{source_routing_id:'a'}};
 const [r]=transferRows([source],[route]);assert.equal(r.status,'CONVERTED');assert.equal(r.route.id,'r');
});
test('cancelled converted LOT becomes reviewable only via explicit reopen',()=>{
 const source=row('a','LOT-A',{mes_transfer:{status:'CONVERTED'}}),route={id:'r',state:'CANCELLED',data:{source_routing_id:'a'}};
 const [r]=transferRows([source],[route]);assert.equal(r.status,'RETURNED');assert.throws(()=>assertTransferGroup([r]),/재검토/);
});
test('excluded source stays excluded and its reason is retained',()=>{
 const [r]=transferRows([row('a','LOT-A',{mes_transfer:{status:'EXCLUDED',last_error:'수량 미확인'}})],[]);
 assert.equal(r.status,'EXCLUDED');assert.equal(r.lastError,'수량 미확인');assert.throws(()=>assertTransferGroup([r]));
});
test('file presence alone cannot prove source is stored',()=>{
 const [r]=transferRows([],[],bundle([row('a')]));assert.equal(r.status,'MISSING');assert.throws(()=>assertTransferGroup([r]));
});
test('ambiguous legacy matches require a choice, but confirmed conversion lineage resolves reload',()=>{
 const rows=[row('a','L'),row('b','L')],file=bundle([row('f','L')]);
 assert.equal(transferRows(rows,[],file)[0].status,'AMBIGUOUS');
 assert.equal(transferRows(rows,[],file,new Map([['SRC-f','b']]))[0].source.id,'b');
 const routes=[{id:'r',state:'RELEASED',data:{source_routing_id:'b'}}];
 assert.equal(transferRows(rows,routes,file)[0].status,'CONVERTED');
});
test('same active original LOT without source lineage is flagged rather than duplicated',()=>{
 const [r]=transferRows([row('a','L',{qty:10,mes_transfer:{review:{current_state:'NOT_STARTED'}}})],[{state:'RELEASED',data:{lot:'L'}}]);
 assert.equal(r.status,'PENDING');assert.match(r.problems.join(),/기존 운영 LOT/);
});
test('group permits missing quantities for subsequent review but requires matching part and TYPE',()=>{
 const rows=transferRows([row('a'),row('b')],[]);assert.deepEqual(assertTransferGroup(rows),{part:'P1',type:'F'});
 rows[1].data.part_type='NF';assert.throws(()=>assertTransferGroup(rows),/TYPE/);
});
test('conversion group accepts 500 but rejects 501 LOTs',()=>{
 const rows=transferRows(Array.from({length:501},(_,i)=>row(String(i))),[]);
 assert.doesNotThrow(()=>assertTransferGroup(rows.slice(0,500)));assert.throws(()=>assertTransferGroup(rows),/500/);
});
test('source process mapping skips headers and never invents assignment or quantity',()=>{
 const b={sources:{R:{process_templates:{F:[['','','공정번호','공정명'],['10','*010','010','가공','NC','치수확인','M'],['20','020','020','외관검사','','','V'],['30','030','030','코팅']]}}}};
 const steps=sourceProcessSteps(b,'F');assert.equal(steps.length,3);assert.deepEqual(steps.map(s=>s.kind),['WORK','INSPECTION','OUTSOURCE']);
 assert.ok(steps.every(s=>s.employee_id===''&&s.equipment_id===''&&s.independent===false&&!('qty'in s)));assert.equal(steps[1].inspection_code,'V');
});
test('unknown process template produces no invented operations',()=>assert.deepEqual(sourceProcessSteps({},'F'),[]));
test('conversion menu and actions require system admin even with all archive rights',()=>{
 const ctx={profile:{role:'viewer',active:true},permissions:permissionPreset('production')};ctx.permissions.archives={read:true,create:true,update:true};
 assert.equal(pageAllowed(ctx,'civilTransfer'),false);assert.equal(actionAllowed(ctx,'transfer:convert','','archives'),false);
 ctx.profile.role='admin';assert.equal(pageAllowed(ctx,'civilTransfer'),true);assert.equal(actionAllowed(ctx,'transfer:convert','','archives'),true);
});
