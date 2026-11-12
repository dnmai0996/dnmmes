// Read-only comparison of an uploaded reference bundle with stored source rows.
// Use the same identity checks as the importer; never classify a file preview as saved.
export function sourceRows(bundle){return (bundle?.rows||[]).filter(row=>row.kind==='source_routing');}

export function compareSourceRows(bundle,stored){
 const indexes={code:new Map(),title:new Map(),lot:new Map()};
 for(const row of stored){
  if(row.kind!=='source_routing')continue;
  for(const key of Object.keys(indexes)){
   const value=key==='lot'?row.data?.lot:row[key];
   if(value===undefined||value===null||value==='')continue;
   const index=indexes[key],text=String(value);
   if(!index.has(text))index.set(text,[]);index.get(text).push(row);
  }
 }
 const rows=sourceRows(bundle).map(source=>{
  const matches=new Set();
  for(const key of Object.keys(indexes)){
   const value=key==='lot'?source.data?.lot:source[key];
   if(value!==undefined&&value!==null&&value!=='')for(const row of indexes[key].get(String(value))||[])matches.add(row);
  }
  const found=[...matches].sort((a,b)=>Number(b.code===source.code)-Number(a.code===source.code)||String(a.id).localeCompare(String(b.id)));
  return {source,matches:found,status:found.length?(found.some(row=>row.code===source.code)?'same-code':'existing-lot'):'missing'};
 });
 return {rows,total:rows.length,matched:rows.filter(row=>row.matches.length).length,
  existing:rows.filter(row=>row.status==='existing-lot').length,missing:rows.filter(row=>!row.matches.length).length,
  multiple:rows.filter(row=>row.matches.length>1).length};
}
