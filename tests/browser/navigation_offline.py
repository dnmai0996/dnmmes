import json, threading, time, functools, subprocess, traceback, re, posixpath, base64, os, tempfile, shutil
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from playwright.sync_api import sync_playwright
BASE=Path(__file__).resolve().parents[2]; OUT=Path(os.environ.get('DNM_TEST_OUTPUT',tempfile.mkdtemp(prefix='dnm-menu-test-'))); OUT.mkdir(parents=True,exist_ok=True); ORIGIN='https://dnm-test.supabase.co'
class Handler(SimpleHTTPRequestHandler):
 def end_headers(self):
  self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' https://*.supabase.co; img-src 'self' data:; object-src 'none'; base-uri 'self'")
  self.send_header('Cache-Control','no-store'); super().end_headers()
 def log_message(self,*a): pass
srv=ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Handler,directory=str(BASE/'public'))); threading.Thread(target=srv.serve_forever,daemon=True).start(); URL=f'http://127.0.0.1:{srv.server_port}'
profiles={
 'admin':dict(id='00000000-0000-4000-a000-000000000001',role='admin',display_name='검수 관리자',email='admin@example.invalid',active=True,version=1),
 'worker':dict(id='00000000-0000-4000-a000-000000000002',role='member',display_name='검수 작업자',email='worker@example.invalid',active=True,version=1),
 'readonly':dict(id='00000000-0000-4000-a000-000000000003',role='viewer',display_name='조회 검수자',email='viewer@example.invalid',active=True,version=1),
}
meta=json.loads(subprocess.check_output(['node','--input-type=module','-e',"import {permissionPreset,GROUPS,TOP_PAGES} from './public/modules/permissions.js';import {NAV_LABELS} from './public/modules/navigation.js';console.log(JSON.stringify({worker:permissionPreset('worker'),viewer:permissionPreset('viewer'),none:permissionPreset('none'),groups:GROUPS,top:TOP_PAGES,labels:NAV_LABELS}));"],cwd=BASE,text=True))
RO=[]
def rec(id,kind,code,title,state='OPEN',data=None,parent=None):
 r=dict(id=id,kind=kind,code=code,title=title,state=state,data=data or {},parent_id=parent,version=1,owner_id=profiles['admin']['id'],updated_at='2026-10-28T03:00:00Z',created_at='2026-10-28T03:00:00Z');RO.append(r);return r
rec('ord1','order','PO-TEST-001','검수용 부싱',data=dict(part_no='TEST-A001',production_no='PO-TEST-001',qty=100,customer='가상 고객사',priority='NORMAL',due_date='2026-11-20',project='시험자료'))
rec('r1','routing','RT-TEST-001','검수용 부싱','RELEASED',dict(part_no='TEST-A001',production_no='PO-TEST-001',due_date='2026-11-20',lot='LOT-TEST',qty=100,revision=1,manager_id=profiles['admin']['id']), 'ord1')
rec('r2','routing','RT-DRAFT-002','미배포 초안','DRAFT',dict(part_no='TEST-B002',production_no='PO-TEST-002',due_date='2026-11-30',qty=50),'ord1')
rec('op1','operation','OP1','선삭 가공','WAIT',dict(kind='WORK',op_code='010',seq=1,part_no='TEST-A001',production_no='PO-TEST-001',qty=100,confirmed_qty=0,profile_id=profiles['worker']['id'],employee_id='em1',employee_name='검수 작업자',equipment_id='eq1',equipment_code='NC-TEST',manager_id=profiles['admin']['id']),'r1')
rec('op2','operation','OP2','검사','DONE',dict(kind='INSPECTION',op_code='020',seq=2,part_no='TEST-A001',production_no='PO-TEST-001',qty=100,confirmed_qty=100,employee_name='검수 담당',equipment_code='QC-TEST'),'r1')
rec('op3','operation','OP3','미배포 가공','WAIT',dict(kind='WORK',op_code='010',seq=1,qty=50),'r2')
for i in range(1,45):rec('eq'+str(i),'equipment',f'NC-{i:03}','검수용 설비 '+str(i),data=dict(active=True,verified=True,department='생산',category='NC',model='TEST-MODEL',specification='가상 규격',manager_id=profiles['admin']['id'],worker_source='확인완료'))
rec('inst1','instrument','QC-001','검수용 계측기',data=dict(category='치수',manufacturer='가상 제조사',specification='시험 규격',introduced='2024',calibration_due='2026-12-31',active=True,verified=True))
rec('em1','employee','EMP-001','검수 작업자',data=dict(department='생산팀',position='사원',hired='2020-01-01',active=True,verified=True,profile_id=profiles['worker']['id']))
rec('p1','process_master','TURN','선삭 가공',data=dict(kind='WORK',inspection_code='M',active=True,verified=True))
rec('as1','assignment','AS1','검수배정',data=dict(equipment_id='eq1',employee_id='em1',processes=['선삭 가공'],active=True))
rec('tpl1','route_template','TEST-A001','검수용 부싱',data=dict(part_no='TEST-A001',active=True,verified=True,review_required=False,steps=[dict(seq=1,code='010',name='선삭 가공',kind='WORK',inspection_code='M',note='시험')] ))
PORTAL={'products':[dict(id='prod1',code='TEST-A001',name='검수용 부싱',project='시험',unit='EA',active=True,version=1)],'partners':[dict(id='part1',code='C1',name='가상 고객사',category='both',contact='',phone='',active=True,version=1)],'notes':[],'audit':[],'profiles':list(profiles.values())}
results=[]; errors=[]; mutations=[]
def check(name,cond=True):
 assert cond,name
 results.append(name)
def profile_ctx(who):
 pr=profiles[who];perms=meta['worker'] if who=='worker' else meta['viewer'] if who=='readonly' else meta['none']
 if who=='readonly':
  perms=json.loads(json.dumps(perms));perms['equipment']={'read':True,'create':False,'update':False,'scope':'all'};perms['instruments']={'read':True,'create':False,'update':False,'scope':'all'}
 return dict(version='4.2.0',profile=pr,permissions=perms,capabilities=[],people=[dict(id=p['id'],name=p['display_name'],role=p['role']) for p in profiles.values()])
sessions={}
def install(context,who):
 sessions[id(context)]=who
 return {'who':who}
def launch_page(page,context):
 who=sessions[id(context)]
 html=(BASE/'public/index.html').read_text()
 html=re.sub(r'<script[^>]*>.*?</script>','',html)
 html=re.sub(r'<link[^>]+>','',html)
 page.set_content(html)
 for f in ['styles.css','v41.css','v42.css','navigation.css','v43.css','v44.css']:page.add_style_tag(content=(BASE/'public'/f).read_text())
 modules={}
 image='data:image/png;base64,'+base64.b64encode((BASE/'public/assets/dnm-logo.png').read_bytes()).decode()
 for p in (BASE/'public').rglob('*.js'):
  src=p.read_text().replace('assets/dnm-logo.png',image)
  name=p.relative_to(BASE).as_posix()
  def rewrite(m):
   target=posixpath.normpath(posixpath.join(posixpath.dirname(name),m.group(2)))
   return m.group(1)+'dnm:'+target+m.group(3)
  src=re.sub(r"((?:from\s*|import\s*)['\"])(\.{1,2}/[^'\"]+)(['\"])",rewrite,src)
  modules['dnm:'+name]=src
 modules['dnm:public/config.js']=f"export const SUPABASE_URL='{ORIGIN}';export const SUPABASE_PUBLIC_KEY='sb_publishable_TEST_ONLY';"
 session=dict(access_token='test',refresh_token='test-refresh',expires_at=9999999999,user=profiles[who])
 payload={'modules':modules,'origin':ORIGIN,'session':session,'context':profile_ctx(who),'records':RO,'portal':PORTAL}
 page.evaluate(r'''async f=>{
  class MemoryStorage{constructor(){this.values={};}getItem(k){return this.values[k]??null;}setItem(k,v){this.values[k]=String(v);}removeItem(k){delete this.values[k];}clear(){this.values={};}}
  Object.defineProperty(window,'sessionStorage',{value:new MemoryStorage(),configurable:true});
  Object.defineProperty(window,'localStorage',{value:new MemoryStorage(),configurable:true});
  sessionStorage.setItem('dnm-portal-session:'+f.origin,JSON.stringify(f.session));
  window.__testData=f;window.__unexpectedMutations=[];
  // Offline about:blank is not a secure context; shim UUID for test-only modal request IDs.
  if(!crypto.randomUUID)crypto.randomUUID=()=>{const b=crypto.getRandomValues(new Uint8Array(16));b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;const h=Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`;};
  window.fetch=async(input,options={})=>{
   const u=new URL(input),q=u.searchParams,path=u.pathname;let data=[];const headers={'Content-Type':'application/json'};
   if(path==='/rest/v1/rpc/dnm_v4_context')data=window.__testData.context;
   else if(path==='/rest/v1/dnm_v4_records'){
    data=f.records;for(const key of ['kind','id','parent_id','state'])if(q.get(key)?.startsWith('eq.'))data=data.filter(r=>String(r[key])===q.get(key).slice(3));
    const total=data.length,offset=Number(q.get('offset')||0),limit=Number(q.get('limit')||500);data=data.slice(offset,offset+limit);headers['content-range']=`${offset}-${offset+Math.max(0,data.length-1)}/${total}`;
   }else if(path.startsWith('/rest/v1/dnm_portal_')){
    data=f.portal[path.split('dnm_portal_')[1]]||[];if(q.get('id'))data=data.filter(r=>r.id===q.get('id').slice(3));headers['content-range']=`0-${Math.max(0,data.length-1)}/${data.length}`;
   }else if(['/rest/v1/dnm_v4_permissions','/rest/v1/dnm_v42_module_access'].includes(path))data=[];
   else if(path==='/rest/v1/rpc/dnm_v4_backup')data={ok:true,records:f.records,profiles:[]};
   else if(path==='/auth/v1/settings')data={external:{email:true}};
   else if(path==='/auth/v1/logout')data={};
   else if(path==='/auth/v1/token')data=f.session;
   else{if((options.method||'GET')!=='GET')window.__unexpectedMutations.push(path);data={};}
   return new Response(JSON.stringify(data),{status:200,headers});
  };
  const imports={};for(const [name,src] of Object.entries(f.modules))imports[name]=URL.createObjectURL(new Blob([src],{type:'text/javascript'}));
  const map=document.createElement('script');map.type='importmap';map.textContent=JSON.stringify({imports});document.head.append(map);
  await import('dnm:public/app.js');
 }''',payload)

def go(page,key,mobile=False):
 if mobile and not page.locator('.app-shell').evaluate('(e)=>e.classList.contains("nav-open")'):page.click('#mobileNav')
 locator=page.locator(f'[data-tab="{key}"]')
 parent=locator.locator('xpath=ancestor::details')
 if parent.count() and not parent.evaluate('(e)=>e.open'):parent.locator('summary').click()
 locator.click()
 page.wait_for_function('(key)=>document.querySelector("#sideMenu [aria-current=page]")?.dataset.tab===key',arg=key)
 page.wait_for_function('()=>document.querySelector("#connection")?.textContent.includes("연결됨")')
 page.wait_for_timeout(75)

def selected_visible(page):
 return page.evaluate('''()=>{let m=document.querySelector('#sideMenu'),s=m.querySelector('[aria-current=page]');let a=m.getBoundingClientRect(),b=s.getBoundingClientRect();return b.top>=a.top-1&&b.bottom<=a.bottom+1;}''')

with sync_playwright() as pw:
 browser=pw.chromium.launch(executable_path=os.environ.get('DNM_CHROMIUM') or shutil.which('chromium') or pw.chromium.executable_path,headless=True,args=['--no-sandbox'])
 try:
  c=browser.new_context(viewport={'width':1440,'height':900});install(c,'admin');p=c.new_page();p.set_default_timeout(4500);p.on('pageerror',lambda e:errors.append(str(e)));launch_page(p,c);p.wait_for_selector('#title');p.wait_for_function('()=>document.querySelector("#connection")?.textContent.includes("연결됨")')
  check('admin lands at independent dashboard',p.locator('[aria-current=page]').get_attribute('data-tab')=='dashboard')
  check('global expand controls removed',p.locator('#expandNav,#collapseNav').count()==0)
  check('dashboard outside any group',p.locator('[data-tab=dashboard]').locator('xpath=ancestor::details').count()==0)
  check('seven groups',p.locator('#sideMenu details').count()==7)
  # every menu navigation and help are exercised against mock API.
  for key in [*meta['top'],*(p for _,pages in meta['groups'] for p in pages)]:
   go(p,key)
   check('page '+key,p.locator('#title').inner_text()==meta['labels'][key])
   check('selection visible '+key,selected_visible(p))
   check('one current '+key,p.locator('#sideMenu [aria-current=page]').count()==1)
   p.click('#vhelp');p.wait_for_selector('#v4dialog[open]');check('help '+key,len(p.locator('#v4dialog').inner_text())>20);p.click('#v4dismiss')
  # v4.5: customer order opens Routing directly, without pre-registering a product template.
  go(p,'orders'); p.locator('[data-vaction="newRouting"]').first.click(); p.wait_for_selector('#v4dialog[open]')
  check('direct Routing from customer order', '수주에서 Routing Sheet 바로 작성' in p.locator('#v4dialog').inner_text())
  check('direct Routing has blank-draft source', p.locator('#routeSource option[value="blank"]').count()==1)
  check('exact previous Routing is optionally available', p.locator('#routeSource option[value="history:r1"]').count()==1)
  check('existing reviewed template remains optional', p.locator('#routeSource option[value="template:tpl1"]').count()==1)
  p.on('dialog',lambda d:d.accept())
  p.select_option('#routeSource','blank')
  check('blank source permits working without a pre-existing template',p.locator('#stepsHost .step-card').count()==1)
  p.locator('#stepsHost [data-s="name"]').fill('검수 신규공정')
  p.locator('#stepsHost [data-s="code"]').fill('010')
  check('independent equipment and employee options',p.locator('#stepsHost [data-s="equipment_id"]').count()==1 and p.locator('#stepsHost [data-team]').count()>0)
  p.click('#v4dismiss')
  go(p,'sourceReview'); check('bulk use activate available',p.locator('[data-vaction="bulkUseMaster"]').count()==1)
  go(p,'workforceSetup'); check('old fixed equipment-worker constraint removed', '설비·작업자·가능공정' not in p.locator('#content').inner_text())
  # Work screen provides independent date and work status filters.
  go(p,'touchWork');check('worker status filter exists',p.locator('#workStatus').count()==1);p.select_option('#workScope','all');p.wait_for_timeout(120)
  p.locator('[data-vaction="start"]').first.click();p.wait_for_selector('#v4dialog[open]')
  check('worker selects date when starting',p.locator('#v4dialog [name="work_date"]').count()==1)
  p.click('#v4dismiss')
  check('no browser page errors',not errors)
  # Short desktop and all groups manually expanded: independent scrollbar.
  p.set_viewport_size({'width':1280,'height':600})
  for group,_ in meta['groups']:
   d=p.locator(f'[data-navgroup="{group}"]')
   if not d.evaluate('(e)=>e.open'):d.locator('summary').click()
  go(p,'backup');check('bottom menu visible after rerender',selected_visible(p))
  before=p.locator('#sideMenu').evaluate('(e)=>e.scrollTop');go(p,'home');after=p.locator('#sideMenu').evaluate('(e)=>e.scrollTop')
  check('nav scroll not reset to top',before>0 and after>0)
  go(p,'equipment');check('equipment selection group',p.locator('.page-path').inner_text().find('설비·계측관리')>=0)
  check('desktop main at top',p.evaluate('window.scrollY')==0)
  nav_before=p.locator('#sideMenu').evaluate('(e)=>e.scrollTop');p.evaluate('window.scrollTo(0,600)');p.wait_for_timeout(50)
  check('sidebar stays within viewport on page scroll',abs(p.locator('#sideNav').bounding_box()['y'])<1)
  check('main scroll does not scroll nav',p.locator('#sideMenu').evaluate('(e)=>e.scrollTop')==nav_before)
  go(p,'instruments');check('instruments title',p.locator('#title').inner_text()=='계측기관리')
  p.set_viewport_size({'width':1440,'height':960});go(p,'instructions')
  check('released work instructions present','선삭 가공' in p.locator('#content').inner_text())
  check('draft operations excluded','미배포 가공' not in p.locator('#content').inner_text())
  p.select_option('#instructionState','closed');p.wait_for_timeout(150);check('closed instruction filter','검사' in p.locator('#content').inner_text() and '선삭 가공' not in p.locator('#content').inner_text())
  p.select_option('#instructionState','all');p.wait_for_timeout(150);p.fill('#vq','NC-TEST');p.wait_for_timeout(600);check('incremental instruction search','선삭 가공' in p.locator('#content').inner_text() and 'QC-TEST' not in p.locator('#content').inner_text())
  p.fill('#vq','');p.wait_for_timeout(500)
  p.screenshot(path=str(OUT/'desktop-instructions.png'),full_page=False)
  go(p,'equipment');p.screenshot(path=str(OUT/'desktop-equipment.png'),full_page=False)
  # User manually closes group then navigates from main content callback.
  go(p,'dashboard');p.locator('[data-vaction="routeDetail"]').first.click();p.wait_for_selector('#v4dialog[open]');p.click('#v4dismiss');check('dashboard route modal preserved')
  # v4.5.1: all matching orders must be sorted before paging.
  p.evaluate('''()=>{const o=window.__testData.records.find(x=>x.kind==='order');for(let i=1;i<=40;i++){
   const r=structuredClone(o);r.id='sort-order-'+i;r.code='SO-'+String(100+i);r.title='가상 정렬품 '+i;
   r.data={...r.data,part_no:'SORT-'+i,production_no:r.code,qty:i,due_date:'2026-11-'+String(i%28+1).padStart(2,'0')};
   window.__testData.records.push(r);
  }}''')
  go(p,'orders')
  check('order quantity header clickable',p.locator('#content thead [data-table-sort="4"]').count()==1)
  p.locator('#content thead [data-table-sort="4"]').click()
  p.wait_for_function('()=>document.querySelector("#content tbody tr td:nth-child(5)")?.textContent.trim()==="1"')
  check('order quantity asc over all 41 orders',p.locator('#content tbody tr td:nth-child(5)').first.inner_text().strip()=='1')
  check('orders list shows first 30',p.locator('#content tbody tr').count()==30)
  p.locator('#vnext').click()
  p.wait_for_function('()=>document.querySelector("#content tbody tr td:nth-child(5)")?.textContent.trim()==="31"')
  check('order quantity next page starts at 31',p.locator('#content tbody tr td:nth-child(5)').first.inner_text().strip()=='31')
  p.locator('#content thead [data-table-sort="4"]').click()
  p.wait_for_function('()=>document.querySelector("#content tbody tr td:nth-child(5)")?.textContent.trim()==="100"')
  check('order descending over all pages',p.locator('#content tbody tr td:nth-child(5)').first.inner_text().strip()=='100')
  check('sort arrow and accessible state',p.locator('#content thead th').nth(4).get_attribute('aria-sort')=='descending')
  check('order management column not sortable',p.locator('#content thead [data-table-sort="14"]').count()==0)
  p.screenshot(path=str(OUT/'sortable-orders.png'),full_page=False)
  # 44 equipment records distributed across two pages.
  go(p,'equipment')
  p.locator('#content thead [data-table-sort="0"]').click()
  p.wait_for_function('()=>document.querySelector("#content tbody tr td:first-child")?.textContent.trim()==="NC-001"')
  p.locator('#vnext').click()
  p.wait_for_function('()=>document.querySelector("#content tbody tr td:first-child")?.textContent.trim()==="NC-031"')
  check('equipment codes sorted across all 44 records',p.locator('#content tbody tr td:first-child').first.inner_text().strip()=='NC-031')
  p.locator('#content thead [data-table-sort="0"]').click()
  p.wait_for_function('()=>document.querySelector("#content tbody tr td:first-child")?.textContent.trim()==="NC-044"')
  check('equipment descending across all records',p.locator('#content tbody tr td:first-child').first.inner_text().strip()=='NC-044')
  p.screenshot(path=str(OUT/'sortable-equipment.png'),full_page=False)
  c.close()
  # Actual mobile drawer closed/open/selection/scroll/focus and overflow.
  for width in [320,360,390,768]:
   c=browser.new_context(viewport={'width':width,'height':800},is_mobile=True,has_touch=True);install(c,'admin');p=c.new_page();p.set_default_timeout(4500);p.on('pageerror',lambda e:errors.append(str(e)));launch_page(p,c);p.wait_for_selector('#title');p.wait_for_function('()=>document.querySelector("#connection")?.textContent.includes("연결됨")')
   check(f'{width} menu initially closed',not p.locator('#sideNav').is_visible())
   go(p,'equipment',True)
   check(f'{width} drawer closes on selection',not p.locator('#sideNav').is_visible())
   check(f'{width} main interactive after selection',not p.locator('.main-pane').evaluate('(e)=>e.inert'))
   check(f'{width} breadcrumb equipment','설비·계측관리' in p.locator('.page-path').inner_text())
   check(f'{width} no page horizontal overflow',p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   p.click('#mobileNav');p.wait_for_timeout(80);check(f'{width} active menu visible on opening',selected_visible(p));check(f'{width} menu aria expanded',p.locator('#mobileNav').get_attribute('aria-expanded')=='true')
   check(f'{width} main inert while drawer open',p.locator('.main-pane').evaluate('(e)=>e.inert'))
   if width==360:p.screenshot(path=str(OUT/'mobile-menu-360.png'),full_page=False)
   p.keyboard.press('Escape');check(f'{width} escape closes menu',not p.locator('#sideNav').is_visible())
   p.click('#mobileNav');p.click('#navBackdrop',position={'x':width-10,'y':100});check(f'{width} backdrop closes menu',not p.locator('#sideNav').is_visible())
   go(p,'instructions',True);check(f'{width} instructions fit',p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   if width==360:p.screenshot(path=str(OUT/'mobile-instructions-360.png'),full_page=False)
   c.close()
  # Worker ACL excludes other business groups. Real API not used and no RLS claim.
  c=browser.new_context(viewport={'width':1440,'height':900});install(c,'worker');p=c.new_page();p.set_default_timeout(4500);p.on('pageerror',lambda e:errors.append(str(e)));launch_page(p,c);p.wait_for_selector('#title');p.wait_for_function('()=>document.querySelector("#connection")?.textContent.includes("연결됨")')
  check('worker lands own touch work',p.locator('[aria-current=page]').get_attribute('data-tab')=='touchWork')
  check('worker no dashboard or equipment or purchase',p.locator('[data-tab=dashboard],[data-tab=equipment],[data-tab=purchase]').count()==0)
  check('worker existing menu set preserved',set(p.locator('[data-tab]').evaluate_all('(es)=>es.map(e=>e.dataset.tab)'))=={'touchWork','voiceWork','worklogs','notes'})
  p.screenshot(path=str(OUT/'worker-menu.png'),full_page=False);c.close()
  c=browser.new_context(viewport={'width':1280,'height':800});install(c,'readonly');p=c.new_page();p.set_default_timeout(4500);p.on('pageerror',lambda e:errors.append(str(e)));launch_page(p,c);p.wait_for_selector('#title');p.wait_for_function('()=>document.querySelector("#connection")?.textContent.includes("연결됨")');go(p,'equipment')
  check('equipment reader sees no new/edit/import',p.locator('[data-vaction=newMaster],[data-vaction=editMaster],[data-vaction=importMaster]').count()==0)
  go(p,'instruments');check('instrument reader sees no new/edit/import',p.locator('[data-vaction=newMaster],[data-vaction=editMaster],[data-vaction=importMaster]').count()==0)
  go(p,'instructions');p.locator('[data-vaction=routeDetail]').first.click();p.wait_for_selector('#v4dialog[open]');check('instruction reader cannot assign or release',p.locator('#v4dialog [data-vaction=assign],#v4dialog [data-vaction=release]').count()==0);c.close()
  check('all scenarios zero JS errors',not errors)
  check('navigation did not mutate business data',not mutations)
 except Exception as e:
  errors.append(traceback.format_exc());
  try:p.screenshot(path=str(OUT/'failure.png'),full_page=False)
  except:pass
 finally:
  (OUT/'results.json').write_text(json.dumps(dict(passed=len(results),checks=results,errors=errors,unexpected_mutations=mutations,scope='Offline native ES module Chromium DOM harness, memory session/local storage and synthetic Supabase fetch; no production network/CSP or DB tested'),ensure_ascii=False,indent=2))
  browser.close();srv.shutdown()
print(json.dumps(dict(passed=len(results),errors=errors),ensure_ascii=False,indent=2))
if errors:raise SystemExit(1)
