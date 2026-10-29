import {routingSort} from './routing-domain.js';
/** Read model only: draft/superseded/cancelled routings never create shop-floor instructions. */
export function instructionRows(routes,operations,state='open'){
 const byId=new Map(routes.filter(r=>['RELEASED','DONE'].includes(r.state)).map(r=>[r.id,r]));
 return operations.filter(o=>byId.has(o.parent_id)&&!['CANCELLED','SUPERSEDED'].includes(o.state))
 .map(o=>{const r=byId.get(o.parent_id);return {...o,route:r,data:{...o.data,part_no:r.data.part_no,production_no:r.data.production_no,due_date:r.data.due_date||'',route_code:r.code,route_title:r.title}};})
 .filter(o=>state==='all'||(state==='closed'?o.state==='DONE':o.state!=='DONE'&&o.route.state==='RELEASED'))
 .sort((a,b)=>routingSort(a.route,b.route)||Number(a.data.seq||0)-Number(b.data.seq||0));
}
