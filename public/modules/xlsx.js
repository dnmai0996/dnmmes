/* DNM v4 OOXML reader. Values only: no macros, external links, formula execution or images.
 * ZIP entries are read selectively. Large sheets are streamed row-by-row (styled empty rows ignored).
 * Requires DecompressionStream('deflate-raw'): modern Chrome/Edge/Safari. CSV/JSON alternative provided.
 */
const dec=new TextDecoder('utf-8');
export const xmlText=s=>String(s??'').replace(/&#x([0-9a-f]+);|&#([0-9]+);|&(amp|lt|gt|quot|apos);/gi,(_,h,d,n)=>h?String.fromCodePoint(parseInt(h,16)):d?String.fromCodePoint(+d):({amp:'&',lt:'<',gt:'>',quot:'"',apos:"'"})[n.toLowerCase()]).replace(/_x([0-9a-f]{4})_/gi,(_,x)=>String.fromCharCode(parseInt(x,16)));
const attrs=s=>Object.fromEntries([...s.matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)].map(m=>[m[1],xmlText(m[2]??m[3])]));
export function columnNumber(s){let n=0;for(const c of String(s).toUpperCase().replace(/[^A-Z]/g,''))n=n*26+c.charCodeAt(0)-64;return n-1;}
export function columnLetter(n){let s='';for(n++;n;n=Math.floor((n-1)/26))s=String.fromCharCode(65+(n-1)%26)+s;return s;}
function zipIndex(buffer){
 const a=new Uint8Array(buffer),v=new DataView(buffer);let e=-1;
 for(let i=a.length-22;i>=Math.max(0,a.length-65557);i--)if(v.getUint32(i,true)===0x06054b50){e=i;break;}
 if(e<0)throw Error('유효한 XLSX ZIP이 아닙니다. 암호를 해제한 .xlsx 파일을 선택하세요.');
 const count=v.getUint16(e+10,true),offset=v.getUint32(e+16,true);if(count===65535||offset===0xffffffff)throw Error('ZIP64 형식은 지원하지 않습니다. 표준 XLSX로 다시 저장하세요.');
 let p=offset;const entries=new Map();
 for(let i=0;i<count;i++){
  if(p+46>a.length||v.getUint32(p,true)!==0x02014b50)throw Error('ZIP 파일 구조가 손상되었습니다.');
  const flags=v.getUint16(p+8,true),method=v.getUint16(p+10,true),size=v.getUint32(p+20,true),raw=v.getUint32(p+24,true),nl=v.getUint16(p+28,true),ex=v.getUint16(p+30,true),co=v.getUint16(p+32,true),local=v.getUint32(p+42,true);
  const name=dec.decode(a.subarray(p+46,p+46+nl));
  if(flags&1)throw Error('암호화된 XLSX는 읽을 수 없습니다.');
  entries.set(name,{method,size,raw,local});p+=46+nl+ex+co;
 }
 const stream=name=>{
  const ent=entries.get(name);if(!ent)throw Error('엑셀 내부 파일을 찾지 못했습니다: '+name);
  if(ent.raw>200*1024*1024)throw Error('워크시트가 너무 큽니다. 사용 범위를 줄여 저장하세요.');
  const q=ent.local;if(q+30>a.length||v.getUint32(q,true)!==0x04034b50)throw Error('ZIP 항목 헤더 오류');
  const start=q+30+v.getUint16(q+26,true)+v.getUint16(q+28,true);if(start+ent.size>a.length)throw Error('ZIP 항목 길이 오류');
  let s=new Blob([a.subarray(start,start+ent.size)]).stream();
  if(ent.method===8){try{s=s.pipeThrough(new DecompressionStream('deflate-raw'));}catch{throw Error('이 브라우저는 XLSX 압축 해제를 지원하지 않습니다. 최신 Chrome/Edge 또는 JSON 변환 도구를 사용하세요.');}}
  else if(ent.method!==0)throw Error('지원하지 않는 압축 형식입니다.');
  let bytes=0;return s.pipeThrough(new TransformStream({transform(chunk,c){bytes+=chunk.length;if(bytes>Math.min(ent.raw+1024,200*1024*1024))throw Error('압축 해제 크기 제한 초과');c.enqueue(chunk);}})).pipeThrough(new TextDecoderStream());
 };
 const text=async name=>{if((entries.get(name)?.raw||0)>15*1024*1024)throw Error('공유문자열/설정이 너무 큽니다.');let s='';for await(const chunk of stream(name))s+=chunk;if(/<!DOCTYPE|<!ENTITY/i.test(s))throw Error('외부 XML 선언은 허용되지 않습니다.');return s;};
 return {entries,stream,text};
}
function joinedText(s){return [...s.matchAll(/<(?:\w+:)?t(?:\s[^>]*)?>([\s\S]*?)<\/(?:\w+:)?t>/g)].map(m=>xmlText(m[1])).join('');}
function parseRow(row,strings,styles,formats){
 const ra=attrs(row.slice(0,row.indexOf('>'))),out=[],issues=[];
 for(const m of row.matchAll(/<(?:\w+:)?c\b([^>]*?)(?:\/\s*>|>([\s\S]*?)<\/(?:\w+:)?c>)/g)){
  const a=attrs(m[1]),body=m[2]||'',col=columnNumber((a.r||'').replace(/\d/g,''));if(col<0||col>511)continue;
  const raw=body.match(/<(?:\w+:)?v(?:\s[^>]*)?>([\s\S]*?)<\/(?:\w+:)?v>/)?.[1];let x;
  if(a.t==='s')x=strings[Number(raw)]??'';
  else if(a.t==='inlineStr')x=joinedText(body);
  else if(a.t==='str')x=xmlText(raw??'');
  else if(a.t==='e'){x=xmlText(raw??'');issues.push(`${a.r}: 셀 오류 ${x}`);}
  else if(raw!==undefined&&raw!==''){
   x=Number(raw);if(!Number.isFinite(x))x=xmlText(raw);
   const fmt=formats[styles[+a.s]];
   if(typeof x==='number'&&/^0{2,20}$/.test(fmt||''))x=String(x).padStart(fmt.length,'0');
  }else x='';
  if(/<(?:\w+:)?f\b/.test(body)&&raw===undefined)issues.push(`${a.r}: 수식 계산값 없음`);
  out[col]=x;
 }
 if(!out.some(v=>v!==''&&v!==undefined&&v!==null))return null;
 return {rowNo:Number(ra.r),values:Array.from({length:out.length},(_,i)=>out[i]??''),issues};
}
export async function readXlsx(buffer,{onProgress=()=>{},maxRows=20000,maxCells=350000}={}){
 if(buffer.byteLength>60*1024*1024)throw Error('파일은 60MB 이하로 업로드하세요.');
 const z=zipIndex(buffer),wb=await z.text('xl/workbook.xml'),rels=await z.text('xl/_rels/workbook.xml.rels');
 const mappings=Object.fromEntries([...rels.matchAll(/<(?:\w+:)?Relationship\b([^>]*?)\/?\s*>/g)].map(m=>{const a=attrs(m[1]);return[a.Id,a.TargetMode==='External'?null:a.Target];}));
 const strings=[];if(z.entries.has('xl/sharedStrings.xml')){
  const s=await z.text('xl/sharedStrings.xml');for(const m of s.matchAll(/<(?:\w+:)?si(?:\s[^>]*)?>([\s\S]*?)<\/(?:\w+:)?si>/g))strings.push(joinedText(m[1]));
 }
 const formats={},styles=[];if(z.entries.has('xl/styles.xml')){
  const s=await z.text('xl/styles.xml');for(const m of s.matchAll(/<(?:\w+:)?numFmt\b([^>]*?)\/?\s*>/g)){const a=attrs(m[1]);formats[a.numFmtId]=a.formatCode;}
  const x=s.match(/<(?:\w+:)?cellXfs\b[^>]*>([\s\S]*?)<\/(?:\w+:)?cellXfs>/)?.[1]||'';for(const m of x.matchAll(/<(?:\w+:)?xf\b([^>]*?)(?:\/?\s*>)/g))styles.push(attrs(m[1]).numFmtId);
 }
 const sheets=[];let nrows=0,ncells=0;
 for(const sm of wb.matchAll(/<(?:\w+:)?sheet\b([^>]*?)\/?\s*>/g)){
  const sa=attrs(sm[1]),target=mappings[sa['r:id']];if(!target)continue;
  const path=new URL(target,'https://local/xl/').pathname.slice(1);if(!path.startsWith('xl/'))throw Error('잘못된 워크시트 경로');
  const rows=[];let pending='',seen=0;
  onProgress(`${sa.name}: 시트 읽기`);
  for await(const chunk of z.stream(path)){
   pending+=chunk;
   if(/<!DOCTYPE|<!ENTITY/i.test(pending))throw Error('XML 선언 오류');
   let end;
   while((end=pending.indexOf('</row>'))>=0){
    const text=pending.slice(0,end+6);pending=pending.slice(end+6);seen++;
    const start=text.indexOf('<row');if(start<0)continue;
    // Skip millions of formatted but empty cells without parsing each of them.
    if(!/<(?:\w+:)?(?:v|t)(?:\s[^>]*)?>[^<]+</.test(text)&&!/<f\b/.test(text))continue;
    const row=parseRow(text.slice(start),strings,styles,formats);if(!row)continue;
    nrows++;ncells+=row.values.length;if(nrows>maxRows||ncells>maxCells)throw Error('실제 데이터 범위가 너무 큽니다. 파일을 나눠 업로드하세요.');rows.push(row);
    if(rows.length%1000===0)onProgress(`${sa.name}: ${rows.length}개 데이터 행`);
   }
   if(pending.length>8*1024*1024)throw Error('한 행 또는 XML 구조가 너무 큽니다. 표준 XLSX로 저장하세요.');
  }
  sheets.push({name:sa.name,rows});
 }
 return {format:'dnm-workbook-v1',date1904:/date1904=["'](?:1|true)["']/.test(wb),sheets};
}
