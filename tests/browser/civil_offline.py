"""Exercises civil screens with the production controller and an in-memory API."""
import json, os, posixpath, re, tempfile
from pathlib import Path
from playwright.sync_api import sync_playwright
BASE=Path(__file__).resolve().parents[2]
OUT=Path(os.environ.get('DNM_TEST_OUTPUT', tempfile.mkdtemp(prefix='dnm-civil-test-')));OUT.mkdir(parents=True, exist_ok=True)
modules={}
for path in (BASE/'public').rglob('*.js'):
    name=path.relative_to(BASE).as_posix()
    def rewrite(match):
        target=posixpath.normpath(posixpath.join(posixpath.dirname(name),match.group(2)))
        return match.group(1)+'dnm:'+target+match.group(3)
    modules['dnm:'+name]=re.sub(r"((?:from\s*|import\s*)['\"])(\.{1,2}/[^'\"]+)(['\"])",rewrite,path.read_text())
results=[]
def check(name,condition=True):
    assert condition,name
    results.append(name)
with sync_playwright() as pw:
    browser=pw.chromium.launch(executable_path=os.environ.get('DNM_CHROMIUM') or '/usr/bin/chromium',headless=True,args=['--no-sandbox'])
    page=browser.new_page(viewport={'width':1440,'height':1000});errors=[]
    page.on('pageerror',lambda e:errors.append(str(e)))
    page.set_content('<!doctype html><html lang="ko"><head><title>민수 오프라인 검증</title></head><body><main><h1>민수 LOT·Routing</h1><div id="message" hidden></div><div id="content"></div></main></body></html>')
    for name in ['styles.css','v41.css','v42.css','navigation.css','v43.css','v44.css','v46.css','modules/civil.css']:
        page.add_style_tag(content=(BASE/'public'/name).read_text())
    page.evaluate('''async modules=>{
        const imports={};for(const [name,source] of Object.entries(modules))imports[name]=URL.createObjectURL(new Blob([source],{type:'text/javascript'}));
        const map=document.createElement('script');map.type='importmap';map.textContent=JSON.stringify({imports});document.head.append(map);
        if(!crypto.randomUUID)crypto.randomUUID=()=>{const data=crypto.getRandomValues(new Uint8Array(16));data[6]=(data[6]&15)|64;data[8]=(data[8]&63)|128;const h=Array.from(data,x=>x.toString(16).padStart(2,'0')).join('');return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;};
        const {V410Controller}=await import('dnm:public/modules/v410.js');
        const {permissionPreset}=await import('dnm:public/modules/permissions.js');
        window.records=[];
        const add=(id,kind,code,title,state,data,parent_id=null)=>{const r={id,kind,code,title,state,data,parent_id,version:1,updated_at:'2026-11-12T01:00:00Z'};records.push(r);return r;};
        add('o1','order','CO-001','민수 부싱','OPEN',{order_type:'CIVIL',shop_order_no:'SO-2026-001',heat_code:'HC-A100',part_no:'C-BUSH-001',qty:384,customer:'검증 고객',due_date:'2026-12-01'});
        add('o2','order','DO-001','방산 부품','OPEN',{order_type:'DEFENSE',part_no:'D-001',qty:10});
        for(let i=1;i<=2;i++){
            add('r'+i,'routing','2611-000'+i,'민수 부싱','RELEASED',{daily:true,order_type:'CIVIL',lot:'2611-000'+i,shop_order_no:'SO-2026-001',heat_code:'HC-A100',part_no:'C-BUSH-001',qty:96,manager_id:'admin',plan_date:'2026-11-12'},'o1');
            for(let seq=1;seq<=2;seq++)add('op'+i+seq,'operation','OP'+i+seq,'품질검사',seq===1?'DONE':'WAIT',{seq,kind:'WORK',op_code:String(seq*10).padStart(3,'0'),qty:96,confirmed_qty:seq===1?96:0,independent:true,employee_id:'w1',employee_name:'김작업',equipment_id:'e1',equipment_code:'NC01'},'r'+i);
        }
        add('r3','routing','DRAFT-DEF','방산 부품','DRAFT',{qty:10,part_no:'D-001'},'o2');
        add('log1','worklog','LOG1','품질검사','CONFIRMED',{start_at:'2026-11-12T01:00:00Z',end_at:'2026-11-12T02:00:00Z',work_date:'2026-11-12',employee_id:'w2',employee_name:'박실제',equipment_code:'NC02',total:96,good:94,defect:2,minutes:60},'op11');
        add('e2','equipment','NC02','후가공 설비','OPEN',{active:true});add('e1','equipment','NC01','가공 설비','OPEN',{active:true});
        add('w2','employee','E002','박실제','OPEN',{active:true,department:'생산2팀'});add('w1','employee','E001','김작업','OPEN',{active:true,department:'생산1팀'});
        add('p1','process_master','TURN','선삭','OPEN',{active:true,kind:'WORK'});
        window.requests=[];window.failOnce=false;window.printCount=0;
        const api={request:async(path,options={})=>{
          if(path.startsWith('/rest/v1/dnm_v4_records?')){
            const q=new URL('http://test'+path).searchParams;let rows=records;
            for(const key of ['id','kind','parent_id','state'])if(q.has(key))rows=rows.filter(r=>String(r[key])===q.get(key).slice(3));
            const total=rows.length;return {data:structuredClone(rows.slice(Number(q.get('offset')||0),Number(q.get('offset')||0)+Number(q.get('limit')||500))),total};
          }
          const body=options.body;
          if(path.endsWith('/dnm_v494_blocked'))return {data:{ok:true,ids:[]}};
          if(path.endsWith('/dnm_v410_plan_info'))return {data:{ok:true,remaining:384,allocated:0,lots:[]}};
          if(path.endsWith('/dnm_v410_work_choices'))return {data:{ok:true,jobs:records.filter(r=>r.kind==='operation'&&r.state==='WAIT'),machines:[{id:'e1',title:'가공 설비',code:'NC01'},{id:'e2',title:'후가공 설비',code:'NC02'}],employees:[{id:'w1',title:'김작업',code:'E001'},{id:'w2',title:'박실제',code:'E002'}]}};
          if(path.endsWith('/dnm_v410_split')){requests.push({path,body:structuredClone(body)});if(window.failOnce){window.failOnce=false;const err=Error('시험 중 응답 유실');err.unknown=true;throw err;}return {data:{ok:true,ids:['new1'],count:body.p.quantities.length}};}
          requests.push({path,body:structuredClone(body)});return {data:{ok:true}};
        }};
        const ctx={version:'4.2.0',profile:{id:'admin',active:true,role:'admin',display_name:'검증관리자'},permissions:permissionPreset('production'),capabilities:['production','work'],people:[{id:'admin',name:'검증관리자',role:'admin',production:true}]};
        window.controller=new V410Controller(api,ctx,page=>controller.load(page));
        controller.civil.print=async()=>{window.printCount++;};
        await controller.load('civilRouting');
    }''',modules)
    page.wait_for_selector('[data-vaction="civil:new"]')
    check('routing lists civil lots only',page.locator('#content').inner_text().count('DRAFT-DEF')==0)
    page.screenshot(path=str(OUT/'civil-list.png'),full_page=True)
    page.click('[data-vaction="civil:new"]');page.select_option('[name=order_id]','o1');page.click('#v4submit');page.wait_for_selector('#civilSize')
    page.fill('#civilSize','96');page.click('#civilRecalculate');check('384 split into 4 lots',page.locator('[data-lot-index]').count()==4)
    page.fill('[data-lot-index="0"]','100');page.fill('[data-lot-index="1"]','92')
    page.fill('#civilSteps [data-s="name"]','선삭');page.fill('#civilSteps [data-s="skl_op_no"]','20')
    page.check('[name=reviewed]')
    check('active worker choice shows department', '김작업 · 생산1팀' in page.locator('#civilSteps').inner_text())
    check('optional planning equipment visible',page.locator('#civilSteps [data-s="equipment_id"]').is_visible())
    page.screenshot(path=str(OUT/'civil-split.png'),full_page=True)
    page.evaluate('window.failOnce=true');page.click('#v4submit');page.wait_for_function('document.querySelector("#v4submit").textContent==="같은 요청 다시 확인"')
    check('unknown save freezes preview',page.locator('[data-lot-index="0"]').is_disabled())
    page.click('#v4submit');page.wait_for_function('!document.querySelector("#v4dialog").open')
    calls=page.evaluate('requests.filter(r=>r.path.endsWith("dnm_v410_split"))')
    check('retry preserves request key and payload',len(calls)==2 and calls[0]['body']==calls[1]['body'])
    check('edited lot split reaches server',calls[0]['body']['p']['quantities']==[100,92,96,96])
    for _ in range(3):
        page.locator('[data-vaction="civil:detail"]').first.click();page.wait_for_selector('#v4dialog[open]');page.click('#v4dismiss')
    page.locator('[data-vaction="civil:detail"]').first.click();page.wait_for_selector('#v4dialog[open]');page.locator('#v4dialog [data-vaction="civil:print"]').click()
    check('modal reopening keeps one click handler',page.evaluate('printCount')==1)
    page.locator('#v4dialog [data-vaction="start"]').first.click();page.wait_for_selector('#v4dialog [name="equipment_id"]')
    check('server-filtered machine choices retained',page.locator('#v4dialog [name="equipment_id"] option').count()==3)
    page.click('#v4dismiss')
    page.evaluate('controller.load("civilResults")');page.wait_for_selector('#civilGroup')
    page.select_option('#civilGroup','order');page.wait_for_timeout(50)
    check('order matrix counts original order once','384 / 192' in page.locator('#content').inner_text())
    check('repeated quality stages use unique columns',page.locator('th').filter(has_text='품질검사').count()==2)
    page.screenshot(path=str(OUT/'civil-results.png'),full_page=True)
    page.select_option('#civilView','logs');page.wait_for_selector('#civilWorker')
    check('results show actual logged worker','박실제' in page.locator('#content').inner_text())
    check('log quantities distinguish good/defect','96 / 94 / 2' in page.locator('#content').inner_text())
    page.set_viewport_size({'width':390,'height':844});page.evaluate('controller.load("civilRouting")');page.wait_for_selector('#civilOrder');page.screenshot(path=str(OUT/'civil-mobile.png'),full_page=True)
    check('mobile document has no horizontal overflow',page.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
    page.evaluate('controller.ctx.profile.role="viewer";controller.ctx.permissions.routing={read:true,create:false,update:false,scope:"all"};controller.load("civilRouting")');page.wait_for_timeout(50)
    check('viewer has no create button',page.locator('[data-vaction="civil:new"]').count()==0)
    denied=page.evaluate('async()=>{try{await controller.civil.routingForm();return false}catch(e){return e.message.includes("권한")}}')
    check('direct create enforces permission',denied)
    check('browser console clean',not errors)
    (OUT/'results.json').write_text(json.dumps({'passed':results,'errors':errors},ensure_ascii=False,indent=2))
    print(json.dumps({'passed':len(results),'output':str(OUT),'errors':errors},ensure_ascii=False))
    browser.close()
