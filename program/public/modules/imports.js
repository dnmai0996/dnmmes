import {excelDate,qty,text,money} from './domain.js';
import {columnLetter} from './xlsx.js';
const norm=v=>String(v??'').replace(/\s|[\n\r]/g,'').toUpperCase();
const source=(file,sh,row)=>({file,sheet:sh.name,row:row.rowNo});
const string=v=>String(v??'').trim();
function mappedHeader(sh,groups){return sh.rows.find(r=>groups.every(g=>g.some(h=>r.values.some(v=>norm(v)===norm(h)))));}
function index(h,aliases){return h.values.findIndex(v=>aliases.some(x=>norm(x)===norm(v)));}
export function previewOrders(book,file){
 const out=[];
 for(const sh of book.sheets){const head=mappedHeader(sh,[['생산오더','생산오더번호'],['자재코드','품번'],['발주수량','수량']]);if(!head)continue;
 const ix={production_no:index(head,['생산오더','생산오더번호']),part_no:index(head,['자재코드','품번']),part_name:index(head,['자재명','품명']),qty:index(head,['발주수량','수량']),po_no:index(head,['PO 번호','PO번호']),po_line:index(head,['PO행번호','PO품목번호']),due_date:index(head,['납기일자','납기일']),order_date:index(head,['발주일자']),project:index(head,['Project내역','사업']),grade_code:index(head,['등급코드']),received_qty:index(head,['입고수량']),unit_price:index(head,['발주단가']),order_amount:index(head,['발주금액']),source_status:index(head,['상태'])};
 const cols=head.values.map((v,i)=>({key:columnLetter(i),letter:columnLetter(i),label:string(v)||'(공란)'}));
 for(const r of sh.rows.filter(r=>r.rowNo>head.rowNo)){
  const get=k=>ix[k]>=0?r.values[ix[k]]:'';if(!get('production_no')&&!get('part_no'))continue;const errors=[...(r.issues||[])],issues=[];
  const data={production_no:string(get('production_no')),part_no:string(get('part_no')),part_name:string(get('part_name')),po_no:string(get('po_no')),po_line:string(get('po_line')),project:string(get('project')),priority:'NORMAL',qty:get('qty'),due_date:'',order_date:''};
  data.grade_code=string(get('grade_code'));data.source_status=string(get('source_status'));
  for(const key of ['received_qty','unit_price','order_amount']){const raw=get(key);data[key]=null;if(raw!==''&&raw!==null&&raw!==undefined)try{const clean=String(raw).replace(/,/g,'').trim();data[key]=key==='received_qty'?qty(clean,'입고수량'):money(clean);}catch(e){errors.push(key+': '+e.message);}}
  if(!data.production_no)errors.push('생산오더 누락');if(!data.part_no)errors.push('품번 누락');
  try{data.qty=qty(String(data.qty??'').replace(/,/g,''),'발주수량',false);}catch(e){errors.push(e.message);}
  for(const key of ['due_date','order_date'])try{data[key]=excelDate(get(key),book.date1904);}catch(e){errors.push(key+': '+e.message);}
  if(!data.due_date)issues.push('납기 공란 확인');if(!data.po_line)issues.push('PO 행번호 미제공: 계약품목번호·PR순번 대입 금지');
  if(!data.part_name)issues.push('품명 공란 확인');
  data.source={...source(file,sh,r),columns:cols,values:Array.from({length:cols.length},(_,i)=>r.values[i]??'')};
  out.push({rowNo:r.rowNo,sheet:sh.name,data,errors,issues});
 }
 }
 const groups=new Map();for(const r of out){const k=r.data.production_no;if(!groups.has(k))groups.set(k,[]);groups.get(k).push(r);}for(const a of groups.values())if(a.length>1)for(const r of a)r.errors.push('파일 내 생산오더 중복');return out;
}
export function previewMasters(book,file,kind){
 const out=[];let serial=0;
 for(const sh of book.sheets){
  if(kind==='catalog'){
   const h=mappedHeader(sh,[['품명 / 재질','품명/재질','품목','품명']]);if(!h)continue;
   const supplier=string(sh.rows.find(r=>r.rowNo<h.rowNo&&norm(r.values[0])==='공구')?.values[1])||sh.name;
   const it=index(h,['품명 / 재질','품명/재질','품목','품명']),sp=index(h,['규격']);
   for(const r of sh.rows.filter(r=>r.rowNo>h.rowNo)){const item=string(r.values[it]);if(!item)continue;out.push({kind,key:[supplier,item,string(r.values[sp])].join('|'),title:item,data:{supplier,item,specification:string(r.values[sp]),unit:'',source:[source(file,sh,r)]},errors:r.issues||[]});}
  }else if(kind==='equipment'){
   const h=mappedHeader(sh,[['설비번호'],['설비명']]);if(!h)continue;
   const cols={department:['사업'],category:['구분'],key:['설비번호'],title:['설비명'],model:['모델명'],specification:['설비규격'],units:['대수'],manufacturer:['제조사'],worker_source:['작업자'],main_product:['주가공품'],introduced:['도입년도'],remarks:['비고(SYSTEM)','비고']};
   const ix=Object.fromEntries(Object.entries(cols).map(([k,a])=>[k,index(h,a)]));
   for(const r of sh.rows.filter(r=>r.rowNo>h.rowNo)){const d=Object.fromEntries(Object.entries(ix).map(([k,i])=>[k,string(r.values[i])]));if(!d.key||!d.title)continue;const {key,title,...data}=d;out.push({kind,key,title,data:{...data,active:false,source:source(file,sh,r),verified:false},errors:r.issues||[]});}
  }else if(kind==='instrument'){
   const h=mappedHeader(sh,[['Serial No.','관리번호'],['명칭']]);if(!h)continue;
   const cols={category:['구분'],title:['명칭'],key:['Serial No.','관리번호'],manufacturer:['제작회사','제조사'],specification:['규격/정밀도','규격'],introduced:['입고일자'],calibration_due:['차기교정']};const ix=Object.fromEntries(Object.entries(cols).map(([k,a])=>[k,index(h,a)]));
   for(const r of sh.rows.filter(r=>r.rowNo>h.rowNo)){const d=Object.fromEntries(Object.entries(ix).map(([k,i])=>[k,r.values[i]??'']));if(!d.key||!d.title)continue;for(const k of ['introduced','calibration_due']){const raw=d[k];try{d[k]=excelDate(raw,book.date1904);}catch{d[k]=string(raw);}d[k+'_raw']=raw;}const {key,title,...data}=d;out.push({kind,key:string(key),title:string(title),data:{...data,source:source(file,sh,r)},errors:r.issues||[]});}
  }else if(kind==='products'){
   const h=mappedHeader(sh,[['PART NO','품번','제품코드'],['품명']]);if(!h)continue;const ci=index(h,['PART NO','품번','제품코드']),ni=index(h,['품명']),pi=index(h,['기준','사업','Project']);let project='';
   for(const r of sh.rows.filter(r=>r.rowNo>h.rowNo)){if(r.values[pi])project=string(r.values[pi]);const key=string(r.values[ci]),title=string(r.values[ni]);if(!key||!title)continue;out.push({kind,key,title,data:{project,unit:'',source:source(file,sh,r)},errors:r.issues||[]});}
  }else if(kind==='route_template'){
   const h=mappedHeader(sh,[['품번'],['품명']]);if(!h)continue;const ci=index(h,['품번']),ni=index(h,['품명']);
   for(const r of sh.rows.filter(r=>r.rowNo>h.rowNo)){const key=string(r.values[ci]),title=string(r.values[ni]);if(!key||!title)continue;const steps=r.values.slice(5,16).map((v,i)=>({source_column:columnLetter(i+5),name:string(v)})).filter(x=>x.name).map((x,i)=>({...x,seq:i+1,code:String((i+1)*10).padStart(3,'0'),kind:'WORK'}));if(!steps.length)continue;out.push({kind,key,title,data:{part_no:key,steps,review_required:true,source:source(file,sh,r)},errors:[],issues:['공정유형·순서·가능설비는 배포 전 담당자 확인 필요']});}
  }else if(kind==='employee'){
   const h=mappedHeader(sh,[['성명','이름'],['부서','부서명']]);if(!h)continue;const ix=Object.fromEntries(Object.entries({title:['성명','이름'],key:['사번','직원번호'],department:['부서','부서명'],position:['직책','직위'],hired:['입사일','입사일자']}).map(([k,a])=>[k,index(h,a)]));
   for(const r of sh.rows.filter(r=>r.rowNo>h.rowNo)){const d=Object.fromEntries(Object.entries(ix).map(([k,i])=>[k,r.values[i]??'']));if(!d.title)continue;let errors=[...(r.issues||[])];if(!d.key)errors.push('사번 필요: 이름으로 자동 계정을 만들지 않습니다.');try{d.hired=excelDate(d.hired,book.date1904);}catch(e){errors.push(e.message);}const {key,title,...data}=d;out.push({kind,key:string(key),title:string(title),data:{...data,active:false,source:source(file,sh,r)},errors});}
  }
 }
 // Catalogue duplicates are combined without losing the original source row references.
 if(kind==='catalog'){const map=new Map();for(const r of out){if(map.has(r.key))map.get(r.key).data.source.push(...r.data.source);else map.set(r.key,r);}return [...map.values()];}
 const groups=new Map();for(const r of out){if(!groups.has(r.key))groups.set(r.key,[]);groups.get(r.key).push(r);if(kind==='instrument'&&/다수|미정|없음|^[-]$/.test(r.key))r.errors.push('개별 관리번호 미제공: 원본을 확인하세요.');}for(const a of groups.values())if(a.length>1)for(const r of a)r.errors.push('동일 코드가 파일 안에 중복됩니다.');return out;
}
