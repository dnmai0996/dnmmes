"""Offline mocked-API UI test; does not claim real Supabase/Auth/Netlify verification."""
import os, json, re, posixpath, base64, subprocess, shutil
from pathlib import Path
from playwright.sync_api import sync_playwright
BASE=Path(__file__).resolve().parents[2];OUT=Path(os.environ.get('DNM_TEST_OUTPUT','/mnt/data/_dnm_v43_accounts_browser'));OUT.mkdir(parents=True,exist_ok=True)
ORIGIN='https://dnm-test.supabase.co';checks=[];errors=[]
A='00000000-0000-4000-a000-000000000001';W='00000000-0000-4000-a000-000000000002';E='00000000-0000-4000-a000-000000000011'
profiles=[dict(id=A,display_name='검수 관리자',email='admin@example.invalid',role='admin',active=True,version=1),dict(id=W,display_name='검수 작업자',email='worker@example.invalid',role='member',active=True,version=1)]
worker=dict(id=E,version=1,code='E-TEST',name='검수 작업자',department='생산팀',position='사원',hired='2020-01-01',employee_active=True,email='',profile_id=None,role=None,profile_active=False,enabled=False,state='unregistered',expires_at=None,protected=False)
perms=json.loads(subprocess.check_output(['node','--input-type=module','-e',"import {permissionPreset} from './public/modules/permissions.js';console.log(JSON.stringify(permissionPreset('worker')))"],cwd=BASE,text=True))
def check(label,value=True):
 if not value: raise AssertionError(label)
 checks.append(label)
def launch(page,who='admin'):
 html=(BASE/'public/index.html').read_text();html=re.sub(r'<script[^>]*>.*?</script>','',html);html=re.sub(r'<link[^>]+>','',html);page.set_content(html)
 for f in ['styles.css','v41.css','v42.css','navigation.css','v43.css','v44.css']:page.add_style_tag(content=(BASE/'public'/f).read_text())
 image='data:image/png;base64,'+base64.b64encode((BASE/'public/assets/dnm-logo.png').read_bytes()).decode();modules={}
 for f in (BASE/'public').rglob('*.js'):
  name=f.relative_to(BASE).as_posix();src=f.read_text().replace('assets/dnm-logo.png',image)
  def rewrite(m):return m.group(1)+'dnm:'+posixpath.normpath(posixpath.join(posixpath.dirname(name),m.group(2)))+m.group(3)
  modules['dnm:'+name]=re.sub(r"((?:from\s*|import\s*)['\"])(\.{1,2}/[^'\"]+)(['\"])",rewrite,src)
 modules['dnm:public/config.js']=f"export const SUPABASE_URL='{ORIGIN}';export const SUPABASE_PUBLIC_KEY='sb_publishable_TEST';"
 person=profiles[0 if who=='admin' else 1]
 payload=dict(modules=modules,who=who,origin=ORIGIN,profiles=profiles,worker=worker,ctx=dict(version='4.2.0',account_management='4.3.0',profile=person,permissions=perms if who!='admin' else {},capabilities=[],people=[]))
 page.on('pageerror',lambda e:errors.append(str(e)))
 page.evaluate(r'''async f=>{
  class M{constructor(){this.x={}}getItem(k){return this.x[k]??null}setItem(k,v){this.x[k]=String(v)}removeItem(k){delete this.x[k]}}
  Object.defineProperty(window,'sessionStorage',{value:new M(),configurable:true});Object.defineProperty(window,'localStorage',{value:new M(),configurable:true});
  if(!crypto.randomUUID)crypto.randomUUID=()=>{let s='';for(let i=0;i<32;i++)s+='0123456789abcdef'[Math.floor(Math.random()*16)];return s.slice(0,8)+'-'+s.slice(8,12)+'-4'+s.slice(13,16)+'-a'+s.slice(17,20)+'-'+s.slice(20)};
  window.__f=f;window.__calls=[];window.__forceError=false;
  const session=()=>({access_token:'TEST',refresh_token:'TEST',expires_at:9999999999,user:f.ctx.profile});
  if(f.who!=='login')sessionStorage.setItem('dnm-portal-session:'+f.origin,JSON.stringify(session()));
  window.fetch=async(path,o={})=>{
   const u=new URL(path,'https://dnm-test.netlify.app'),q=u.searchParams;let data=[],status=200;const h={'Content-Type':'application/json'};
   if(u.pathname==='/functions/v1/dnm-accounts'){
    const b=JSON.parse(o.body);window.__calls.push(b);
    if(window.__forceError){status=503;data={ok:false,message:'시험용 설정 실패'};}
    else if(b.action==='status')data={ok:true};
    else if(b.action==='name_temporary_login')data={ok:true,requires_password_change:true,login_id:b.login_id,ticket:'A'.repeat(43),expires_at:'2099-01-01'};
    else if(b.action==='set_initial_password')data={ok:true};
    else if(['provision','reset','disable'].includes(b.action)){
     f.worker.profile_id=f.profiles[1].id;f.worker.email='worker-'+f.worker.id+'@dnm.example';f.worker.enabled=b.action!=='disable';f.worker.state=b.action==='disable'?'disabled':'pending';f.worker.expires_at='2099-01-01T00:00:00Z';
     data={ok:true,message:'시험용 계정 처리 완료',state:f.worker.state};
    }else if(b.action==='change_password')data={ok:true};
   }else if(['/rest/v1/rpc/dnm_v47_accounts','/rest/v1/rpc/dnm_v43_accounts'].includes(u.pathname))data={version:'4.3.0',name_login:'4.7.0',workers:[f.worker]};
   else if(u.pathname==='/rest/v1/rpc/dnm_v4_context')data=f.ctx;
   else if(u.pathname==='/rest/v1/rpc/dnm_v48_set_worker_active'){const x=JSON.parse(o.body);window.__calls.push({action:'worker_state',...x});f.worker.employee_active=x.p_active;f.worker.enabled=x.p_active;data={ok:true};}
   else if(u.pathname==='/rest/v1/dnm_portal_profiles'){data=f.profiles;if(q.has('id'))data=data.filter(x=>x.id===q.get('id').slice(3));h['content-range']=`0-${data.length-1}/${data.length}`;}
   else if(u.pathname==='/rest/v1/dnm_v4_records'){data=[];h['content-range']='0-0/0';}
   else if(u.pathname.startsWith('/rest/v1/dnm_portal_')){data=[];h['content-range']='0-0/0';}
   else if(u.pathname==='/auth/v1/token')data=session();
   else if(u.pathname==='/auth/v1/logout')data={};
   else if(u.pathname==='/auth/v1/settings')data={external:{email:true}};
   else if(u.pathname==='/rest/v1/rpc/dnm_v43_my_account_status')data={managed:false,allowed:true};
   return new Response(JSON.stringify(data),{status,headers:h});
  };
  const imports={};for(const [k,v]of Object.entries(f.modules))imports[k]=URL.createObjectURL(new Blob([v],{type:'text/javascript'}));let im=document.createElement('script');im.type='importmap';im.textContent=JSON.stringify({imports});document.head.append(im);await import('dnm:public/app.js');
 }''',payload)
def accounts(page):
 if page.locator('#mobileNav').is_visible():page.click('#mobileNav')
 d=page.locator('[data-tab=profiles]').locator('xpath=ancestor::details')
 if not d.evaluate('(e)=>e.open'):d.locator('summary').click()
 page.click('[data-tab=profiles]');page.wait_for_selector('[data-account-check]')
with sync_playwright() as pw:
 b=pw.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
 try:
  p=b.new_page(viewport={'width':1440,'height':960});launch(p);accounts(p)
  check('admin worker account checkbox present',p.locator('[data-account-check]').count()==1)
  check('one worker management table',p.locator('[data-vaction=accountRole]').count()==0)
  p.click('#accountHealth');p.wait_for_function("()=>document.querySelector('#accountServiceState').textContent.includes('직원 로그인 서버에 연결')")
  check('backend health result rendered')
  p.screenshot(path=str(OUT/'admin-worker-accounts.png'),full_page=False)
  p.click('[data-vaction=accountEnroll]');p.wait_for_selector('#v4dialog[open]');check('no email required',p.locator('[name=email]').count()==0)
  p.check('#v4dialog [name=confirm_owner]');p.click('#v4submit');p.wait_for_function("()=>!document.querySelector('#v4dialog').open")
  check('registration linked by worker ID',p.evaluate("__calls.some(x=>x.action==='provision'&&x.employee_id==='"+E+"'&&x.email==='')"))
  check('pending password state shown','첫 비밀번호 설정 대기' in p.locator('#content').inner_text())
  p.click('[data-vaction=accountReset]');p.wait_for_selector('#v4dialog[open]');check('reset asks administrator current password',p.locator('[name=admin_password]').count()==1)
  check('reset needs no email input',p.locator('[name=email]').count()==0)
  p.fill('[name=reason]','본인 확인 후 초기화');p.fill('[name=admin_password]','Admin-Example-2026!');p.check('[name=confirm_owner]');p.click('#v4submit');p.wait_for_function("()=>!document.querySelector('#v4dialog').open")
  check('reset is explicit server action',p.evaluate("__calls.some(x=>x.action==='reset')"))
  p.click('[data-account-check]');p.wait_for_selector('#v4dialog[open]');check('disable confirmation preserves work data','보존' in p.locator('#v4dialog').inner_text())
  p.fill('[name=reason]','사용 중지 승인');p.click('#v4submit');p.wait_for_function("()=>!document.querySelector('#v4dialog').open")
  check('account disable not deletion',p.evaluate("__calls.some(x=>x.action==='worker_state'&&x.p_active===false)"))
  p.click('#password');p.wait_for_selector('#editor[open]');p.fill('#editor [name=current]','Current123456!');p.fill('#editor [name=next]','New-Password-2026!');p.fill('#editor [name=repeat]','New-Password-2026!');p.click('#save');p.wait_for_selector('#loginForm');check('self-change returns to login','비밀번호가 변경' in p.locator('#message').inner_text());p.close()
  p=b.new_page(viewport={'width':1440,'height':900});launch(p,'worker');p.wait_for_selector('#title');check('worker cannot see account management menu',p.locator('[data-tab=profiles]').count()==0);check('worker has password change button',p.locator('#password').count()==1);p.close()
  for width in [320,360,390]:
   p=b.new_page(viewport={'width':width,'height':860});launch(p,'login');p.wait_for_selector('#loginForm');p.fill('#loginForm [name=login_id]','검수 작업자');p.fill('#loginForm [name=password]','1111');p.click('#loginForm button');p.wait_for_selector('#initialPasswordForm')
   check(f'{width}: no business nav before personal password',p.locator('#sideMenu').count()==0)
   check(f'{width}: bootstrap flow stores no session',p.evaluate('sessionStorage.getItem("dnm-portal-session:"+__f.origin)') is None)
   check(f'{width}: no horizontal page overflow',p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'))
   if width==360:p.screenshot(path=str(OUT/'first-password-mobile-360.png'),full_page=False)
   p.fill('#initialPasswordForm [name=password]','New-Password-2026!');p.fill('#initialPasswordForm [name=repeat]','Different-2026!');p.click('#initialPasswordForm button[type=submit]');check(f'{width}: mismatch rejected','확인값이 다릅니다' in p.locator('#message').inner_text())
   if width==360:p.screenshot(path=str(OUT/'password-mismatch-mobile-360.png'),full_page=False)
   p.fill('#initialPasswordForm [name=repeat]','New-Password-2026!');p.click('#initialPasswordForm button[type=submit]');p.wait_for_selector('#loginForm')
   check(f'{width}: setup success requires new personal login','비밀번호를 설정했습니다' in p.locator('#message').inner_text())
   check(f'{width}: initialization never sends 1111 to Auth token endpoint',p.evaluate('__calls.filter(x=>x.action==="name_temporary_login").length')==1)
   p.close()
  p=b.new_page(viewport={'width':360,'height':860});launch(p);accounts(p);check('mobile account list page has no horizontal overflow',p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'));p.screenshot(path=str(OUT/'admin-accounts-mobile-360.png'),full_page=False);p.close()
  check('no browser JavaScript errors',not errors)
 finally:
  (OUT/'result.json').write_text(json.dumps({'passed':len(checks),'checks':checks,'errors':errors,'mode':'Offline mocked HTTP API; no actual Supabase or Netlify service'},ensure_ascii=False,indent=2));b.close()
print(json.dumps({'passed':len(checks),'errors':errors},ensure_ascii=False,indent=2))
