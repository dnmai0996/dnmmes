"""DNM source-grounded initial data. Stdlib XML cached values only; no macros/OCR."""
from pathlib import Path
from collections import defaultdict,Counter
from datetime import datetime,timedelta
import json,re,hashlib,zipfile,xml.etree.ElementTree as ET
import argparse,sys
from xlsx_to_dnm_json import convert
parser=argparse.ArgumentParser(description='원본 10개 Excel/XLSM을 로컬 PRIVATE 기준정보로 변환; 매크로 실행 없음')
parser.add_argument('source_directory');parser.add_argument('private_output_directory')
args=parser.parse_args();ROOT=Path(args.source_directory).resolve();W=Path(args.private_output_directory).resolve();OUT=W
if not ROOT.is_dir():raise SystemExit('원본 폴더가 없습니다.')
if W==ROOT or W.name.lower()=='public':raise SystemExit('출력은 원본과 별도의 비공개 폴더를 선택하세요.')
W.mkdir(parents=True,exist_ok=True)
if (OUT/'DNM_v42_MasterData_PRIVATE.dnm.json').exists():raise SystemExit('기존 출력 보존: 다른 출력 폴더명을 사용하세요.')
BOOK={};FILES={};ISSUES=[];rows=[];arch=[];SOURCE_ROWS=[]
def load(name,key):
 d=convert(str(ROOT/name)); BOOK[key]=d;FILES[key]={'file':name,'sha256':hashlib.sha256((ROOT/name).read_bytes()).hexdigest()};return d
for k,f in [('P','PARTS_MASTER_DNM(2).xlsx'),('E','설비MASTER_AI(2).xlsx'),('EM','설비(민수)별 작업자 파악현황_Copied[00](2).xlsx'),('ED','설비(방산)별 작업자 파악현황_Copied[00](2).xlsx'),('H','한화 제품별 공정순서도_Copied[00](2).xlsx'),('F','부싱방산품공정도(3).xlsx'),('O','수주자료_20261027110753(2).xlsx'),('T','공구업체,품목_(주)디엔엠(3).xlsx'),('W','근로자명부2026(1).xlsx'),('R','라우팅,품질보증서,시험성적서 통합 양식(1).xlsm')]:load(f,k)
def s(v):return str(v if v is not None else '').strip()
def at(r,i):return r['values'][i] if i<len(r['values']) else ''
def ref(key,sh,r):return {'file_id':key,'sheet':sh,'row':r if isinstance(r,int) else r['rowNo']}
def token(prefix,*v):return prefix+hashlib.sha256('|'.join(map(str,v)).encode()).hexdigest()[:16].upper()
def date(v):
 if v in ('',None):return ''
 if isinstance(v,(float,int)):
  return (datetime(1899,12,30)+timedelta(days=int(v))).date().isoformat()
 t=s(v).replace('.','-').replace('/','-').strip('-')
 try:return datetime.strptime(t,'%Y-%m-%d').date().isoformat()
 except:return ''
def issue(kind,code,msg,refs,level='확인'):ISSUES.append({'kind':kind,'code':code,'issue':msg,'sources':refs,'level':level})
def add(kind,code,title,data,source,status='REVIEW'):
 row={'kind':kind,'code':s(code),'title':s(title),'state':status,'data':{**data,'sources':source,'seed_origin':'DNM-SOURCES-20261028-v42'}};rows.append(row);return row
# exact merged-cell lookup (no unrestricted forward fill)
def merged(key,sheet,col,row):
 f=ROOT/FILES[key]['file'];NS='{http://schemas.openxmlformats.org/spreadsheetml/2006/main}';R='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
 if (key,sheet) not in merged.cache:
  with zipfile.ZipFile(f) as z:
   book=ET.fromstring(z.read('xl/workbook.xml'));rel={e.attrib['Id']:e.attrib['Target'] for e in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
   sh=next(e for e in book.iter(NS+'sheet') if e.attrib['name']==sheet);pth=rel[sh.attrib[R+'id']];pth=pth.lstrip('/') if pth.startswith('/') else 'xl/'+pth
   root=ET.fromstring(z.read(pth));merged.cache[key,sheet]=[e.attrib['ref'] for e in root.iter(NS+'mergeCell')]
 letter='';n=col+1
 while n: n,x=divmod(n-1,26);letter=chr(65+x)+letter
 for area in merged.cache[key,sheet]:
  m=re.fullmatch(r'([A-Z]+)(\d+):([A-Z]+)(\d+)',area)
  if m and m[1]==m[3]==letter and int(m[2])<=row<=int(m[4]):
   rr=next((r for sh in BOOK[key]['sheets'] if sh['name']==sheet for r in sh['rows'] if r['rowNo']==int(m[2])),None)
   return at(rr,col) if rr else ''
 return ''
merged.cache={}
# Preserve displayed operation numbers such as numeric 15 with Excel format 000 -> 015.
# Keep the raw stored value as well; never apply arbitrary zero-padding without a source format.
def formatted_code(key,sheet,address,value):
 if key not in formatted_code.cache:
  with zipfile.ZipFile(ROOT/FILES[key]['file']) as z:
   N='{http://schemas.openxmlformats.org/spreadsheetml/2006/main}';R='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
   sty=ET.fromstring(z.read('xl/styles.xml'));fmts={int(n.attrib['numFmtId']):n.attrib['formatCode'] for n in sty.iter(N+'numFmt')};xf=list(sty.find(N+'cellXfs'))
   rel={n.attrib['Id']:n.attrib['Target'] for n in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))};out={}
   for sh in ET.fromstring(z.read('xl/workbook.xml')).iter(N+'sheet'):
    target=rel[sh.attrib[R+'id']];target=target.lstrip('/') if target.startswith('/') else 'xl/'+target
    d={}
    for c in ET.fromstring(z.read(target)).iter(N+'c'):
     if re.fullmatch('A[0-9]+',c.attrib.get('r','')):
      fid=int(xf[int(c.attrib.get('s',0))].attrib['numFmtId']);d[c.attrib['r']]=fmts.get(fid,'')
    out[sh.attrib['name']]=d
   formatted_code.cache[key]=out
 fmt=formatted_code.cache[key].get(sheet,{}).get(address,'');raw=s(value)
 if re.fullmatch(r'0{2,8}',fmt or '') and isinstance(value,(int,float)) and int(value)==value and value>=0:return str(int(value)).zfill(len(fmt)),fmt
 return raw,fmt
formatted_code.cache={}
# Products: exact codes only; names/REV alternatives retained. No hyphen/suffix merge.
products=defaultdict(list)
def product(code,title,project,source,priority,unit='',raw=None):
 code=s(code);title=s(title)
 if not code or code.startswith('#') or not title:return
 products[code].append({'name':title,'project':s(project),'unit':s(unit),'source':source,'priority':priority,'raw':raw or {}})
for sh in BOOK['P']['sheets']:
 for r in sh['rows']:
  if r['rowNo']<5 or not at(r,5):continue
  pr=at(r,3) or merged('P',sh['name'],3,r['rowNo']);product(at(r,5),at(r,6),pr,ref('P',sh['name'],r),0,raw={'material_spec':at(r,8),'material_supplier':at(r,13),'material_type':at(r,14),'material_size':at(r,15),'material_price':at(r,16)})
# process sheet retains ordered columns. Never use column index as actual operation number.
route_candidates=defaultdict(list)
def kind_guess(name,equipment='',inspection=''):
 if '외주' in name or '외주' in equipment:return 'OUTSOURCE'
 if '검사' in name or name in ('CMM','3차원검사'):return 'INSPECTION'
 if '입고' in name or name=='원자재':return 'MATERIAL'
 if '포장' in name or '납품' in name:return 'PACK'
 return 'WORK'
def eq_candidates(label):
 clean=s(label).upper();out=[];prefix=''
 for part in re.split(r'[,/\s]+',clean):
  m=re.fullmatch(r'([A-Z]{2,3})-?(\d{1,2})',part)
  if m:prefix=m[1];out.append(prefix+m[2].zfill(2))
  elif re.fullmatch(r'\d{1,2}',part) and prefix:out.append(prefix+part.zfill(2))
 return list(dict.fromkeys(out))
for sh in BOOK['H']['sheets']:
 for r in sh['rows']:
  if r['rowNo']<4 or not at(r,3) or not at(r,2):continue
  rawcode=s(at(r,3));code,_,rev=rawcode.partition(' / ');code=code.strip();source=ref('H',sh['name'],r);product(code,at(r,2),at(r,4),source,2,raw={'part_revision_raw':rawcode,'rev':rev})
  steps=[]
  for i in range(5,16):
   name=s(at(r,i))
   if not name or name.startswith('#'):continue
   steps.append({'seq':len(steps)+1,'code':str((len(steps)+1)*10).zfill(3),'code_generated':True,'name':name,'kind':kind_guess(name),'kind_proposed':True,'note':'','inspection_code':'','equipment_label':'','source_column':i+1,'source':source})
  if steps:route_candidates[code].append({'label':s(at(r,2)),'project':s(at(r,4)),'steps':steps,'source':source,'priority':2,'binding':'explicit_part_REV_delimiter','rev':rev,'part_revision_raw':rawcode})
rsheets={sht['name']:sht for sht in BOOK['R']['sheets']}
for r in rsheets['품명']['rows']:
 if r['rowNo']<3:continue
 rawpart=s(at(r,1));name=s(at(r,0))
 if not rawpart or rawpart.startswith('#') or not name:continue
 part,sep,rev=rawpart.partition(' / ');part=part.strip();rev=rev.strip();source=ref('R','품명',r)
 product(part,name,at(r,12),source,1,raw={'part_revision_raw':rawpart,'rev':rev,'pwi':at(r,2),'route_sheet':s(at(r,17)),'source_note':at(r,18)})
 sheetno=s(at(r,17));sh=rsheets.get(sheetno);binding='explicit_품명_순번_to_sheet'
 if not sh and sheetno.replace('-','_') in rsheets:
  original=sheetno;sheetno=sheetno.replace('-','_');sh=rsheets[sheetno];binding='sheet_separator_difference_review_required'
  issue('route_template',part,'품명 순번 '+original+'와 실제 시트 '+sheetno+'의 구분자 차이: 연결 후보 검토 필요',[source],'필수확인')
 if not sh:continue
 steps=[]
 for st in sh['rows']:
  if st['rowNo']<2 or not at(st,0) or not at(st,1):continue
  op,opfmt=formatted_code('R',sheetno,'A'+str(st['rowNo']),at(st,0));nm=s(at(st,1));eq=s(at(st,2));insp=s(at(st,4))
  if not re.fullmatch(r'[0-9A-Za-z-]+',op):continue
  steps.append({'seq':len(steps)+1,'code':op,'code_raw':at(st,0),'code_format':opfmt,'code_generated':False,'name':nm,'kind':kind_guess(nm,eq,insp),'kind_proposed':True,'note':s(at(st,3)),'inspection_code':insp if insp in ('M','I','V') else '', 'inspection_code_raw':insp,'equipment_label':eq,'equipment_candidates':eq_candidates(eq),'source':ref('R',sheetno,st)})
 if steps:
  route_candidates[part].append({'label':name,'rev':rev,'project':s(at(r,12)),'steps':steps,'source':source,'detail_sheet':sheetno,'priority':0,'binding':binding})
# current order source (not presumed live or dispatched)
order_rows=BOOK['O']['sheets'][0]['rows'];hdr=order_rows[0]['values']
def oval(r,k):
 try:return at(r,hdr.index(k))
 except ValueError:return ''
orders=[]
for r in order_rows[1:]:
 if not oval(r,'생산오더'):continue
 sr=ref('O','Sheet1',r);product(oval(r,'자재코드'),oval(r,'자재명'),oval(r,'Project내역'),sr,3,'')
 d={n:s(oval(r,k)) for n,k in [('production_no','생산오더'),('part_no','자재코드'),('part_name','자재명'),('po_no','PO 번호'),('project','Project내역'),('grade_code','등급코드'),('source_status','상태')]}
 d.update(qty=oval(r,'발주수량'),received_qty=oval(r,'입고수량'),unit_price=oval(r,'발주단가'),order_amount=oval(r,'발주금액'),order_date=date(oval(r,'발주일자')),due_date=date(oval(r,'납기일자')),customer='한화에어로스페이스(주)',customer_source='한화에어로스페이슬 발주서(2).pdf p.1 / 같은 고객 자료인지 가져오기 화면에서 확인',po_line='',priority='NORMAL',source=sr)
 orders.append({'kind':'order','code':d['production_no'],'title':d['part_name'],'state':'OPEN','data':d})
# employees: only current roster before explicit retired marker, omit all sensitive columns.
current=BOOK['W']['sheets'][0];worker_count=0
for r in current['rows']:
 if '【 퇴직자 】' in r['values']:break
 if r['rowNo']<4 or not isinstance(at(r,2),(int,float)) or not at(r,3):continue
 raw=s(at(r,3));name=re.sub(r'\s*\(2공장\)','',raw).replace('\n','').strip();h=date(at(r,11));worker_count+=1
 code=token('EMP-',name,h)
 add('employee',code,name,{'department':s(at(r,5)),'position':s(at(r,4)),'hired':h,'source_name':raw,'site':'2공장' if '(2공장)' in raw else '', 'active':False,'profile_id':'','code_generated':True,'snapshot_date':'2026-07-20','review_required':True,'verified':False},[ref('W','2026',r)])
 if not h:issue('employee',code,'입사일 미확정',[ref('W','2026',r)])
# equipment/importantly all worker cells blank - no manufactured assignments.
equipment={};instruments=[]
for sh in BOOK['E']['sheets']:
 if '설비현황' in sh['name']:
  for r in sh['rows']:
   if r['rowNo']<4 or not at(r,4) or not at(r,5):continue
   code=s(at(r,4));equipment[code]=add('equipment',code,at(r,5),{'department':s(at(r,2)),'category':s(at(r,3)),'model':s(at(r,6)),'specification':s(at(r,7)),'units':at(r,8),'manufacturer':s(at(r,9)),'worker_source':s(at(r,10)),'introduced_raw':at(r,12),'remarks':s(at(r,13)),'active':False,'verified':False,'review_required':True,'manager_id':'','processes':[]},[ref('E',sh['name'],r)])
 elif sh['name']=='계측기현황':
  for r in sh['rows']:
   if r['rowNo']<4 or not at(r,2):continue
   raw=s(at(r,3));uncertain=not raw or bool(re.search(r'다수|없음|미정|^-$',raw))
   code=raw if not uncertain else token('INST-UNVERIFIED-',sh['name'],r['rowNo'])
   ins=add('instrument',code,at(r,2),{'category':s(at(r,1)),'serial_raw':raw,'manufacturer':s(at(r,4)),'specification':s(at(r,5)),'introduced':date(at(r,6)),'calibration_due':date(at(r,7)),'active':False,'verified':False,'review_required':True,'code_generated':uncertain},[ref('E',sh['name'],r)]);instruments.append(ins)
   if uncertain:issue('instrument',code,'원본에 개별 관리번호가 없어 검토용 내부코드만 생성',[ref('E',sh['name'],r)],'필수확인')
for key in ('EM','ED'):
 for sh in BOOK[key]['sheets']:
  for r in sh['rows']:
   code=s(at(r,4))
   if code in equipment:
    equipment[code]['data']['sources'].append(ref(key,sh['name'],r))
    if at(r,10):equipment[code]['data']['worker_source']=s(at(r,10))
# tool catalog and materials, preserve exact supplier,item,spec; unit/price not invented
cat=defaultdict(list);suppliers={}
for sh in BOOK['T']['sheets']:
 supplier=s(sh['rows'][0]['values'][1]);suppliers[supplier]=ref('T',sh['name'],sh['rows'][0])
 for r in sh['rows']:
  if r['rowNo']<3 or not at(r,1):continue
  cat[(supplier,s(at(r,1)),s(at(r,2)))].append(ref('T',sh['name'],r))
for (supplier,item,spec),refs in cat.items():
 code=token('TOOL-',supplier,item,spec);d={'supplier':supplier,'item':item,'specification':spec,'unit':'','unit_price':None,'active':False,'verified':False,'review_required':True,'code_generated':True}
 add('catalog',code,item,d,refs);add('material_master',code,item,{**d,'category':'공구·구매품','catalog_code':code},refs)
for supplier,source in suppliers.items():add('partners',token('SUP-',supplier),supplier,{'category':'supplier','contact':'','phone':'','active':True,'code_generated':True},[source],'OPEN')
add('partners','CUS-HANWHA-AERO','한화에어로스페이스(주)',{'category':'customer','contact':'','phone':'','active':True,'code_generated':True},[{'file':'한화에어로스페이슬 발주서(2).pdf','page':1}],'OPEN')
# one product per exact code; original names and disagreements remain in part_detail, never overwrite deployed records
for code,variants in products.items():
 variants.sort(key=lambda d:d['priority']);p=variants[0];names=list(dict.fromkeys(v['name'] for v in variants));prs=list(dict.fromkeys(v['project'] for v in variants if v['project']));refs=[v['source'] for v in variants];units=list(dict.fromkeys(v['unit'] for v in variants if v['unit']))
 add('products',code,p['name'],{'project':p['project'],'unit':units[0] if len(units)==1 else '', 'active':True},refs,'OPEN')
 add('part_detail',code,p['name'],{'variants':variants,'name_variants':names,'project_variants':prs,'review_required':len(names)>1,'primary_name_rule':'PARTS_MASTER→XLSM품명→공정표→수주, 표시명 초안 기준; 다른 원문 병기'},refs)
 if len(names)>1:issue('products',code,'동일 품번에 원본 명칭 차이: '+' / '.join(names)[:350],refs)
# Routing candidates: all variants staged; single detailed or generic proposal only, all unapproved.
proc={};template_count=0;candidate_count=0;ambiguous=[]
for code,candidates in route_candidates.items():
 unique={}
 for c in sorted(candidates,key=lambda d:d['priority']):
  key=json.dumps([{k:v for k,v in st.items() if k not in ('source','source_column')} for st in c['steps']],ensure_ascii=False,sort_keys=True)
  if key in unique:unique[key]['other_sources'].append(c['source'])
  else:unique[key]={**c,'other_sources':[c['source']]}
 candidates=list(unique.values());detail=[c for c in candidates if c['priority']==0];proposals=detail if detail else candidates
 selected=proposals[0] if len(proposals)==1 else None
 for c in candidates:
  cc=token('RTC-',code,c.get('detail_sheet',''),json.dumps(c['steps'],ensure_ascii=False,sort_keys=True));candidate_count+=1
  for st in c['steps']:
   key=(st['name'],st['kind'],st['inspection_code']);pc=token('PROC-',*key)
   if pc not in proc:proc[pc]={'title':st['name'],'data':{'kind':st['kind'],'inspection_code':st['inspection_code'],'note':st['note'],'active':False,'verified':False,'review_required':True,'kind_proposed':True,'code_generated':True},'sources':[]}
   proc[pc]['sources'].append(st['source']);st['process_master_code']=pc
   unknown=[eq for eq in st.get('equipment_candidates',[]) if eq not in equipment]
   if unknown:st['unmatched_equipment']=unknown;issue('route_template',code,'원본 설비표기와 설비마스터 미매칭: '+', '.join(unknown),[st['source']])
  add('route_candidate',cc,c['label'],{'part_no':code,'project':c['project'],'rev':c.get('rev',''),'steps':c['steps'],'source_sheet':c.get('detail_sheet',''),'binding':c['binding'],'other_sources':c['other_sources'],'preferred_proposal':c is selected,'active':False,'verified':False,'review_required':True},c['other_sources'])
 if selected:
  template_count+=1;add('route_template',code,selected['label'],{'part_no':code,'project':selected['project'],'rev':selected.get('rev',''),'steps':selected['steps'],'source_sheet':selected.get('detail_sheet',''),'active':False,'verified':False,'review_required':True,'proposal_only':True,'candidate_count':len(candidates)},selected['other_sources'])
 else:
  ambiguous.append(code);issue('route_template',code,f'서로 다른 공정경로 {len(proposals)}개: 담당자가 경로 선택 필요',[c['source'] for c in proposals],'필수확인')
for pc,d in proc.items():add('process_master',pc,d['title'],d['data'],d['sources'])
# generic flow is reference, never auto-assign to all products.
for sh in BOOK['F']['sheets']:
 steps=[]
 for r in sh['rows']:
  for v in r['values']:
   m=re.match(r'^(\d+)\.\s*(.+)',s(v))
   if m:steps.append({'seq':int(m[1]),'name':m[2],'source':ref('F',sh['name'],r)})
 if steps:add('flow_reference',token('FLOW-',sh['name']),sh['name'],{'steps':sorted(steps,key=lambda v:v['seq']),'note':'제품별 라우팅에 자동 적용하지 않는 공정 개요 원문'},[{'file_id':'F','sheet':sh['name']}])
# historical routing records retained as non-operational source archive. formula errors retained literally.
for r in rsheets['라우팅입력']['rows']:
 if r['rowNo']<3 or not at(r,0):continue
 data={key:at(r,i) for i,key in enumerate(['lot','part_name','part_revision','project','so_raw','qty','serials','work_type','input_date_raw','due_date_raw','warranty_raw','print_raw','delivery_date_raw','inspection_lot','worker_raw','qnc_no','note'])}
 data.update(input_date=date(at(r,8)),due_date=date(at(r,9)),delivery_date=date(at(r,12)),source=ref('R','라우팅입력',r),formula_issues=r.get('issues',[]),operational=False)
 arch.append({'kind':'source_routing','code':token('HIST-',at(r,0),r['rowNo']),'title':s(at(r,0)),'state':'REFERENCE','data':data})
# order source original 82 columns separately, bundle import RPC validates using current order validator.
def colletter(i):
 t='';i+=1
 while i:i,x=divmod(i-1,26);t=chr(65+x)+t
 return t
for o,r in zip(orders,order_rows[1:]):
 o['data']['source_columns']=[{'index':i+1,'letter':colletter(i),'key':colletter(i),'label':s(h)} for i,h in enumerate(hdr)]
 o['data']['source_values']=[at(r,i) for i in range(len(hdr))]
# order exact-match report
matching=[]
for o in orders:
 code=o['data']['part_no'];matching.append({'order':o['code'],'part_no':code,'candidates':len(route_candidates.get(code,[])),'template_proposal':any(r['kind']=='route_template' and r['code']==code for r in rows),'note':'공정번호/REV까지 담당자 검토 후 주문별 Routing 생성'})
# Detect duplicate keys before writing. No silent loss.
keys=Counter((r['kind'],r['code']) for r in rows)
assert not [k for k,v in keys.items() if v>1], str([(k,v) for k,v in keys.items() if v>1])
assert all(1<=len(r['code'])<=400 and 1<=len(r['title'])<=300 for r in rows)
counts=Counter(r['kind'] for r in rows)
metadata={'format':'dnm-seed-bundle-v42','version':'4.2.0','bundle_id':'DNM-SOURCES-20261028-v42','generated_at':'2026-10-28','sources':FILES,'policies':{'existing':'skip; never overwrite existing values','auth_users':'not created; employee master requires manual account link','history':'reference only; no actual start/end, inspection, approval, shipment invented','scope':'No resident ID, address, phone, age, gender, Auth credentials'},'counts':dict(counts),'issues':ISSUES,'order_matching':matching,'equipment_worker_assignments':0,'employee_snapshot':'2026-07-20'}
bundle={**metadata,'rows':rows,'orders':orders}
(OUT/'DNM_v42_MasterData_PRIVATE.dnm.json').write_text(json.dumps(bundle,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
(OUT/'DNM_v42_RoutingHistory_PRIVATE.dnm.json').write_text(json.dumps({'format':'dnm-seed-bundle-v42','version':'4.2.0','bundle_id':'DNM-HISTORY-20261028-v42','sources':{'R':FILES['R']},'counts':{'source_routing':len(arch)},'issues':[],'rows':arch,'orders':[]},ensure_ascii=False,separators=(',',':')),encoding='utf-8')
(W/'seed_summary.json').write_text(json.dumps({**metadata,'historical_routes':len(arch),'route_candidate_count':candidate_count,'ambiguous_products':ambiguous,'row_count':len(rows)},ensure_ascii=False,indent=2),encoding='utf-8')
print('COUNTS',dict(counts),'current-orders',len(orders),'history',len(arch),'issues',len(ISSUES),'ambiguous',len(ambiguous))
print('ORDER MATCH',matching)
print('BUNDLE BYTES', (OUT/'DNM_v42_MasterData_PRIVATE.dnm.json').stat().st_size)
