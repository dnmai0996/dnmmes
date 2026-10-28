"""Browser flow test with mocked API and local cryptography bridge. No live Supabase or native browser WebCrypto validation."""
import os,json,uuid,hashlib,mimetypes,time,shutil,re,posixpath,base64
from types import SimpleNamespace
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pathlib import Path
from urllib.parse import urlparse,parse_qs
from playwright.sync_api import sync_playwright
BASE=Path(__file__).resolve().parents[2];OUT=Path(os.environ.get('DNM_TEST_OUTPUT','/mnt/data/_dnm_v44_browser'));OUT.mkdir(parents=True,exist_ok=True)
SITE='https://dnm-test.netlify.app';DB='https://dnm-test.supabase.co';A='11111111-1111-4111-8111-111111111111';INSTANCE=str(uuid.uuid4());CHECKS=[];ERRORS=[]
NAMES=['profiles','products','partners','notes','records','permissions','module_access','requests','audit'];JOBS={};restore_calls=[]
profile={'id':A,'email':'admin@example.invalid','role':'admin','active':True,'display_name':'검수 관리자','version':1}
ctx={'version':'4.2.0','account_management':'4.3.0','backup_management':'4.4.0','profile':profile,'permissions':{},'capabilities':[],'people':[]}
def check(n,cond=True):
 assert cond,n
 CHECKS.append(n);print('PASS',len(CHECKS),n,flush=True);(OUT/'progress.json').write_text(json.dumps({'checks':CHECKS,'errors':ERRORS},ensure_ascii=False))
def h(s):return hashlib.sha256(s.encode()).hexdigest()
def fixture():
 collections={n:[] for n in NAMES}
 values=[('profiles',A,profile),('products',str(uuid.uuid4()),{'code':'TEST-001','name':'가상 부싱'})]
 for n,k,d in values:
  t=json.dumps(d,ensure_ascii=False,separators=(',',':'));collections[n].append({'key':k,'row_json':t,'sha256':h(t)})
 for i in range(121):
  k=f'{i:032x}';d={'id':k,'kind':'material','code':f'TEST-{i:03}','title':'가상 시험자료','data':{'qty':i}};t=json.dumps(d,ensure_ascii=False,separators=(',',':'));collections['records'].append({'key':k,'row_json':t,'sha256':h(t)})
 return collections
COLLECTIONS=fixture()
def manifest(id):return {'format':'dnm-business-snapshot-v44','schema_version':'4.4.0','backup_id':id,'instance_id':INSTANCE,'captured_at':'2026-10-29T00:15:30Z','scope':'all_dnm_business_tables','collections':[{'name':n,'count':len(COLLECTIONS[n]),'sha256':h('\n'.join(r['key']+':'+r['sha256'] for r in sorted(COLLECTIONS[n],key=lambda r:r['key']))),'restore_mode':'replace' if n not in ['profiles','audit'] else 'security_preserved' if n=='profiles' else 'append_only'} for n in NAMES]}
FAIL=False;DELAY=False

def fulfill(route):
 global FAIL
 req=route.request;u=urlparse(req.url);path=u.path;q=parse_qs(u.query);data=[];status=200;headers={'Content-Type':'application/json'}
 if u.hostname=='dnm-test.netlify.app' and not path.startswith('/.netlify/'):
  if path=='/config.js':return route.fulfill(body=f"export const SUPABASE_URL='{DB}';export const SUPABASE_PUBLIC_KEY='sb_publishable_TEST_ONLY';",content_type='text/javascript')
  f=BASE/'public'/('index.html' if path=='/' else path.lstrip('/'))
  if f.is_file():return route.fulfill(body=f.read_bytes(),content_type=mimetypes.guess_type(str(f))[0] or 'application/octet-stream')
  return route.fulfill(status=404,body='Not found')
 if path=='/rest/v1/rpc/dnm_v4_context':data=ctx
 elif path=='/rest/v1/dnm_portal_profiles':data=[profile];headers['Content-Range']='0-0/1'
 elif path in ['/rest/v1/rpc/dnm_v43_my_account_status']:data={'allowed':True,'managed':False}
 elif path=='/rest/v1/rpc/dnm_v44_backup_api':
  p=json.loads(req.post_data);action=p['p_action'];p=p['p'];id=p.get('id');j=JOBS.get(id)
  if action=='history':data={'ok':True,'items':[dict(v,collections=v.get('manifest',{}).get('collections',[])) for v in JOBS.values() if v['status'] in ['ready','applied']]}
  elif action=='status':data={'ok':True,'version':'4.4.0','busy':False,'instance_id':INSTANCE}
  elif action=='begin':
   j={'id':id,'status':'building','job_type':'backup','purpose':p.get('purpose','normal'),'safety_for':p.get('safety_for'),'snapshot_at':'2026-10-29T00:15:30Z','manifest':manifest(id),'progress':{'records':{'count':0,'total':123}}};JOBS[id]=j;data=j
  elif action=='step':
   if DELAY:time.sleep(.25)
   if FAIL:status=500;data={'code':'57014','message':'canceling statement due to statement timeout'};FAIL=False
   else:
    j['progress']['records']['count']=min(123,j['progress']['records']['count']+40)
    if j['progress']['records']['count']>=123:j['status']='ready'
    data=j
  elif action=='cancel':
   if j:j['status']='cancelled'
   data={'ok':True}
  elif action=='inspect':data=j
  elif action=='read':data={'rows':[r for r in COLLECTIONS[p['collection']] if r['key']>p.get('after','')][:50]}
  elif action=='stage_begin':
   j={'id':id,'status':'staging','job_type':'restore','purpose':'restore','manifest':p['manifest'],'snapshot_at':'2026-10-29T00:16:00Z'};JOBS[id]=j;data=j
  elif action=='stage_rows':data={'ok':True,'count':len(p['rows'])}
  elif action=='stage_verify':j['status']='validated';data=j
  elif action=='ack_file':j['ack_at']='2026-10-29T00:16:00Z';data={'ok':True}
 elif path=='/.netlify/functions/dnm-backups':
  p=json.loads(req.post_data);restore_calls.append(p);j=JOBS[p['stage_id']];j['status']='applied';j['applied_at']='2026-10-29T00:17:00Z';data={'ok':True,'applied':True,'relogin_required':True}
 elif path=='/auth/v1/token':data={'access_token':'TEST','refresh_token':'TEST','expires_at':9999999999,'user':profile}
 elif path.startswith('/rest/v1/'):
  data=[];headers['Content-Range']='0-0/0'
 elif path=='/auth/v1/settings':data={'external':{'email':True}}
 else:data={}
 route.fulfill(status=status,body=json.dumps(data,ensure_ascii=False),headers=headers)
def service_bridge(arg):
 class Route:
  request=SimpleNamespace(url=arg['url'],post_data=arg.get('body'))
  result=None
  def fulfill(self,**kwargs):self.result=kwargs
 r=Route();fulfill(r);return r.result

def crypto_bridge(p):
 op=p['op'];data=bytes(p.get('data',[]))
 if op=='digest':return list(hashlib.sha256(data).digest())
 if op=='derive':return list(hashlib.pbkdf2_hmac('sha256',bytes(p['password']),bytes(p['salt']),p['iterations'],dklen=32))
 aes=AESGCM(bytes(p['key']));iv=bytes(p['iv']);aad=bytes(p['aad'])
 return list(aes.encrypt(iv,data,aad) if op=='encrypt' else aes.decrypt(iv,data,aad))

def launch(browser,width=1440):
 print('LAUNCH',width,flush=True)
 c=browser.new_context(viewport={'width':width,'height':1000},accept_downloads=True);p=c.new_page();p.set_default_timeout(10000);p.on('pageerror',lambda e:ERRORS.append(str(e)))
 print('bindings',flush=True);p.expose_function('__serviceBridge',service_bridge);p.expose_function('__cryptoBridge',crypto_bridge)
 html=(BASE/'public/index.html').read_text();html=re.sub(r'<script[^>]*>.*?</script>','',html);html=re.sub(r'<link[^>]+>','',html);p.set_content(html)
 for css in ['styles.css','v41.css','v42.css','navigation.css','v43.css','v44.css']:p.add_style_tag(content=(BASE/'public'/css).read_text())
 modules={};image='data:image/png;base64,'+base64.b64encode((BASE/'public/assets/dnm-logo.png').read_bytes()).decode()
 for f in (BASE/'public').rglob('*.js'):
  name=f.relative_to(BASE).as_posix();src=f.read_text().replace('assets/dnm-logo.png',image)
  def rewrite(m):return m.group(1)+'dnm:'+posixpath.normpath(posixpath.join(posixpath.dirname(name),m.group(2)))+m.group(3)
  modules['dnm:'+name]=re.sub(r"((?:from\s*|import\s*)['\"])(\.{1,2}/[^'\"]+)(['\"])",rewrite,src)
 modules['dnm:public/config.js']=f"export const SUPABASE_URL='{DB}';export const SUPABASE_PUBLIC_KEY='sb_publishable_TEST_ONLY';"
 payload={'modules':modules,'origin':DB,'session':{'access_token':'TEST','refresh_token':'TEST','expires_at':9999999999,'user':profile}}
 print('evaluate app',flush=True)
 p.evaluate(r'''async f=>{
  class Storage{constructor(){this.v={}}getItem(k){return this.v[k]??null}setItem(k,v){this.v[k]=String(v)}removeItem(k){delete this.v[k]}}
  Object.defineProperty(window,'sessionStorage',{value:new Storage(),configurable:true});Object.defineProperty(window,'localStorage',{value:new Storage(),configurable:true});sessionStorage.setItem('dnm-portal-session:'+f.origin,JSON.stringify(f.session));
  const arr=x=>Array.from(new Uint8Array(x));
  // Managed test browser blocks navigation. Use real AES/PBKDF from a local test bridge.
  Object.defineProperty(crypto,'subtle',{value:{
   digest:async(_,d)=>new Uint8Array(await __cryptoBridge({op:'digest',data:arr(d)})).buffer,
   importKey:async(_,d)=>({password:arr(d)}),
   deriveKey:async(a,m)=>new Uint8Array(await __cryptoBridge({op:'derive',password:m.password,salt:arr(a.salt),iterations:a.iterations})),
   encrypt:async(a,k,d)=>new Uint8Array(await __cryptoBridge({op:'encrypt',key:arr(k),iv:arr(a.iv),aad:arr(a.additionalData),data:arr(d)})).buffer,
   decrypt:async(a,k,d)=>new Uint8Array(await __cryptoBridge({op:'decrypt',key:arr(k),iv:arr(a.iv),aad:arr(a.additionalData),data:arr(d)})).buffer
  },configurable:true});
  if(!crypto.randomUUID)crypto.randomUUID=()=>{const b=crypto.getRandomValues(new Uint8Array(16));b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;const h=arr(b).map(x=>x.toString(16).padStart(2,'0')).join('');return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20)};
  window.fetch=async(url,o={})=>{const x=await __serviceBridge({url:new URL(url,'https://dnm-test.netlify.app').href,body:o.body||null});return new Response(x.body,{status:x.status||200,headers:x.headers||{'Content-Type':'application/json'}})};
  const blobs=new Map(),orig=URL.createObjectURL.bind(URL);URL.createObjectURL=b=>{const u=orig(b);blobs.set(u,b);return u};window.__downloads=[];
  const nativeClick=HTMLAnchorElement.prototype.click;HTMLAnchorElement.prototype.click=function(){if(this.download&&blobs.has(this.href)){const name=this.download;blobs.get(this.href).text().then(text=>__downloads.push({name,text}));return}return nativeClick.call(this)};
  const imports={};for(const[k,v]of Object.entries(f.modules))imports[k]=URL.createObjectURL(new Blob([v],{type:'text/javascript'}));const im=document.createElement('script');im.type='importmap';im.textContent=JSON.stringify({imports});document.head.append(im);await import('dnm:public/app.js');
 }''',payload)
 print('import completed',flush=True)
 p.wait_for_selector('#sideMenu',state='attached')
 if width<1000:
  print('open mobile',flush=True);p.click('#mobileNav')
 print('select menu',flush=True)
 loc=p.locator('[data-tab=backup]');parent=loc.locator('xpath=ancestor::details');parent.locator('summary').click() if not parent.evaluate('(e)=>e.open') else None
 loc.click();p.wait_for_selector('#createBackupForm');return c,p
with sync_playwright() as pw:
 browser=pw.chromium.launch(executable_path=shutil.which('chromium'),headless=True,args=['--no-sandbox'])
 try:
  c,p=launch(browser);check('test crypto bridge installed',p.evaluate('!!crypto.subtle'))
  body=p.locator('#content').inner_text();check('normal page no backend brand',all(x not in body for x in ['Supabase','PostgreSQL','Netlify','MySQL','서버 버전','RPC']))
  check('old one-shot JSON backup removed',p.get_by_text('업무 JSON 백업',exact=True).count()==0)
  p.screenshot(path=str(OUT/'backup-desktop.png'),full_page=True)
  p.fill('#createBackupForm [name=password]','Backup-Example-2026!');p.fill('#createBackupForm [name=repeat]','Different-Example-2026!');p.click('#createBackupForm button[type=submit]');p.wait_for_function("document.querySelector('#backupNotice').textContent.includes('확인값')");check('file password mismatch rejected')
  p.fill('#createBackupForm [name=repeat]','Backup-Example-2026!');DELAY=True
  p.click('#createBackupForm button[type=submit]');p.wait_for_selector('body.dnm-working');check('waiting cursor',p.evaluate("getComputedStyle(document.body).cursor")=='progress');check('button disabled during work',p.locator('#createBackupForm button').is_disabled());check('progress visible',p.locator('#backupProgress').is_visible());p.screenshot(path=str(OUT/'backup-progress.png'),full_page=False)
  p.wait_for_function('__downloads.length===1');file=p.evaluate('__downloads[0]');filepath=OUT/file['name'];filepath.write_text(file['text']);DELAY=False;p.wait_for_function("!document.body.classList.contains('dnm-working')")
  check('timestamp filename',re.match(r'20261029_091530_KST_DNM_업무전체_.+\.dnmbak',file['name']));check('encrypted file no row data','가상 시험자료' not in filepath.read_text());check('controls restored',p.locator('#createBackupForm button').is_enabled())
  p.locator('#restoreFileForm [name=file]').set_input_files(str(filepath));p.fill('#restoreFileForm [name=password]','Wrong-Password-2026!');p.click('#restoreFileForm button');p.wait_for_function("document.querySelector('#backupNotice').textContent.includes('비밀번호가 다르거나')");check('wrong restore password rejected')
  p.fill('#restoreFileForm [name=password]','Backup-Example-2026!');p.click('#restoreFileForm button');p.wait_for_selector('#makeSafety');check('stage validation does not restore',not restore_calls);check('restore disabled without safety copy',p.locator('#applyRestore').is_disabled())
  p.click('#makeSafety');p.wait_for_function('__downloads.length===2');safe=p.evaluate('__downloads[1]');safepath=OUT/safe['name'];safepath.write_text(safe['text']);p.wait_for_function("!document.body.classList.contains('dnm-working')");check('safety file name', '복원전_안전' in safe['name'])
  p.locator('#checkSafetyFile').set_input_files(str(filepath));p.wait_for_function("document.querySelector('#backupNotice').textContent.includes('방금 내려받은')");check('reject wrong safety file',p.locator('#applyRestore').is_disabled())
  p.locator('#checkSafetyFile').set_input_files(str(safepath));p.wait_for_function("!document.querySelector('#applyRestore').disabled");check('safety reselect unlocks restore');p.screenshot(path=str(OUT/'restore-ready.png'),full_page=True)
  p.fill('#applyRestoreForm [name=reason]','시험 입력 오류 복원');p.fill('#applyRestoreForm [name=confirmation]','틀린문구');p.fill('#applyRestoreForm [name=password]','Admin-Example-2026!');p.check('#applyRestoreForm [name=confirm]');p.click('#applyRestore');p.wait_for_function("document.querySelector('#backupNotice').textContent.includes('확인문구')");check('typed confirmation required',not restore_calls)
  p.fill('#applyRestoreForm [name=confirmation]','백업시점복원');p.click('#applyRestore');p.wait_for_selector('#afterRestoreLogin');check('restore reached server once',len(restore_calls)==1);check('local session cleared',p.evaluate('sessionStorage.getItem('+json.dumps('dnm-portal-session:'+DB)+')') in [None,'null']);p.screenshot(path=str(OUT/'restore-success.png'));print('CLOSING SUCCESS',flush=True);c.close();print('CLOSED',flush=True)
  for width in [320,360,390,768,1440]:
   c,p=launch(browser,width);check(str(width)+' no page horizontal overflow',p.evaluate('document.documentElement.scrollWidth<=innerWidth+1'));p.click('#backupHelp');p.wait_for_selector('#v4dialog[open]');check(str(width)+' help shows manuals',p.locator('a[href="manuals/admin.html"]').count()==1);check(str(width)+' technical help collapsed',not p.locator('.help-technical').first.evaluate('(e)=>e.open'))
   if width==360:p.screenshot(path=str(OUT/'help-mobile.png'))
   p.click('#v4cancel')
   if width==360:p.screenshot(path=str(OUT/'backup-mobile.png'),full_page=True)
   c.close()
  c,p=launch(browser);FAIL=True;p.fill('#createBackupForm [name=password]','Backup-Example-2026!');p.fill('#createBackupForm [name=repeat]','Backup-Example-2026!');p.click('#createBackupForm button[type=submit]');p.wait_for_function("!document.querySelector('#backupNotice').hidden");check('timeout technical words hidden','statement timeout' not in p.locator('#backupNotice').inner_text());check('spinner ends after failure',not p.locator('body').evaluate('(e)=>e.classList.contains("dnm-working")'));check('failed snapshot not ready',list(JOBS.values())[-1]['status']=='cancelled');c.close()
  check('no browser JS errors',not ERRORS)
 except Exception:
  try:p.screenshot(path=str(OUT/'failure.png'),full_page=True)
  except:pass
  raise
 finally:
  (OUT/'result.json').write_text(json.dumps({'passed':len(CHECKS),'checks':CHECKS,'errors':ERRORS,'mode':'Mock API + local crypto test bridge; NOT live Supabase or native browser WebCrypto'},ensure_ascii=False,indent=2));browser.close()
print('PASS',len(CHECKS))
