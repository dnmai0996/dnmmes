#!/usr/bin/env python3
"""Local optional converter for large styled Excel files. Python standard library only.
Reads cached cell values, never executes formulas/macros, never sends data to a server.
Usage: python xlsx_to_dnm_json.py INPUT.xlsx [OUTPUT.dnm.json]
The output is company data: do NOT commit to GitHub or copy into public/.
"""
from pathlib import Path
from zipfile import ZipFile
from xml.etree import ElementTree as ET
import json,sys,posixpath,re
N='{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
R='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
def col(s):
 n=0
 for c in re.sub('[^A-Z]','',s.upper()): n=n*26+ord(c)-64
 return n-1

def convert(filename):
 result={'format':'dnm-workbook-v1','date1904':False,'source_file':Path(filename).name,'sheets':[]}
 with ZipFile(filename) as z:
  ss=[]
  if 'xl/sharedStrings.xml' in z.namelist():
   for event,e in ET.iterparse(z.open('xl/sharedStrings.xml'),events=['end']):
    if e.tag==N+'si':ss.append(''.join(x.text or '' for x in e.iter(N+'t')));e.clear()
  rels={e.attrib['Id']:e.attrib['Target'] for e in ET.fromstring(z.read('xl/_rels/workbook.xml.rels')) if e.attrib.get('TargetMode')!='External'}
  book=ET.fromstring(z.read('xl/workbook.xml'));pr=book.find(N+'workbookPr');result['date1904']=pr is not None and pr.attrib.get('date1904') in ('1','true')
  for sheet in book.iter(N+'sheet'):
   name=sheet.attrib['name'];target=rels.get(sheet.attrib[R+'id']);
   if not target:continue
   path=target.lstrip('/') if target.startswith('/') else posixpath.normpath('xl/'+target)
   rows=[];parent=None
   for event,e in ET.iterparse(z.open(path),events=['start','end']):
    if event=='start' and e.tag==N+'sheetData':parent=e
    if event!='end' or e.tag!=N+'row':continue
    values={};issues=[]
    for cell in e:
     ref=cell.attrib.get('r','');i=col(ref);v=cell.find(N+'v');v=v.text if v is not None else '';t=cell.attrib.get('t')
     if t=='s' and v:v=ss[int(v)]
     elif t=='inlineStr':v=''.join(x.text or '' for x in cell.iter(N+'t'))
     elif t not in ('str','e') and v:
      try:v=float(v);v=int(v) if v.is_integer() else v
      except ValueError:pass
     if t=='e':issues.append(ref+': '+str(v))
     if cell.find(N+'f') is not None and not v:issues.append(ref+': 수식 계산값 확인')
     if i>=0 and i<=511 and v not in ('',None):values[i]=v
    if values:
     rows.append({'rowNo':int(e.attrib['r']),'values':[values.get(i,'') for i in range(max(values)+1)],'issues':issues})
     if len(rows)>20000:raise ValueError('시트의 실제 데이터 행은 20,000개까지 처리합니다.')
    e.clear()
    if parent is not None:parent.clear()
   result['sheets'].append({'name':name,'rows':rows})
 return result
if __name__=='__main__':
 if len(sys.argv)<2:raise SystemExit('사용법: python xlsx_to_dnm_json.py 원본.xlsx [결과.dnm.json]')
 src=Path(sys.argv[1]);dest=Path(sys.argv[2]) if len(sys.argv)>2 else src.with_suffix('.dnm.json')
 if dest.exists():raise SystemExit('기존 파일 보호: 다른 출력파일명을 지정하세요.')
 obj=convert(src);dest.write_text(json.dumps(obj,ensure_ascii=False),encoding='utf-8')
 print('변환 완료:',dest);print('데이터 행수:',sum(len(s['rows']) for s in obj['sheets']))
