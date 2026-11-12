import test from 'node:test';
import assert from 'node:assert/strict';
import {V410Controller} from '../public/modules/v410.js';
import {workerAssignedOperations} from '../public/modules/routing-domain.js';

const route={id:'r',kind:'routing',state:'RELEASED',data:{daily:true}};
const operation={id:'op',kind:'operation',parent_id:'r',state:'ACTIVE',data:{employee_id:'planned',equipment_id:'machine-1',profile_ids:['planner']}};
const log={id:'log',kind:'worklog',parent_id:'op',state:'ACTIVE',data:{employee_id:'actual',equipment_id:'machine-2',profile_id:'worker'}};
function controller(records=[route,operation,log]){
 const c=Object.create(V410Controller.prototype);
 c.s={one:async id=>{const found=records.find(r=>r.id===id);assert.ok(found,'known record only');return found;}};
 c.calls=[];c.saveRpc=async(name,args)=>{c.calls.push({name,args});return {ok:true,id:'log'};};
 return c;
}
test('actual replacement worker sees their active card without changing planned assignment',()=>{
 assert.deepEqual(workerAssignedOperations([route],[operation],'worker','mine',[log]).map(r=>r.id),['op']);
 assert.deepEqual(operation.data.profile_ids,['planner']);
 assert.equal(workerAssignedOperations([route],[operation],'stranger','mine',[log]).length,0);
});
test('terminated routes stay out of active worker cards even with personal history',()=>{
 assert.equal(workerAssignedOperations([{...route,state:'TERMINATED'}],[operation],'worker','mine',[log]).length,0);
});
test('voice finish preserves actual log identity instead of planned operation identity',async()=>{
 const c=controller();await c.command('finish_work',{id:'log',version:3,total:7,defect:1},'same-key');
 assert.deepEqual(c.calls,[{name:'dnm_v410_work',args:{act:'finish',p:{id:'log',version:3,total:7,defect:1,employee_id:'actual',equipment_id:'machine-2'},k:'same-key'}}]);
});
test('voice start defaults to logged-in employee among multiple planned workers',async()=>{
 const c=controller();c.rpc=async(name,p)=>{assert.equal(name,'dnm_v410_work_choices');assert.equal(p.p_operation,'op');return {employee_id:'self'};};
 await c.command('start_work',{id:'op',version:1},'key');
 assert.equal(c.calls[0].args.p.employee_id,'self');
 assert.equal(c.calls[0].args.p.equipment_id,'machine-1');
});
test('pending confirmation uses explicit confirmation mode with idempotency key preserved',async()=>{
 const c=controller();await c.command('confirm_work',{id:'log',version:4,total:3,defect:0},'retry-key');
 assert.equal(c.calls[0].args.p.confirm_pending,true);
 assert.equal(c.calls[0].args.k,'retry-key');
});
