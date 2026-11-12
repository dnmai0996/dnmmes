export async function boot(window){
        const {V4101Controller}=await import('../../public/modules/v4101.js');
        const {permissionPreset}=await import('../../public/modules/permissions.js');
        const records=window.records=[];
        const add=(id,kind,code,title,state,data,parent_id=null)=>{const r={id,kind,code,title,state,data,parent_id,version:1,updated_at:'2026-11-12T01:00:00Z'};records.push(r);return r;};
        add('o1','order','CO-001','민수 부싱','OPEN',{order_type:'CIVIL',shop_order_no:'SO-2026-001',heat_code:'HC-A100',part_no:'C-BUSH-001',qty:384,customer:'검증 고객',due_date:'2026-12-01'});
        add('o2','order','DO-001','방산 부품','OPEN',{order_type:'DEFENSE',part_no:'D-001',qty:10});
        for(let i=1;i<=2;i++){
            add('r'+i,'routing','2611-000'+i,'민수 부싱','RELEASED',{daily:true,order_type:'CIVIL',lot:'2611-000'+i,shop_order_no:'SO-2026-001',heat_code:'HC-A100',part_no:'C-BUSH-001',qty:96,manager_id:'admin',plan_date:'2026-11-12'},'o1');
            for(let seq=1;seq<=2;seq++)add('op'+i+seq,'operation','OP'+i+seq,'품질검사',seq===1?'DONE':'WAIT',{seq,kind:'WORK',op_code:String(seq*10).padStart(3,'0'),qty:96,confirmed_qty:seq===1?96:0,independent:true,employee_id:'w1',employee_name:'김작업',equipment_id:'e1',equipment_code:'NC01'},'r'+i);
        }
        add('r3','routing','DRAFT-DEF','방산 부품','DRAFT',{qty:10,part_no:'D-001'},'o2');
        add('log1','worklog','LOG1','품질검사','CONFIRMED',{start_at:'2026-11-12T01:00:00Z',end_at:'2026-11-12T02:00:00Z',work_date:'2026-11-12',employee_id:'w2',employee_name:'박실제',equipment_id:'e2',equipment_code:'NC02',total:96,good:94,defect:2,minutes:60},'op11');
        add('e2','equipment','NC02','후가공 설비','OPEN',{active:true});add('e1','equipment','NC01','가공 설비','OPEN',{active:true});
        add('w2','employee','E002','박실제','OPEN',{active:true,department:'생산2팀'});add('w1','employee','E001','김작업','OPEN',{active:true,department:'생산1팀'});
        add('p1','process_master','TURN','선삭','OPEN',{active:true,kind:'WORK'});
        const requests=window.requests=[];window.failOnce=false;window.printCount=0;
        const api={request:async(path,options={})=>{
          if(path.startsWith('/rest/v1/dnm_v4_records?')){
            const q=new URL('http://test'+path).searchParams;let rows=records;
            for(const key of ['id','kind','parent_id','state'])if(q.has(key))rows=rows.filter(r=>String(r[key])===q.get(key).slice(3));
            const total=rows.length;return {data:structuredClone(rows.slice(Number(q.get('offset')||0),Number(q.get('offset')||0)+Number(q.get('limit')||500))),total};
          }
          const body=options.body;
          if(path.endsWith('/dnm_v4101_balances'))return {data:{ok:true,rows:body.ids.map(id=>{const o=records.find(r=>r.id===id);const allocated=records.filter(r=>r.kind==='routing'&&r.parent_id===id&&r.data.daily&&!['CANCELLED','SUPERSEDED'].includes(r.state)).reduce((n,r)=>n+r.data.qty,0);return {id,qty:o.data.qty,allocated,remaining:o.data.qty-allocated};})}};
          if(path.endsWith('/dnm_v4101_edit_status'))return {data:{ok:true,rows:body.ids.map(id=>({id,editable:!window.finalLocked||controller.ctx.profile.role==='admin',final_locked:!!window.finalLocked}))}};
          if(path.endsWith('/dnm_v494_blocked'))return {data:{ok:true,ids:[]}};
          if(path.endsWith('/dnm_v410_plan_info'))return {data:{ok:true,remaining:384,allocated:0,lots:[]}};
          if(path.endsWith('/dnm_v410_work_choices'))return {data:{ok:true,jobs:records.filter(r=>r.kind==='operation'&&r.state==='WAIT'),machines:[{id:'e1',title:'가공 설비',code:'NC01'},{id:'e2',title:'후가공 설비',code:'NC02'}],employees:[{id:'w1',title:'김작업',code:'E001'},{id:'w2',title:'박실제',code:'E002'}]}};
          if(path.endsWith('/dnm_v410_split')){requests.push({path,body:structuredClone(body)});if(window.failOnce){window.failOnce=false;const err=Error('시험 중 응답 유실');err.unknown=true;throw err;}return {data:{ok:true,ids:['new1'],count:body.p.quantities.length}};}
          requests.push({path,body:structuredClone(body)});return {data:{ok:true}};
        }};
        const ctx={version:'4.2.0',profile:{id:'admin',active:true,role:'admin',display_name:'검증관리자'},permissions:permissionPreset('production'),capabilities:['production','work'],people:[{id:'admin',name:'검증관리자',role:'admin',production:true}]};
        let controller;window.controller=controller=new V4101Controller(api,ctx,page=>controller.load(page));
        controller.civil.print=async()=>{window.printCount++;};
        await controller.load('civilRouting');
    
return window.controller;
}
