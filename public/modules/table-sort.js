// Client-side table ordering: sort the ENTIRE filtered record set before paging.
// Pure helpers: no database writes and no additional permissions.
const collator = new Intl.Collator('ko-KR', {numeric: true, sensitivity: 'base'});
export function displayedText(html) {
  if(html === null || html === undefined) return '';
  return String(html).replace(/<br\s*\/?\s*>/gi, ' ')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&(?:nbsp|#160);/gi, ' ')
    .replace(/&amp;/gi, '&').replace(/&lt;/gi, '<').replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"').replace(/&#39;|&apos;/gi, "'")
    .replace(/\s+/g, ' ').trim();
}
const blank = v => !v || v === '—' || v === '-' || v === '미확정' || v === '미등록' || v === '미지정';
function parseComparable(v) {
  const text = displayedText(v);
  if(blank(text))return {kind:'empty',value:null,text};
  // Treat YYYY-MM-DD or yyyy. m. d. with optional time as chronological values.
  const date = text.match(/^(\d{4})[-./년]\s*(\d{1,2})[-./월]\s*(\d{1,2})(?:일)?(?:\D+(\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
  if(date) {
    const [,y,m,d,hh='0',mm='0',ss='0']=date;
    const month=Number(m),day=Number(d);
    if(month>=1&&month<=12&&day>=1&&day<=31) return {kind:'date',value:Date.UTC(+y,month-1,day,+hh,+mm,+ss),text};
  }
  const numeric = text.replace(/,/g,'').match(/^-?\d+(?:\.\d+)?$/);
  if(numeric)return {kind:'number',value:Number(numeric[0]),text};
  return {kind:'text',value:text,text};
}
export function compareSortValues(a,b,dir='asc') {
  const x=parseComparable(a),y=parseComparable(b),sign=dir==='desc'?-1:1;
  if(x.kind==='empty'||y.kind==='empty')return x.kind==='empty'?(y.kind==='empty'?0:1):-1; // blanks always last
  if(x.kind===y.kind&&(x.kind==='date'||x.kind==='number'))return (x.value-y.value)*sign;
  return collator.compare(x.text,y.text)*sign;
}
export function sortCellRows(rows,col,dir='asc') {
  return rows.map((cells,index)=>({cells,index})).sort((a,b)=>compareSortValues(a.cells[col],b.cells[col],dir)||a.index-b.index).map(x=>x.cells);
}
export const SORT_EXCLUDED_HEADERS = new Set(['관리','선택','확인','출력','등록','권한','작업일보 준비','연결할 대상','로그인 사용자']);
export function canSortHeader(label){return !SORT_EXCLUDED_HEADERS.has(String(label).trim());}
export function sortTableDOM(table,col,dir='asc') {
  const body=table?.tBodies?.[0];if(!body)return;
  const rows=Array.from(body.rows).filter(r=>r.cells.length>col&&!r.querySelector('.empty'));
  const keyed=rows.map((r,i)=>({r,i,text:r.cells[col]?.textContent||''}));
  keyed.sort((a,b)=>compareSortValues(a.text,b.text,dir)||a.i-b.i);
  for(const item of keyed)body.appendChild(item.r);
}
export function indicateSort(table,col,dir) {
  const ths=Array.from(table?.tHead?.rows?.[0]?.cells||[]);
  ths.forEach((th,i)=>{
    th.setAttribute('aria-sort',i===col?(dir==='desc'?'descending':'ascending'):'none');
    const icon=th.querySelector('.sort-indicator');if(icon)icon.textContent=i===col?(dir==='desc'?'▼':'▲'):'⇅';
    const button=th.querySelector('[data-table-sort]');
    if(button)button.title=i===col?(dir==='desc'?'내림차순 정렬 · 다시 클릭하면 오름차순':'오름차순 정렬 · 다시 클릭하면 내림차순'):'이 열 기준 오름차순 정렬';
  });
}
export function localHeaderSort(btn) {
  const table=btn?.closest('table');if(!table)return;
  const col=Number(btn.dataset.tableSort),old=table.dataset.sortColumn===String(col)?table.dataset.sortDirection:'';
  const dir=old==='asc'?'desc':'asc';
  sortTableDOM(table,col,dir);table.dataset.sortColumn=String(col);table.dataset.sortDirection=dir;indicateSort(table,col,dir);
}
