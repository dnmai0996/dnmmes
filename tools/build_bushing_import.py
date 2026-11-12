"""Read cached XLSM cells without executing macros; prepare non-operational reference import."""
import argparse, collections, csv, datetime as dt, hashlib, json
from pathlib import Path
import openpyxl

def normal(v):
    if isinstance(v,dt.datetime): return v.isoformat()
    if isinstance(v,(dt.date,dt.time)): return v.isoformat()
    return v

def celltext(v): return '' if v is None else str(v).strip()
def csvsafe(v):
    s=celltext(v)
    return "'"+s if s[:1] in ('=','+','-','@','\t','\r') else s

def build(source,out,asof):
    out.mkdir(parents=True,exist_ok=True)
    book=openpyxl.load_workbook(source,read_only=True,data_only=True,keep_links=False)
    sheet=book['라우팅입력'];sheet.reset_dimensions()
    rows=[]
    for n,values in enumerate(sheet.iter_rows(max_col=16,values_only=True),1):
        if n<3 or values[0] in (None,''):continue
        rows.append({'row':n,'values':[normal(v) for v in values]})
    candidates=[r for r in rows if celltext(r['values'][8]).startswith(str(asof.year)+'-') and celltext(r['values'][8])[:10]<=asof.isoformat() and r['values'][11] in (None,'')]
    counts=collections.Counter(celltext(r['values'][0]) for r in rows)
    duplicate=[{'lot':lot,'rows':[r['row'] for r in rows if celltext(r['values'][0])==lot]} for lot,n in counts.items() if n>1]
    assert len({r['values'][0] for r in candidates})==len(candidates),'Current candidates contain duplicate LOT IDs; review before import.'
    templates={}
    for name in ['F','F(80-5)','NF','F(NR)','NF(NM)']:
        ws=book[name];ws.reset_dimensions()
        templates[name]=[[normal(v) for v in values] for values in ws.iter_rows(max_col=11,values_only=True) if any(v is not None for v in values)]
    source_sha=hashlib.sha256(source.read_bytes()).hexdigest()
    records=[]
    for r in candidates:
        v=r['values'];lot=celltext(v[0]);part=celltext(v[1])
        records.append({'kind':'source_routing','code':'HIST-BUSH-'+lot,'title':lot,'state':'REFERENCE','data':{
            'source_family':'DNM_BUSH_XLSM','lot':lot,'part_no':part,'part_revision':part,'part_name':celltext(v[2]),'project':celltext(v[3]),
            'heat_code':celltext(v[4]),'shop_order_no':celltext(v[5]),'so_raw':v[5],'material_certificate':v[6],'part_type':celltext(v[7]),
            'qty':None,'input_date':celltext(v[8])[:10],'material_diameter':v[9],'note':celltext(v[10]),'delivery_date':None,
            'operational':False,'review_required':True,'review_status':'재공 확인대기','source_state':'납품완료일 미기재',
            'missing_fields':['LOT 수량','현재 진행상태','S/O','Heat Code','실제 작업자·설비','공정별 실적수량·시간'],
            'source':{'file':source.name,'sha256':source_sha,'sheet':'라우팅입력','row':r['row']},'source_values':v}})
    issues=[{'kind':'source_routing','code':'CURRENT-STATUS','issue':f'{len(records):,}건은 {asof.year}년 투입·납품완료일 미기재 후보입니다. 작업 중으로 확정되지 않았습니다.'},
            {'kind':'source_routing','code':'MISSING-QTY','issue':'LOT 수량·S/O·Heat Code·실제 공정실적이 없습니다. 생산지시·실적·재고는 자동 생성하지 않습니다.'},
            {'kind':'source_routing','code':'OLD-OPEN','issue':'이전 연도 납품완료일 미기재 행은 후보에서 제외하고 전체원문 CSV에 보관했습니다.'}]
    bundle={'format':'dnm-seed-bundle-v42','version':'4.10.1','bundle_id':'DNM-BUSH-WIP-REVIEW-'+asof.isoformat()+'-'+source_sha[:12],
            'sources':{'R':{'file':source.name,'sha256':source_sha,'sheet':'라우팅입력','columns':['LOT.NO','품번','품명','기종','HEAT CODE','S/O','원소재성적서','TYPE','투입일','소재Ø','비고','납품완료라우팅시트'], 'process_templates':templates}},
            'counts':{'source_routing':len(records)},'issues':issues,'rows':records,'orders':[]}
    (out/'DNM_민수부싱_2026_재공확인대기_PRIVATE.dnm.json').write_text(json.dumps(bundle,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    with (out/'DNM_민수부싱_재공확인표.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.writer(f);writer.writerow(['원본행','기존 LOT','품번','품명','기종','공정형식','투입일','현재 상태(확인필요)','LOT 수량(입력필요)','연결할 MES 수주번호','S/O','Heat Code','실제 작업자','실제 설비','비고'])
        for r in candidates:
            v=r['values'];writer.writerow([csvsafe(x) for x in [r['row'],v[0],v[1],v[2],v[3],v[7],celltext(v[8])[:10],'확인대기','','',v[5],v[4],'','',v[10]]])
    with (out/'DNM_민수부싱_전체원문_17698행.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.writer(f);writer.writerow(['원본행','LOT.NO','품번','품명','기종','HEAT CODE','S/O','원소재성적서','TYPE','투입일','소재Ø','비고','납품완료라우팅시트','M','N','O','P'])
        writer.writerows([[r['row']]+[csvsafe(v) for v in r['values']] for r in rows])
    report={'source':source.name,'source_sha256':source_sha,'as_of':asof.isoformat(),'all_rows':len(rows),'candidate_rows':len(candidates),
            'all_delivery_blank':sum(r['values'][11] in (None,'') for r in rows),'older_delivery_blank_excluded':sum(r['values'][11] in (None,'') for r in rows)-len(candidates),
            'candidate_missing_qty':len(candidates),'candidate_missing_so':sum(not celltext(r['values'][5]) for r in candidates),'candidate_missing_heat':sum(not celltext(r['values'][4]) for r in candidates),
            'candidate_types':dict(collections.Counter(r['values'][7] for r in candidates)),'duplicate_original_lots':duplicate,'operating_database_written':False}
    (out/'분석결과.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--out',required=True);p.add_argument('--as-of',required=True)
    a=p.parse_args();build(Path(a.input),Path(a.out),dt.date.fromisoformat(a.as_of))
