"""Offline visual name-login smoke test. Fake Supabase & fake Netlify; NEVER live data."""
from pathlib import Path
import json, re, base64, posixpath, os, tempfile
from playwright.sync_api import sync_playwright
BASE=Path(__file__).resolve().parents[2]
OUT=Path(os.environ.get('DNM_TEST_OUTPUT',tempfile.mkdtemp(prefix='dnm-v47-name-')));OUT.mkdir(parents=True,exist_ok=True)
ORIGIN='https://dnm-test.supabase.co';UID='00000000-0000-4000-a000-000000000002';errors=[];reports=[]
modules={}
for p in (BASE/'public').rglob('*.js'):
 src=p.read_text(encoding='utf-8'); name=p.relative_to(BASE).as_posix()
 def rewrite(m):
  target=posixpath.normpath(posixpath.join(posixpath.dirname(name),m.group(2)))
  return m.group(1)+'dnm:'+target+m.group(3)
 src=re.sub(r"((?:from\s*|import\s*)['\"])(\.{1,2}/[^'\"]+)(['\"])",rewrite,src)
 modules['dnm:'+name]=src
modules['dnm:public/config.js']=f"export const SUPABASE_URL='{ORIGIN}';export const SUPABASE_PUBLIC_KEY='sb_publishable_TEST_ONLY';"
html=(BASE/'public/index.html').read_text(encoding='utf-8')
html=re.sub(r'<script[^>]*>.*?</script>','',html)
html=re.sub(r'<link[^>]+>','',html)
image='data:image/png;base64,'+base64.b64encode((BASE/'public/assets/dnm-logo.png').read_bytes()).decode()
for name,src in list(modules.items()):modules[name]=src.replace('assets/dnm-logo.png',image)
ctx=dict(version='4.2.0',account_management='4.3.0',profile=dict(id=UID,active=True,role='member',display_name='검수 작업자',email='worker@example.invalid',version=1),capabilities=[],permissions={'worklogs':{'read':True,'create':True,'update':True,'scope':'own'},'notes':{'read':True,'create':False,'update':False,'scope':'own'}},people=[])
def check(label,value):
 if not value:raise AssertionError(label)
 reports.append(label)
with sync_playwright() as pw:
 browser=pw.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 for label,width,height in [('desktop',1366,900),('mobile',360,780)]:
  browser_context=browser.new_context(viewport={'width':width,'height':height})
  page=browser_context.new_page();page.on('pageerror',lambda e:errors.append(str(e)))
  page.set_content(html)
  for file in ['styles.css','v41.css','v42.css','navigation.css','v43.css','v44.css','v46.css']:
   page.add_style_tag(content=(BASE/'public'/file).read_text(encoding='utf-8'))
  payload=dict(modules=modules,context=ctx,login='검수 작업자',user=ctx['profile'])
  page.evaluate(r'''async a=>{
   class Mem{constructor(){this.v={};}getItem(x){return this.v[x]||null;}setItem(x,y){this.v[x]=String(y);}removeItem(x){delete this.v[x];}}
   Object.defineProperty(window,'sessionStorage',{value:new Mem(),configurable:true});
   Object.defineProperty(window,'localStorage',{value:new Mem(),configurable:true});
   window.__requests=[];
   window.fetch=async(input,opts={})=>{
    const u=new URL(input,'https://dnm-test.netlify.app'),path=u.pathname;
    let data={},status=200;
    if(path==='/.netlify/functions/dnm-accounts'){
     const b=JSON.parse(opts.body||'{}');window.__requests.push({action:b.action,login_id:b.login_id});
     if(b.action==='name_login')data={ok:true,session:{access_token:'worker-token',refresh_token:'worker-refresh',expires_at:9999999999,user:{id:a.user.id}}};
     else if(b.action==='name_temporary_login')data={ok:true,requires_password_change:true,ticket:'x'.repeat(43),login_id:a.login,expires_at:'2099-01-01'};
     else{status=400;data={ok:false,message:'UNSUPPORTED_MOCK_ACTION'};}
    }else if(path==='/rest/v1/dnm_portal_profiles')data=[a.user];
    else if(path==='/rest/v1/rpc/dnm_v4_context')data=a.context;
    else if(path==='/rest/v1/dnm_v4_records')data=[];
    else if(path==='/auth/v1/token')data={access_token:'email-token',refresh_token:'email-refresh',expires_at:9999999999,user:{id:a.user.id}};
    else if(path==='/auth/v1/settings')data={external:{email:true}};
    else if(path==='/auth/v1/logout')data={};
    else data=[];
    return new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','content-range':'0-0/1'}});
   };
   const imports={};for(const [name,src] of Object.entries(a.modules))imports[name]=URL.createObjectURL(new Blob([src],{type:'text/javascript'}));
   const map=document.createElement('script');map.type='importmap';map.textContent=JSON.stringify({imports});document.head.append(map);
   await import('dnm:public/app.js');
  }''',payload)
  page.locator('input[name="login_id"]').wait_for(timeout=10000)
  check(label+' name login label','작업자 이름' in page.locator('.loginbox').inner_text())
  check(label+' input free text',page.locator('input[name="login_id"]').get_attribute('type')=='text')
  page.screenshot(path=str(OUT/f'{label}-login.png'),full_page=True)
  page.locator('input[name="login_id"]').fill('검수 작업자')
  page.locator('input[name="password"]').fill('1111')
  page.locator('#loginForm button').click()
  page.locator('#initialPasswordForm').wait_for(timeout=12000)
  check(label+' initial setup uses name','검수 작업자' in page.locator('.password-setup').inner_text())
  page.screenshot(path=str(OUT/f'{label}-initial.png'),full_page=True)
  page.locator('#cancelInitialPassword').click()
  page.locator('input[name="login_id"]').fill('검수 작업자')
  page.locator('input[name="password"]').fill('Worker-2026-Personal!')
  page.locator('#loginForm button').click()
  page.locator('.app-shell').wait_for(timeout=12000)
  check(label+' app opened', '검수 작업자' in page.locator('.topbar').inner_text())
  calls=page.evaluate('window.__requests');check(label+' both server actions',[c['action'] for c in calls]==['name_temporary_login','name_login'])
  page.screenshot(path=str(OUT/f'{label}-logged-in.png'),full_page=True)
  browser_context.close()
 # Existing administrator email login must still work without name-mapping calls.
 admin_user={'id':'00000000-0000-4000-a000-000000000001','display_name':'검수 관리자','email':'admin@example.invalid','role':'admin','active':True,'version':1}
 admin_ctx=dict(ctx);admin_ctx['profile']=admin_user;admin_ctx['permissions']={}
 bctx=browser.new_context(viewport={'width':1366,'height':900});page=bctx.new_page();page.on('pageerror',lambda e:errors.append(str(e)))
 page.set_content(html)
 for file in ['styles.css','v41.css','v42.css','navigation.css','v43.css','v44.css','v46.css']:page.add_style_tag(content=(BASE/'public'/file).read_text(encoding='utf-8'))
 page.evaluate(r'''async a=>{
  class Mem{constructor(){this.v={};}getItem(x){return this.v[x]||null;}setItem(x,y){this.v[x]=String(y);}removeItem(x){delete this.v[x];}}
  Object.defineProperty(window,'sessionStorage',{value:new Mem(),configurable:true});Object.defineProperty(window,'localStorage',{value:new Mem(),configurable:true});window.__requests=[];
  window.fetch=async(input,opts={})=>{
   const path=new URL(input,'https://dnm-test.netlify.app').pathname;let data=[];
   if(path==='/auth/v1/token')data={access_token:'admin-token',refresh_token:'admin-refresh',expires_at:9999999999,user:{id:a.user.id}};
   else if(path==='/rest/v1/dnm_portal_profiles')data=[a.user];
   else if(path==='/rest/v1/rpc/dnm_v4_context')data=a.context;
   else if(path==='/auth/v1/settings')data={external:{email:true}};
   else if(path==='/.netlify/functions/dnm-accounts')window.__requests.push(path);
   return new Response(JSON.stringify(data),{status:200,headers:{'content-range':'0-0/1','Content-Type':'application/json'}});
  };
  const imports={};for(const [name,src] of Object.entries(a.modules))imports[name]=URL.createObjectURL(new Blob([src],{type:'text/javascript'}));
  const map=document.createElement('script');map.type='importmap';map.textContent=JSON.stringify({imports});document.head.append(map);await import('dnm:public/app.js');
 }''',dict(modules=modules,context=admin_ctx,user=admin_user))
 page.locator('input[name="login_id"]').fill('admin@example.invalid');page.locator('input[name="password"]').fill('Admin-2026-Personal!');page.locator('#loginForm button').click();page.locator('.app-shell').wait_for(timeout=12000)
 check('administrator email login retained','검수 관리자' in page.locator('.topbar').inner_text())
 check('administrator bypasses worker name lookup',page.evaluate('window.__requests.length===0'))
 page.screenshot(path=str(OUT/'admin-email-logged-in.png'),full_page=True)
 bctx.close()
 browser.close()
assert not errors,errors
(OUT/'results.json').write_text(json.dumps({'passed':len(reports),'checks':reports,'errors':errors},ensure_ascii=False,indent=2),encoding='utf-8')
print('BROWSER OK',len(reports),'checks, output',OUT)
