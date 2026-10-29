import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {WORK_STATES,workerAssignedOperations,workerTaskStatus,validateSteps} from '../public/modules/routing-domain.js';
import {GROUPS} from '../public/modules/permissions.js';
const fixture=(id,profileIds=['worker-a'],state='WAIT',employeeName='작업자A')=>({id,kind:'operation',parent_id:'routing-1',state,title:'NC 작업',data:{part_no:'A001',due_date:'2026-11-20',qty:100,employee_name:employeeName,profile_ids:profileIds,profile_id:profileIds[0],equipment_code:id}});
const route=[{id:'routing-1',state:'RELEASED'}];
const log=(id,state,worker,date,total=0)=>({id,parent_id:'op-1',state,updated_at:date+'T08:00:00Z',data:{profile_id:worker,work_date:date,start_at:date+'T07:00:00Z',end_at:date+'T08:00:00Z',total}});
test('assigned worker appears on multiple equipment and orders',()=>{
 const operations=[fixture('op-1'),fixture('op-2'),fixture('op-3',['worker-a','worker-b'])];
 assert.deepEqual(workerAssignedOperations(route,operations,'worker-a').map(o=>o.id),['op-1','op-2','op-3']);
 assert.deepEqual(workerAssignedOperations(route,operations,'worker-b').map(o=>o.id),['op-3']);
});
test('multiple workers on one operation without a fixed equipment mapping',()=>{
 const a=validateSteps([{code:'010',name:'1차 황삭',kind:'WORK',equipment_id:'eq-1',employee_ids:['emp-a','emp-b']}]);
 assert.deepEqual(a[0].employee_ids,['emp-a','emp-b']);assert.equal(a[0].employee_id,'emp-a');
});
test('same person may be assigned to multiple independent operations',()=>{
 const ops=validateSteps([{code:'010',name:'NC',kind:'WORK',employee_ids:['emp-a']},{code:'020',name:'연마',kind:'WORK',employee_ids:['emp-a']}]);
 assert.equal(ops[0].employee_ids[0],ops[1].employee_ids[0]);
});
test('the same worker cannot be entered twice inside one operation',()=>{
 assert.throws(()=>validateSteps([{code:'010',name:'NC',kind:'WORK',employee_ids:['emp-a','emp-a']}]),/중복/);
});
test('draft may be composed without registering a product template or assigning employees',()=>{
 assert.equal(validateSteps([{code:'010',name:'NC',kind:'WORK'}])[0].employee_ids.length,0);
});
test('worker status transitions are independent when two workers share operation',()=>{
 const op=fixture('op-1',['worker-a','worker-b']);
 assert.equal(workerTaskStatus(op,[],'worker-a').code,'ASSIGNED');
 assert.equal(workerTaskStatus(op,[log('l1','ACTIVE','worker-a','2026-10-26')],'worker-a').code,'ACTIVE');
 assert.equal(workerTaskStatus(op,[log('l1','ACTIVE','worker-a','2026-10-26')],'worker-b').code,'ASSIGNED');
});
test('urgent pause and next-day resumption are distinct segments',()=>{
 const op=fixture('op-1');
 const pauses=[log('l1','PAUSED','worker-a','2026-10-26'),log('l2','PAUSED','worker-a','2026-10-27')];
 const status=workerTaskStatus(op,pauses,'worker-a');
 assert.equal(status.code,'PAUSED');assert.equal(status.days,2);assert.equal(status.pausedCount,2);
 const resumed=workerTaskStatus(op,[...pauses,log('l3','ACTIVE','worker-a','2026-10-28')],'worker-a');
 assert.equal(resumed.code,'ACTIVE');assert.equal(resumed.days,3);
});
test('partial completion sums only personal confirmed quantities',()=>{
 const op=fixture('op-1',['worker-a','worker-b']);
 const logs=[log('a','CONFIRMED','worker-a','2026-10-26',15),log('b','CONFIRMED','worker-b','2026-10-26',20),log('c','CONFIRMED','worker-a','2026-10-27',8)];
 const a=workerTaskStatus(op,logs,'worker-a');assert.equal(a.code,'PARTIAL');assert.equal(a.personalQty,23);assert.equal(a.days,2);
});
test('done routing operation remains visible for worker history',()=>{
 const r=[{id:'routing-1',state:'DONE'}];const o=[fixture('op-1',['worker-a'],'DONE')];
 assert.deepEqual(workerAssignedOperations(r,o,'worker-a').map(x=>x.id),['op-1']);
 assert.equal(workerTaskStatus(o[0],[],'worker-a').code,'DONE');
});
test('user-facing menu moves master templates away from customer order',()=>{
 const nav=Object.fromEntries(GROUPS);
 assert.deepEqual(nav['수주관리'],['orders','routing']);
 assert.ok(nav['기준정보'].includes('templates'));
 assert.ok(!nav['초기구축·운영'].includes('routingSetup'));
});
const sql=readFileSync(new URL('../database/14_upgrade_v4_5.sql',import.meta.url),'utf8');
const ui=readFileSync(new URL('../public/modules/v41.js',import.meta.url),'utf8');
const master=readFileSync(new URL('../public/modules/v42.js',import.meta.url),'utf8');
test('v4.5 SQL uses additive migration and retains old business records',()=>{
 assert.match(sql,/BEGIN;/);assert.match(sql,/COMMIT;/);
 assert.doesNotMatch(sql.replace(/^--.*$/gm,''),/\bDROP\s+TABLE\b|\bTRUNCATE\b|\bDELETE\s+FROM\b/i);
});
test('SQL migration removes mandatory prelinked equipment-worker map at release',()=>{
 const f=sql.split('FUNCTION public.dnm_v45_team(')[1].split('END $$;')[0];
 assert.doesNotMatch(f,/kind='assignment'/);assert.match(f,/employee_ids/);assert.match(f,/profile_ids/);
});
test('SQL supports direct Routing creation without a template and same-part historical source',()=>{
 assert.match(sql,/신규 품번은 템플릿 없이/);
 assert.match(sql,/source_routing_id/);
 assert.match(sql,/data->>'part_no'=parent.data->>'part_no'/);
});
test('SQL supports pause, independent active logs, multiple worker profile_ids and chosen workday',()=>{
 for(const x of ["p_action='pause_work'",'PAUSED',"profile_ids",'work_date',"종료",'worklog'])assert.ok(sql.includes(x),x);
});
test('bulk activation is restricted to administrator and batch-limited',()=>{
 assert.match(sql,/public\.dnm_v45_bulk_state/);assert.match(sql,/role\(\) IS DISTINCT FROM 'admin'/);assert.match(sql,/BETWEEN 1 AND 200/);
 assert.match(master,/bulkUseMaster/);
});
test('order form opens Routing directly, and worker finish form asks for work date',()=>{
 assert.match(ui,/Routing Sheet 바로 작성/);assert.match(ui,/source_routing_id/);assert.match(ui,/배정 작업자 — 복수 선택 가능/);
 assert.match(ui,/작업일자 \(본인 선택\)/);assert.match(ui,/pause_work/);
});
test('fixed equipment-worker master binding is absent from setup form',()=>{
 const section=master.split('async workforceSetup(){')[1].split('async routeCandidates(){')[0];
 assert.doesNotMatch(section,/가능 공정명|assignProcesses|assignment['",]/);
});
