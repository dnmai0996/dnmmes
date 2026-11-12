import {V410Controller} from './v410.js';
import {isCivilOrder,isCivilRoute} from './civil-domain.js';
import {routingSort} from './routing-domain.js';
import {sourceRows,compareSourceRows} from './source-review.js';
import {permit,actionAllowed,validateBundle} from './permissions.js';
import {$,esc,num,clock,btn,input,area,select,table,notice,message,modal,pill,exportCSV} from './ui.js';
import {counts,duration,toUTC} from './domain.js';

const localTime=value=>{const ms=Date.parse(value);return Number.isFinite(ms)?new Date(ms+32400000).toISOString().slice(0,16):'';};
const workDate=log=>log.data.work_date||localTime(log.data.start_at).slice(0,10);
const options=rows=>rows.map(row=>[row.id,[row.title||row.name,row.data?.department||row.code].filter(Boolean).join(' · ')]);

export class V4101Controller extends V410Controller {
 sourceImportLinks(){
  const count=sourceRows(this.bundle).length;if(!count)return '';
  return `<section class="notice" id="sourceImportLinks"><strong>원문 참조자료 ${num(count)}건</strong><p>이 자료는 「업로드 자료 · 과거 Routing」에서 조회합니다. 수주·작업지시·작업실적은 자동 생성하지 않습니다. 같은 LOT가 이미 있으면 기존 원문을 보존합니다.</p>${btn('showImportedSources','등록 자료 확인','','primary')}</section>`;
 }
 async archives(){
  const ticket=this.archiveTicket=(this.archiveTicket||0)+1,content=$('#content');
  const stored=await this.rec('source_routing');
  if(this.page!=='archives'||ticket!==this.archiveTicket||content!==$('#content'))return;
  const bundle=this.sourceBundle||this.bundle,hasBundle=sourceRows(bundle).length>0;
  const comparison=hasBundle?compareSourceRows(bundle,stored):null;this.sourceComparison=comparison;
  if(this.sourceView==='bundle'&&!hasBundle)this.sourceView='all';
  const view=this.sourceView||'all';
  const reviewByCode=new Map(comparison?.rows.map(row=>[row.source.code,row])||[]);
  let rows=view==='bundle'?sourceRows(bundle):view==='bush'?stored.filter(r=>r.data.source_family==='DNM_BUSH_XLSM'):stored;
  rows=this.filter(rows);
  const options=[['all','DB 원문 전체'],['bush','새로 등록된 민수 부싱'],...(hasBundle?[['bundle','선택 파일 · DB 등록 대조']]:[])];
  const summary=comparison?`<div class="kpis" id="sourceMatchSummary"><article>파일 원문<strong>${num(comparison.total)}</strong></article><article>DB에 원문 있음<strong>${num(comparison.matched)}</strong><small>기존 동일 LOT 보존 ${num(comparison.existing)}건 포함</small></article><article>DB 원문 미확인<strong>${num(comparison.missing)}</strong></article><article>동일 LOT 원문 여러 건<strong>${num(comparison.multiple)}</strong></article></div>
   ${notice('선택 파일: '+(this.sourceBundleName||bundle.bundle_id)+'\n「DB에 원문 있음」은 코드 또는 LOT가 일치한다는 뜻입니다. 기존 원문의 내용이 업로드 파일로 변경되었다는 뜻은 아닙니다. 원문을 비교하여 확인하세요.')}`:'';
  this.set(`<div class="card">${this.top(this.ctx.profile.role==='admin'?btn('openSourceImport','자료 일괄등록'):'')}
   ${notice('업로드한 원문 자료의 조회 화면입니다. 기존 동일 LOT가 보존되어 필터에서 보이지 않는 경우, 아래에서 업로드했던 JSON 파일을 선택하면 DB 등록 여부를 대조합니다. 파일 선택은 조회만 하며 DB에 저장하지 않습니다.')}
   ${input('sourceCheckFile','업로드한 JSON 파일로 등록 여부 확인','','file','id="sourceCheckFile" accept=".json,.dnm.json"')}
   ${summary}${select('sourceView','조회자료',options,view,'id="sourceView"')}
   ${view==='bush'?notice('이 필터는 새 민수 부싱 형식으로 저장된 원문만 표시합니다. 이전 형식의 동일 LOT는 「DB 원문 전체」 또는 파일 대조로 확인하세요.'):''}
   ${view==='bundle'?notice('아래 품번·품명·수량·날짜는 선택 파일의 원문입니다. DB 미확인 행도 함께 표시하며, 실제 저장 내용은 「DB 원문」에서 확인합니다. 민수 부싱 확인대기는 납품완료일 미기재 후보이며 현재 작업 중으로 확정된 자료가 아닙니다.'):''}
   ${table(['원본 LOT','품번 / 품명','형식','S/O','Heat Code','LOT 수량','투입일','등록 확인','원문 보기'],this.pagedCells(rows,r=>{
    const match=view==='bundle'?reviewByCode.get(r.code):null;
    return [esc(r.data.lot||r.title),esc(r.data.part_no||r.data.part_revision)+'<br>'+esc(r.data.part_name),esc(r.data.part_type||r.data.work_type||''),esc(r.data.shop_order_no||r.data.so_raw||'미기재'),esc(r.data.heat_code||'미기재'),r.data.qty==null?'미기재':esc(r.data.qty),esc(r.data.input_date),
     match?match.status==='missing'?'<strong>DB 원문 미확인</strong>':match.status==='existing-lot'?'기존 동일 LOT 보존':'같은 코드 원문 있음':r.data.source_family==='DNM_BUSH_XLSM'?'재공 확인대기 · DB 원문':'DB 원문',
     match?btn('sourceCompare','파일·DB 비교',r.code)+match.matches.map(row=>btn('masterDetail','DB 원문',row.id)).join(''):btn('masterDetail','DB 원문',r.id)];
   }))}<div id="v4pager" class="pagination"></div></div>`);
  this.pageFooter(rows);
  $('#sourceView').onchange=event=>{this.sourceView=event.target.value;this.pageNo=1;this.archives().catch(e=>message(e.message));};
  const fileInput=$('#sourceCheckFile');fileInput.onchange=async event=>{
   try{
    const file=event.target.files[0];if(!file)return;if(file.size>35*1024*1024)throw Error('파일은 35MB 이내입니다.');
    const book=JSON.parse(await file.text());validateBundle(book);
    if(!sourceRows(book).length)throw Error('원본 Routing 자료가 포함된 .dnm.json 파일을 선택하세요.');
    if(!fileInput.isConnected||this.page!=='archives')return;
    this.sourceBundle=book;this.sourceBundleName=file.name;this.sourceView='bundle';this.pageNo=1;this.search='';await this.archives();
   }catch(error){message(error.message);}
  };
 }
 showSourceComparison(code){
  const row=this.sourceComparison?.rows.find(item=>item.source.code===code);if(!row)throw Error('파일을 다시 선택하여 대조하세요.');
  const fields=[['관리코드',r=>r.code],['LOT',r=>r.data.lot||r.title],['품번',r=>r.data.part_no||r.data.part_revision],['품명',r=>r.data.part_name],['형식',r=>r.data.part_type||r.data.work_type],['S/O',r=>r.data.shop_order_no||r.data.so_raw],['Heat Code',r=>r.data.heat_code],['LOT 수량',r=>r.data.qty],['투입일',r=>r.data.input_date],['납품일',r=>r.data.delivery_date],['비고',r=>r.data.note]];
  const value=v=>v===null||v===undefined||v===''?'미기재':esc(v);
  modal('업로드 파일 · DB 원문 비교',notice('선택 파일은 검토용입니다. 아래 DB 원문은 변경하지 않습니다. DB 미확인은 이 계정으로 조회한 원문에서 일치하는 코드·LOT를 찾지 못했다는 뜻입니다.')+
   table(['항목','선택 파일',...(row.matches.length?row.matches.map((_,i)=>'DB 원문 '+(i+1)):['DB 원문'])],fields.map(([label,get])=>[label,value(get(row.source)),...(row.matches.length?row.matches.map(item=>value(get(item))):['미확인'])])));
 }
 help(){
  if(this.page==='archives')return modal('업로드 자료 확인 · 사용방법',notice('1. 업로드했던 .dnm.json 파일을 선택합니다. DB에 다시 저장하지 않고 조회만 합니다.\n2. 파일 원문 / DB에 원문 있음 / DB 원문 미확인 건수를 확인합니다.\n3. 기존 동일 LOT 보존도 조회되며 파일·DB 비교에서 내용을 대조합니다.\n4. 등록이 필요하면 관리자만 「자료 일괄등록」에서 파일 선택·검토 후 등록합니다. 수주·실적은 원문에서 자동 생성하지 않습니다.'));
  return super.help();
 }
 async saveRpc(name,args){
  if(name==='dnm_v410_save_order')name='dnm_v4101_save_order';
  return super.saveRpc(name,args);
 }
 async orders(){
  const ticket=++this.orderViewTicket,content=$('#content');this.detail=null;
  const [orders,routes]=await Promise.all([this.rec('order'),this.rec('routing')]);
  if(this.page!=='orders'||this.detail||ticket!==this.orderViewTicket||content!==$('#content'))return;
  const civilIds=new Set(routes.filter(isCivilRoute).map(r=>r.parent_id));
  const civil=order=>isCivilOrder(order)||civilIds.has(order.id);
  const routedIds=new Set(routes.map(r=>r.parent_id));
  const balances=new Map((await this.rpc('dnm_v4101_balances',{ids:orders.filter(civil).map(r=>r.id)})).rows.map(r=>[r.id,r]));
  if(this.page!=='orders'||this.detail||ticket!==this.orderViewTicket||content!==$('#content'))return;
  const rows=this.filter(orders).filter(r=>this.orderView==='deleted'?r.data.deleted===true:r.data.deleted!==true).sort(routingSort);
  const create=permit(this.ctx,'orders','create'),update=permit(this.ctx,'orders','update'),routing=permit(this.ctx,'routing','create');
  this.set(`<div class="card">${this.top(create?btn('newCivilOrder','민수 수주 수기등록','','primary')+btn('newOrder','방산 수주 직접등록')+btn('importOrders','방산 수주 Excel 등록'):'')}
   ${select('orderView','목록',[['current','현재 수주'],['deleted','삭제 이력']],this.orderView||'current','id="orderView"')}
   ${notice('민수 수주의 미배정 잔량 = 수주수량 − 삭제·취소 LOT를 제외한 배정합계입니다. 완료·불량 종결 LOT는 배정합계에 포함합니다. 잔량이 있으면 추가 LOT를 작성할 수 있습니다.')}
   ${table(['구분','생산오더 / Shop Order','품번 / 품명','고객','수주수량','LOT 배정합계','미배정 잔량','납기 / Heat Code','상태','관리'],this.pagedCells(rows,r=>{
    const isCivil=civil(r),balance=balances.get(r.id),active=r.data.deleted!==true;
    return [isCivil?'민수':'방산',btn('orderDetail',r.code,r.id)+'<br>'+esc(r.data.shop_order_no||''),esc(r.data.part_no)+'<br>'+esc(r.title),esc(r.data.customer),num(r.data.qty),
     balance?num(balance.allocated):'—',balance?`<strong>${num(balance.remaining)}</strong>`:'—',esc(r.data.due_date||'미정')+'<br>'+esc(r.data.heat_code||''),active?pill(r.state):'삭제',
     btn('orderDetail','상세',r.id)+(active&&update?btn('editOrder','수정',r.id)+(isCivil?btn('deleteCivilOrder','삭제',r.id):!routedIds.has(r.id)&&r.state==='OPEN'?btn('markCivilOrder','민수로 지정',r.id):''):'')+
     (active&&routing&&r.state==='OPEN'&&(!isCivil||Number(balance?.remaining)>0)?btn('newRouting',isCivil?'잔량 LOT 추가':'Routing 작성',r.id):'')];
   }))}<div id="v4pager" class="pagination"></div></div>`);
  this.pageFooter(rows);$('#orderView').onchange=event=>{this.orderView=event.target.value;this.pageNo=1;this.orders().catch(e=>message(e.message));};
 }
 async orderDetailData(order,routes){
  if(!isCivilOrder(order)&&!routes.some(isCivilRoute))return {};
  const {rows:[balance]}=await this.rpc('dnm_v4101_balances',{ids:[order.id]});
  return {balance,routingAllowed:!order.data.deleted&&order.state==='OPEN'&&Number(balance?.remaining)>0,routingLabel:'잔량 LOT 추가 작성',
   actions:permit(this.ctx,'orders','update')&&!order.data.deleted?btn('editOrder','민수 수주 수정',order.id)+btn('deleteCivilOrder','민수 수주 삭제',order.id):''};
 }
 orderDetailFields(order,routes,view){
  return super.orderDetailFields(order,routes,view)+(view.balance?
   `<div><small>LOT 배정합계</small><strong>${num(view.balance.allocated)}</strong></div><div><small>미배정 잔량</small><strong>${num(view.balance.remaining)}</strong></div>`:'');
 }
 async orderForm(order=null,forceCivil=false){
  await super.orderForm(order,forceCivil);
  if(order&&(forceCivil||await this.civilOrder(order))){
   const form=$('#v4form');if(form)form.querySelector('.modalbody')?.insertAdjacentHTML('afterbegin',notice('배정된 LOT 합계보다 수주수량을 줄일 수 없습니다. 기존 LOT의 수량은 별도로 조정합니다. 마감 수주의 수량을 늘리면 추가 LOT 작성을 위해 다시 진행 상태가 됩니다.'));
  }
 }
 async deleteCivil(kind,id){
  const target=await this.s.one(id);
  modal((kind==='order'?'민수 수주 삭제':'실적 0 LOT 삭제')+' · '+target.code,
   notice(kind==='order'?'작업·검사·출하 실적이 없는 수주와 하위 LOT를 삭제 처리합니다. 실적이 있는 수주에서는 실적 0인 개별 LOT만 삭제하세요.':'수주에 다른 LOT가 작업 중이거나 완료되어도 이 LOT의 실적이 0이면 삭제할 수 있습니다. 진행·확인대기 작업은 먼저 종료·확정하세요.')+
   notice('삭제 대상은 현재 목록에서 제외되며 자료와 변경 이력은 보관합니다.')+
   area('reason','삭제 사유','','required maxlength="1000"')+'<label class="check"><input type="checkbox" name="reviewed" required>대상과 삭제 조건을 확인했습니다.</label>',async(form,k)=>{
    if(form.reviewed!=='on')throw Error('삭제 대상을 확인하세요.');
    const result=await this.rpc('dnm_v4101_delete',{kind,p:{id,version:target.version,reason:form.reason},k});
    if(kind==='order')this.detail=null;
    return this.refreshAfterSave(result);
   },'삭제 처리');
 }
 async loadLogEditStatus(logs){
  if(!permit(this.ctx,'worklogs','read')){this.logEditStatus=new Map();return;}
  const ids=logs.filter(log=>log.state==='CONFIRMED').map(log=>log.id);
  const statuses=ids.length?(await this.rpc('dnm_v4101_edit_status',{ids})).rows:[];
  this.logEditStatus=new Map(statuses.map(row=>[row.id,row]));
 }
 logEditButton(log){
  const status=this.logEditStatus?.get(log.id);
  return status?.editable?btn('editWorklog','수정·비고',log.id):status?.final_locked?'<small>최종공정 종료 · 관리자만 수정</small>':'—';
 }
 async worklogs(){
  let rows=this.filter(await this.rec('worklog'));
  const workers=[...new Set(rows.map(log=>log.data.employee_name).filter(Boolean))].sort((a,b)=>a.localeCompare(b,'ko'));
  if(this.logDate)rows=rows.filter(log=>workDate(log)===this.logDate);
  if(this.logWorker)rows=rows.filter(log=>log.data.employee_name===this.logWorker);
  await this.loadLogEditStatus(rows);if(this.page!=='worklogs')return;
  this.visibleLogs=rows;
  this.set(`<div class="card">${this.top(btn('printLogs','작업일보 인쇄')+btn('exportVisibleLogs','CSV 내보내기'))}
   ${notice('등록 완료된 작업일보의 수량·시간·작업내용·비고를 수정할 수 있습니다. 해당 Routing의 마지막 공정이 종료되면 시스템 관리자만 수정할 수 있으며 수정 사유와 이전 값이 기록됩니다.')}
   <div class="filter-bar">${input('logDate','작업일(전체는 공란)',this.logDate,'date','id="logDate"')}${select('logWorker','작업자',[['','전체'],...workers.map(name=>[name,name])],this.logWorker,'id="logWorker"')}</div>
   ${table(['작업일','시작 / 종료','생산오더 / 공정','설비 / 작업자','총 / 양품 / 불량','작업시간','비고','상태','관리'],this.pagedCells(rows,log=>[
    esc(workDate(log)),esc(clock(log.data.start_at))+'<br>'+esc(clock(log.data.end_at)),esc(log.data.production_no)+'<br>'+esc(log.title),esc(log.data.equipment_name||log.data.equipment_code)+'<br>'+esc(log.data.employee_name),
    log.state==='CONFIRMED'?`${num(log.data.total)} / ${num(log.data.good)} / ${num(log.data.defect)}`:'미확정',esc(duration(log.data.minutes)),esc(log.data.memo||''),pill(log.state),
    log.state==='ACTIVE'?btn('pauseLog','일시중지',log.id)+btn('stopLog','작업 종료',log.id):log.state==='PENDING'?btn('confirmLog','수량 확인',log.id):this.logEditButton(log)+
    (log.state==='CONFIRMED'&&this.able('production')&&(!this.logEditStatus?.get(log.id)?.final_locked||this.ctx.profile.role==='admin')?btn('cancelLog','사유취소',log.id):'')
   ]))}<div id="v4pager" class="pagination"></div></div>`);
  this.pageFooter(rows);
  $('#logDate').onchange=event=>{this.logDate=event.target.value;this.pageNo=1;this.worklogs().catch(e=>message(e.message));};
  $('#logWorker').onchange=event=>{this.logWorker=event.target.value;this.pageNo=1;this.worklogs().catch(e=>message(e.message));};
 }
 async editWorklog(id){
  const log=await this.s.one(id);await this.loadLogEditStatus([log]);
  if(!this.logEditStatus.get(id)?.editable)throw Error('수정 권한이 없거나 마지막 공정이 종료되었습니다. 시스템 관리자에게 확인하세요.');
  const op=await this.s.one(log.parent_id),route=await this.s.one(op.parent_id),d=log.data;
  let team='';
  if(isCivilRoute(route)){
   const refs=await this.rpc('dnm_v410_work_choices',{p_operation:op.id});
   const employees=[...(refs.employees||[])],machines=[...(refs.machines||[])];
   if(!employees.some(row=>row.id===d.employee_id))employees.push({id:d.employee_id,title:d.employee_name+' (기존 기록)'});
   if(!machines.some(row=>row.id===d.equipment_id))machines.push({id:d.equipment_id,title:(d.equipment_name||d.equipment_code)+' (기존 기록)'});
   team=select('employee_id','실제 작업자',options(employees),d.employee_id,'required')+select('equipment_id','실제 설비',options(machines),d.equipment_id,'required');
  }
  modal('작업일보 수정 · '+log.title,notice(`${route.code} · ${d.employee_name||''}${this.logEditStatus.get(id).final_locked?' · 최종공정 종료 후 관리자 정정':''}`)+
   `<div class="fields">${input('total','총 처리수량',d.total,'number','required min="0" step="1"')}${input('defect','불량수량',d.defect||0,'number','required min="0" step="1"')}
   ${input('work_date','작업일자',workDate(log),'date','required')}${input('start_at','시작시간',localTime(d.start_at),'datetime-local','required')}${input('end_at','종료시간',localTime(d.end_at),'datetime-local','required')}${team}</div>
   ${area('note','작업내용',d.note||'','maxlength="4000"')}${area('defect_note','불량내용',d.defect_note||'','maxlength="4000"')}${area('memo','비고 · 참고 메모',d.memo||'','maxlength="4000"')}
   ${area('reason','수정 사유','','required maxlength="1000"')}<label class="check"><input type="checkbox" name="reviewed" required>변경할 내용을 확인했습니다.</label>`,(form,k)=>{
    if(form.reviewed!=='on')throw Error('수정 내용을 확인하세요.');
    return this.saveRpc('dnm_v4101_edit_work',{p:{...form,...counts(form.total,form.defect),id,version:log.version,start_at:form.start_at===localTime(d.start_at)?d.start_at:toUTC(form.start_at),end_at:form.end_at===localTime(d.end_at)?d.end_at:toUTC(form.end_at)},k});
   },'수정 저장');
 }
 addMemo(log){const form=$('#v4form');if(form&&!form.elements.memo&&form.querySelector('[name="note"]'))form.querySelector('.modalbody').insertAdjacentHTML('beforeend',area('memo','비고 · 참고 메모',log?.data?.memo||'','maxlength="4000"'));}
 async manualForm(...args){const result=await super.manualForm(...args);this.addMemo();return result;}
 async fieldStart(...args){const result=await super.fieldStart(...args);this.addMemo();return result;}
 async finishForm(log,...args){const result=await super.finishForm(log,...args);this.addMemo(log);return result;}
 async command(action,payload,key){
  const memo=$('#v4form')?.elements.memo;
  if(memo&&['manual_work','finish_work','confirm_work'].includes(action))payload={...payload,memo:memo.value};
  return super.command(action,payload,key);
 }
 async action(action,id){
  if(!actionAllowed(this.ctx,action,id,this.page,this.cache.get(id)))throw Error('이 업무의 등록·수정 권한이 없습니다.');
  if(action==='showImportedSources'){this.sourceBundle=this.bundle;this.sourceBundleName='';this.sourceView='bundle';return this.go('archives');}
  if(action==='sourceCompare')return this.showSourceComparison(id);
  if(action==='openSourceImport'){if(this.ctx.profile.role!=='admin')throw Error('관리자만 자료를 등록할 수 있습니다.');return this.go('seedData');}
  if(action==='deleteCivilOrder')return this.deleteCivil('order',id);
  if(action==='civil:deleteZero')return this.deleteCivil('lot',id);
  if(action==='editWorklog')return this.editWorklog(id);
  if(action==='exportVisibleLogs')return exportCSV('DNM_작업일보.csv',[['생산오더','품번','공정','설비','작업자','시작','종료','공수(분)','총수량','양품','불량','상태','작업내용','비고'],...this.visibleLogs.map(log=>[log.data.production_no,log.data.part_no,log.title,log.data.equipment_code,log.data.employee_name,log.data.start_at,log.data.end_at,log.data.minutes,log.data.total,log.data.good,log.data.defect,log.state,log.data.note,log.data.memo])]);
  return super.action(action,id);
 }
}
