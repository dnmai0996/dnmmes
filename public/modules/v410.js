import {V493Controller} from './v493.js';
import {CivilUI} from './civil.js';
import {CIVIL_PAGES,isCivilOrder,isCivilRoute} from './civil-domain.js';
import {permit,pageAllowed,actionAllowed} from './permissions.js';
import {$,esc,num,btn,input,area,select,table,notice,message,modal,pill} from './ui.js';
import {qty,money,counts} from './domain.js';
import {routingSort} from './routing-domain.js';

const today=()=>new Date(Date.now()+32400000).toISOString().slice(0,10);
const choices=(rows)=>rows.map(r=>[r.id,[r.title||r.name,r.data?.department||r.code].filter(Boolean).join(' · ')]);

// All new writes use additive server RPCs. Legacy defence and purchasing paths
// remain in the existing controller chain; no client-side data migrations.
export class V410Controller extends V493Controller {
 constructor(...args){super(...args);this.civil=new CivilUI(this);}
 async load(page){
  if(!CIVIL_PAGES.has(page))return super.load(page);
  if(this.loadingImport)throw Error('일괄등록이 끝난 뒤 이동하세요.');
  if(!pageAllowed(this.ctx,page)){this.page=page;this.set(notice('이 메뉴의 조회권한을 관리자에게 요청하세요.','warning'));return;}
  if(this.page!==page){this.search='';this.pageNo=1;this.detail=null;this.selected.clear();}
  this.page=page;return this.civil.load(page);
 }
 help(){return CIVIL_PAGES.has(this.page)?this.civil.help():super.help();}
 async civilOrder(order){return isCivilOrder(order)||(await this.rec('routing',{parent:order.id})).some(isCivilRoute);}
 async orders(){
  const [orders,routes]=await Promise.all([this.rec('order'),this.rec('routing')]);
  if(this.page!=='orders')return;
  const civilIds=new Set(routes.filter(isCivilRoute).map(r=>r.parent_id)),routedIds=new Set(routes.map(r=>r.parent_id));
  const rows=this.filter(orders).sort(routingSort);
  const create=permit(this.ctx,'orders','create'),routing=permit(this.ctx,'routing','create');
  this.set(`<div class="card">${this.top(create?btn('newCivilOrder','민수 수주 수기등록','','primary')+btn('newOrder','방산 수주 직접등록')+btn('importOrders','방산 수주 Excel 등록'):'')}${notice('민수는 수주를 수기로 등록한 뒤 「민수 LOT 작성」에서 작업 LOT 수량으로 나눕니다. Shop Order No와 Heat Code는 각 LOT와 민수 양식에 연결됩니다.')}${table(['구분','생산오더 / Shop Order','품번 / 품명','고객 / Project','수주수량','발주일 / 납기','Heat Code','상태','관리'],this.pagedCells(rows,r=>{const civil=isCivilOrder(r)||civilIds.has(r.id);return [civil?'민수':'방산',btn('orderDetail',r.code,r.id)+'<br>'+esc(r.data.shop_order_no||''),esc(r.data.part_no)+'<br>'+esc(r.title),esc(r.data.customer)+'<br>'+esc(r.data.project),num(r.data.qty),esc(r.data.order_date||'')+'<br>'+esc(r.data.due_date||'미정'),esc(r.data.heat_code||''),pill(r.state),btn('orderDetail','상세',r.id)+(permit(this.ctx,'orders','update')?btn('editOrder','수정',r.id)+(!civil&&!routedIds.has(r.id)&&r.state==='OPEN'?btn('markCivilOrder','민수로 지정',r.id):''):'')+(routing?btn('newRouting',civil?'민수 LOT 작성':'방산 Routing 작성',r.id):'')];}))}<div id="v4pager" class="pagination"></div></div>`);
  this.pageFooter(rows);
 }
 orderDetailFields(r,routes,view){
  const civil=isCivilOrder(r)||routes.some(isCivilRoute);
  return (civil?`<div><small>생산 구분</small><strong>민수</strong></div><div><small>Shop Order No</small><strong>${esc(r.data.shop_order_no||'미등록')}</strong></div><div><small>Heat Code</small><strong>${esc(r.data.heat_code||'미등록')}</strong></div>`:'')+super.orderDetailFields(r,routes,view);
 }
 async orderForm(r=null,forceCivil=false){
  if(!forceCivil&&(!r||!await this.civilOrder(r)))return super.orderForm(r);
  const d=r?.data||{};
  modal(r?'민수 수주 수정':'민수 수주 수기등록',`${notice('생산오더 관리번호는 신규 등록 시 자동 부여됩니다. 고객 Shop Order No와 Heat Code를 별도로 입력하세요.')}<div class="fields">${input('customer','고객명',d.customer,'text','required maxlength="80"')}${input('shop_order_no','Shop Order No',d.shop_order_no,'text','required maxlength="100"')}${input('heat_code','Heat Code',d.heat_code,'text','maxlength="100"')}${input('part_no','PART NUMBER / 품번',d.part_no,'text','required maxlength="100"')}${input('part_name','PART NAME / 품명',r?.title,'text','required maxlength="200"')}${input('qty','수주수량',d.qty,'number','required min="1" step="1"')}${input('order_date','수주일자',d.order_date||today(),'date','required')}${input('due_date','납기일자',d.due_date,'date')}${input('project','PJT / Project',d.project)}${input('model','MODEL',d.model)}${input('pwi_no','PWI No',d.pwi_no)}${input('material_spec','MATERIAL / 재질',d.material_spec)}${input('part_type','TYPE',d.part_type)}${input('qpa','QPA (선택)',d.qpa,'number','min="0" step="0.001"')}${input('set_qty','SET (선택)',d.set_qty,'number','min="0" step="0.001"')}${input('unit_price','참고 단가',d.unit_price,'number','min="0" step="0.01"')}${input('po_no','고객 PO 번호',d.po_no)}</div>${area('note','수주 비고',d.note||'')}<label class="check"><input type="checkbox" name="open_route" ${r?'':'checked'}>저장 후 민수 LOT 분할 작성</label>`,async(f,k)=>{
   const data={...d,...f,order_type:'CIVIL',qty:qty(f.qty,'수주수량',false),priority:d.priority||'NORMAL',production_no:r?d.production_no||r.code:''};
   delete data.open_route;data.unit_price=f.unit_price===''?null:money(f.unit_price);
   for(const field of ['qpa','set_qty'])data[field]=f[field]===''?null:Number(f[field]);
   const saved=await this.saveRpc('dnm_v410_save_order',{p:{id:r?.id,version:r?.version,data},k});
   if(f.open_route==='on'&&saved.id)setTimeout(async()=>{try{await this.civil.routingForm(await this.s.one(saved.id));}catch(e){message(e.message);}},75);
   return saved;
  });
 }
 async routingForm(order){return await this.civilOrder(order)?this.civil.routingForm(order):super.routingForm(order);}
 async routeDetail(id){const route=await this.s.one(id);return isCivilRoute(route)?this.civil.routeDetail(id):super.routeDetail(id);}
 async startForm(op){const route=await this.s.one(op.parent_id);return isCivilRoute(route)?this.fieldStart(op.id):super.startForm(op);}
 async manualForm(op,options={}){
  if(!options.submit&&op&&isCivilRoute(await this.s.one(op.parent_id)))return this.fieldStart(op.id,true);
  return super.manualForm(op,options);
 }
 async fieldStart(preselected='',manual=false){
  let result=await this.rpc('dnm_v410_work_choices',{p_operation:preselected||null});
  const jobs=(result.jobs||[]).filter(job=>!job.sequence_blocked);
  if(!preselected&&jobs.length)result=await this.rpc('dnm_v410_work_choices',{p_operation:jobs[0].id});
  const machines=[...(result.machines||[])].sort((a,b)=>a.title.localeCompare(b.title,'ko',{numeric:true})),employees=[...(result.employees||[])].sort((a,b)=>a.title.localeCompare(b.title,'ko'));
  if(!jobs.length)return modal('민수 작업 등록',notice('시작 가능한 민수 작업이 없습니다. LOT 배포, 본인 작업권한, 공정 진행 순서를 확인하세요.'));
  if(!machines.length||!employees.length)return modal('민수 작업 등록',notice('사용 중인 작업자와 설비가 필요합니다. 관리자가 작업자 연결 및 설비 사용 상태를 확인해야 합니다.'));
  const selected=jobs.find(j=>j.id===preselected)||jobs[0];
  const header=select('job','LOT / Shop Order / 공정',jobs.map(j=>[j.id,[j.route_code||j.lot,j.shop_order_no,j.data?.part_no,j.data?.op_code,j.title].filter(Boolean).join(' · ')]),selected.id,'required')+
   select('employee_id','실제 작업자',choices(employees),employees.find(e=>e.id===selected.data?.employee_id)?.id||employees[0].id,'required')+
   select('equipment_id','실제 사용 설비',[['','설비를 선택하세요'],...choices(machines)],machines.find(e=>e.id===selected.data?.equipment_id)?.id||'','required')+
   notice('이번 작업일보에 실제 작업자·설비를 기록합니다. 기존 계획 배정과 다른 작업일보는 바뀌지 않습니다.');
  const submit=(f,k)=>{const job=jobs.find(j=>j.id===f.job);if(!job)throw Error('LOT 공정을 선택하세요.');return this.saveRpc('dnm_v410_work',{act:manual?'manual':'start',p:{...f,id:job.id,version:job.version},k});};
  if(manual)await super.manualForm(null,{header,submit});
  else modal('민수 작업 시작 · 실제 배정 확인',header+input('work_date','작업일자',today(),'date','required'),submit,'작업 시작');
  const form=$('#v4form');let choiceTicket=0;
  form.elements.job.onchange=async()=>{const ticket=++choiceTicket;try{const fresh=await this.rpc('dnm_v410_work_choices',{p_operation:form.elements.job.value});if(ticket!==choiceTicket||!form.isConnected)return;const team=fresh.employees||[];form.elements.employee_id.innerHTML=choices(team).map(([id,label])=>`<option value="${esc(id)}">${esc(label)}</option>`).join('');const job=jobs.find(j=>j.id===form.elements.job.value);form.elements.equipment_id.value=job?.data?.equipment_id||'';}catch(e){message(e.message);}};
 }
 async finishForm(log,pending=false,complete=false){
  const op=await this.s.one(log.parent_id),route=await this.s.one(op.parent_id);
  if(!isCivilRoute(route))return super.finishForm(log,pending,complete);
  const result=await this.rpc('dnm_v410_work_choices',{p_operation:op.id});
  // Existing inactive assignees remain visible only for preserving history.
  const employees=[...(result.employees||[])],machines=[...(result.machines||[])];
  if(log.data.employee_id&&!employees.some(e=>e.id===log.data.employee_id))employees.push({id:log.data.employee_id,title:log.data.employee_name+' (기존 기록)'});
  if(log.data.equipment_id&&!machines.some(e=>e.id===log.data.equipment_id))machines.push({id:log.data.equipment_id,title:(log.data.equipment_name||log.data.equipment_code)+' (기존 기록)'});
  modal(pending?'민수 미확정 수량 확인':complete?'민수 공정 전량 완료':'민수 작업 종료 · 부분실적',notice(`${route.code} · ${op.title} · 지시 ${num(op.data.qty)}개 / 기존 확정 ${num(op.data.confirmed_qty)}개`)+`<div class="fields">${select('employee_id','실제 작업자',choices(employees),log.data.employee_id,'required')}${select('equipment_id','실제 사용 설비',choices(machines),log.data.equipment_id,'required')}${input('total','이번 총 처리수량',log.data.total??'','number','min="0" step="1"')}${input('defect','이번 불량수량',log.data.defect??0,'number','min="0" step="1"')}${input('work_date','작업일자',log.data.work_date||today(),'date','required')}</div>${area('change_reason','작업자·설비 변경 시 사유','','maxlength="500"')}${area('note','작업내용',log.data.note||'')}${area('defect_note','불량유형·비고',log.data.defect_note||'')}${!pending&&!complete?'<label class="check"><input name="pending" type="checkbox">수량 확인대기로 종료</label>':''}<label class="check"><input name="verified" type="checkbox" required>작업내용과 실제 작업자·설비·수량을 확인했습니다.</label>${notice('LOT 전체를 불량으로 종결하려면 이 작업의 수량을 먼저 확정한 후 민수 LOT 관리에서 불량 최종종결을 실행하세요.')}`,async(f,k)=>{
   const changed=f.employee_id!==log.data.employee_id||f.equipment_id!==log.data.equipment_id;
   if(changed&&!f.change_reason.trim())throw Error('실제 작업자 또는 설비를 바꾼 사유를 입력하세요.');
   const data=f.pending==='on'?{pending:true}:counts(f.total,f.defect);
   return this.saveRpc('dnm_v410_work',{act:'finish',p:{...f,...data,id:log.id,version:log.version,confirm_pending:pending,complete_operation:complete,input_mode:'touch'},k});
  },'확인 후 저장');
 }
 async command(action,payload,key){
  // Voice and legacy buttons also enter the same server validation path.
  if(['start_work','manual_work','finish_work','confirm_work'].includes(action)&&payload.id){
   const record=await this.s.one(payload.id),op=record.kind==='worklog'?await this.s.one(record.parent_id):record;
   if(isCivilRoute(await this.s.one(op.parent_id))){
    const p={...payload};
    if(!p.employee_id&&record.kind!=='worklog'){const team=await this.rpc('dnm_v410_work_choices',{p_operation:op.id});p.employee_id=team.employee_id||record.data.employee_id;}
    p.employee_id||=record.data.employee_id;p.equipment_id||=record.data.equipment_id;
    if(action==='confirm_work')p.confirm_pending=true;
    return this.saveRpc('dnm_v410_work',{act:action==='start_work'?'start':action==='manual_work'?'manual':'finish',p,k:key});
   }
  }
  return super.command(action,payload,key);
 }
 async action(action,id){
  if(!actionAllowed(this.ctx,action,id,this.page,this.cache.get(id)))throw Error('이 업무의 등록·수정 권한이 없습니다.');
  if(action==='newCivilOrder')return this.orderForm(null,true);
  if(action==='markCivilOrder')return this.orderForm(await this.s.one(id),true);
  if(action.startsWith('civil:'))return this.civil.action(action,id);
  if(action==='printRoute'){const route=await this.s.one(id);if(isCivilRoute(route))return this.civil.print(id);}
  return super.action(action,id);
 }
}
