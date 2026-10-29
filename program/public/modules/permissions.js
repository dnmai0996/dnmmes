// v4.2 UI capabilities mirror the database ACL. Never use this file as the only authorization check.
export const MODULES={dashboard:'작업진척 대시보드',orders:'고객수주·원본',routing:'Routing·작업지시',worklogs:'본인작업·작업일보',purchase:'구매요청',receipts:'발주·입고·반품',settlement:'정산',quality:'품질·출하',documents:'품질문서',products:'제품',materials:'자재',employees:'작업자',processes:'공정',equipment:'설비',instruments:'계측기',customers:'매출처',suppliers:'매입처',templates:'제품 Routing',assignments:'설비·작업자 연결',catalog:'공구·공급업체',notes:'공유메모',archives:'원본 Routing 이력'};
// Dashboard is a standalone entry; group visibility still uses the existing database ACL.
export const TOP_PAGES=['dashboard'];
export const GROUPS=[
 ['수주관리',['orders','routing']],
 ['생산관리',['instructions','workCards','touchWork','voiceWork','worklogs']],
 ['구매관리',['purchase','receipts','settlement']],
 ['품질관리',['quality','documents']],
 ['설비·계측관리',['equipment','instruments']],
 ['기준정보',['products','materials','employees','processes','customers','suppliers','templates','catalog']],
 ['초기구축·운영',['seedData','workforceSetup','sourceReview','sourceOrders','routeCandidates','archives','notes','profiles','access','audit','backup','home']]
];
export const PAGE_MODULE={instructions:'routing',sourceOrders:'orders',touchWork:'worklogs',voiceWork:'worklogs',work:'worklogs',routeCandidates:'templates',routingSetup:'routing',workCards:'routing',sourceReview:'products'};
export const ADMIN_PAGES=new Set(['seedData','workforceSetup','profiles','access','audit','backup','home','sourceReview']);
export function permit(ctx,module,action='read'){
 if(!ctx?.profile?.active)return false;if(ctx.profile.role==='admin')return true;
 if(action!=='read'&&ctx.profile.role!=='member')return false;
 const p=ctx.permissions?.[module];return !!(p?.read&&(action==='read'||p[action]));
}
export function pageAllowed(ctx,page){return ADMIN_PAGES.has(page)?ctx?.profile?.active&&ctx.profile.role==='admin':permit(ctx,PAGE_MODULE[page]||page);}
export function navGroups(ctx){return [...TOP_PAGES.filter(p=>pageAllowed(ctx,p)).map(p=>({title:'대시보드',pages:[p],standalone:true})),...GROUPS.map(([title,pages])=>({title,pages:pages.filter(p=>pageAllowed(ctx,p))})).filter(g=>g.pages.length)];}
export function permissionPreset(name){
 const acl=Object.fromEntries(Object.keys(MODULES).map(m=>[m,{read:false,create:false,update:false,scope:'all'}]));
 const set=(m,write=false,scope='all')=>{acl[m]={read:true,create:write,update:write,scope};};
 if(name==='worker'){set('worklogs',true,'own');set('notes');}
 if(name==='production'){for(const m of ['dashboard','orders','routing','worklogs','products','employees','equipment','processes','templates','assignments'])set(m,['orders','routing','worklogs'].includes(m));set('notes',true);}
 if(name==='purchasing'){for(const m of ['purchase','receipts','settlement'])set(m,true);for(const m of ['materials','suppliers','catalog'])set(m);set('notes',true);}
 if(name==='quality'){for(const m of ['quality','documents'])set(m,true);for(const m of ['dashboard','orders','routing','worklogs','instruments','products'])set(m);set('notes');}
 if(name==='viewer'){for(const m of ['dashboard','orders','routing','worklogs'])set(m);set('notes');}
 if(name==='master'){for(const m of ['products','materials','employees','processes','equipment','instruments','customers','suppliers','templates','assignments','catalog'])set(m,true);set('archives');set('notes',true);}
 return acl;
}
const CREATE={newOrder:'orders',importOrders:'orders',newRouting:'routing',start:'worklogs',manual:'worklogs',newPurchase:'purchase',newPurchaseCatalog:'purchase',addPayment:'settlement',receive:'receipts',returnReceipt:'receipts',settle:'settlement',quality:'quality',newQuality:'quality',ship:'quality',customerReturn:'quality',returnCustomer:'quality',newProduct:'products',newPartner:'partners',newTemplate:'templates',newExtra:'kind',newMaster:'kind',importMaster:'kind'};
const UPDATE={editOrder:'orders',urgent:'orders',closeOrder:'orders',release:'routing',assign:'routing',managerStep:'routing',finish:'worklogs',stopLog:'worklogs',completeLog:'worklogs',confirmLog:'worklogs',cancelLog:'worklogs',ack:'worklogs',purchaseOrder:'receipts',purchaseQuote:'receipts',editPayment:'settlement',paid:'settlement',editProduct:'products',editPartner:'partners',editTemplate:'templates',editExtra:'kind',editMaster:'kind'};
export const KIND_MODULE={equipment:'equipment',instrument:'instruments',employee:'employees',assignment:'assignments',route_template:'templates',route_candidate:'templates',catalog:'catalog',material_master:'materials',process_master:'processes',quality_doc:'documents',products:'products'};
export function actionRule(action,id,page,record){
 if(['approve','reject','delegate'].includes(action))return {module:'purchase',action:'read',approve:true};
 if(['templateForOrder','templateForProduct','useCandidate'].includes(action))return {module:'templates',action:'write'};
 if(action==='bulkUseMaster')return {module:'products',action:'write'};
 if(action==='pauseLog')return {module:'worklogs',action:'update'};
 if(['printPurchaseRequest','sharePurchaseRequest','printPurchaseQuote','sharePurchaseQuote','printPurchaseOrder','sharePurchaseOrder'].includes(action))return {module:'purchase',action:'read'};
 if(action==='voicePanel')return {module:'worklogs',action:'write'};
 if(action==='importOrders')return {module:'orders',action:'write'};
 if(action==='importMaster')return {module:KIND_MODULE[id]||PAGE_MODULE[page]||page,action:'write'};
 let m=CREATE[action]||UPDATE[action];if(!m)return null;
 if(m==='kind')m=KIND_MODULE[record?.kind||id]||PAGE_MODULE[page]||page;
 if(m==='partners')m=record?.category==='supplier'?'suppliers':record?.category==='customer'?'customers':page==='suppliers'?'suppliers':'customers';
 return {module:m,action:CREATE[action]?'create':'update'};
}
export function actionAllowed(ctx,action,id,page,record){const rule=actionRule(action,id,page,record);if(!rule)return true;return (rule.action==='write'?(permit(ctx,rule.module,'create')||permit(ctx,rule.module,'update')):permit(ctx,rule.module,rule.action))&&(!rule.approve||ctx.profile.role==='admin'||ctx.capabilities?.includes('approve'));}
export function validateBundle(book){
 if(book?.format!=='dnm-seed-bundle-v42'||!Array.isArray(book.rows)||book.rows.length>15000)throw Error('v4.2 기준정보 자료묶음 파일을 선택하세요.');
 const kinds=new Set(['products','partners','employee','equipment','instrument','catalog','material_master','process_master','part_detail','route_template','route_candidate','flow_reference','source_routing','data_issue']);const seen=new Set();
 for(const r of book.rows){if(!kinds.has(r.kind)||!String(r.code||'').trim()||!String(r.title||'').trim()||typeof r.data!=='object'||!r.data||Array.isArray(r.data))throw Error('자료묶음 행 형식을 확인하세요.');const key=r.kind+'\0'+r.code;if(seen.has(key))throw Error('자료묶음 내부 중복코드: '+r.code);seen.add(key);if(['worklog','operation','routing','profiles'].includes(r.kind))throw Error('실적·계정 자동 생성 금지');}
 return {rows:book.rows.length,counts:book.rows.reduce((a,r)=>(a[r.kind]=(a[r.kind]||0)+1,a),{}),orders:book.orders?.length||0,issues:book.issues?.length||0};
}
export function employeeSort(a,b){const rank=r=>{const x=r.data||r;const p=String(x.position||'');return /대표|사장|전무|상무|공장장/.test(p+' '+x.department)?0:1;};const dept=r=>String(r.data?.department||'').replace(/\s/g,'');const order=['대표이사','관리','영업','연구개발','생산/기술팀','생산기술','생산팀','품질팀'];const dr=r=>order.indexOf(dept(r))<0?99:order.indexOf(dept(r));const pr=r=>{const p=String(r.data?.position||'');const v=['사장','전무','상무','공장장','부장','차장','과장','대리','주임','사원'];const n=v.findIndex(x=>p.includes(x));return n<0?99:n;};return rank(a)-rank(b)||dr(a)-dr(b)||dept(a).localeCompare(dept(b),'ko')||pr(a)-pr(b)||String(a.data?.hired||'9999').localeCompare(String(b.data?.hired||'9999'))||a.title.localeCompare(b.title,'ko');}
