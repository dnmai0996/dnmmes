import {$,all,area,btn,esc,input,message,modal,notice,num,select,table,exportCSV} from './ui.js';
import {validateBundle} from './permissions.js';
import {sourceRows} from './source-review.js';
import {civilOrderChoices} from './civil-domain.js';
import {assertTransferGroup,currentStates,reviewValues,sourceProcessSteps,transferLabels,transferRows} from './source-transfer-domain.js';
import {mountSteps} from './step-editor.js';
import {blankStep} from './routing-domain.js';
const today=()=>new Date(Date.now()+32400000).toISOString().slice(0,10);
const button=(act,label,id='',style='secondary')=>btn('transfer:'+act,label,id,style);
const stateLabel=v=>currentStates.find(([key])=>key===v)?.[1]||'확인대기';
export class SourceTransferUI {
 constructor(main){this.main=main;this.selected=new Set();this.resolved=new Map();this.view='pending';this.part='';this.ticket=0;this.lastResult=null;this.batchLimit=100;}
 require(){if(this.main.ctx.profile.role!=='admin')throw Error('관리자만 원문 자료를 운영 전환할 수 있습니다.');}
 get bundle(){return this.main.sourceBundle||this.main.bundle;}
 selectedRows(){return this.rows.filter(row=>this.selected.has(row.id));}
 async load(){
  this.require();const ticket=++this.ticket,content=$('#content');
  const [stored,routes,orders]=await Promise.all(['source_routing','routing','order'].map(kind=>this.main.rec(kind)));
  if(ticket!==this.ticket||this.main.page!=='civilTransfer'||content!==$('#content'))return;
  this.orders=orders;this.routes=routes;this.rows=transferRows(stored,routes,this.bundle,this.resolved);
  for(const key of this.selected)if(!this.rows.some(row=>row.id===key&&row.source&&!row.route))this.selected.delete(key);
  const parts=[...new Set(this.rows.map(row=>JSON.stringify([row.data.part_no,row.data.part_type])))].sort((a,b)=>a.localeCompare(b,'ko'));
  if(this.part&&!parts.includes(this.part))this.part='';
  let rows=this.main.filter(this.rows).filter(row=>!this.part||JSON.stringify([row.data.part_no,row.data.part_type])===this.part);
  if(this.view==='pending')rows=rows.filter(row=>!['CONVERTED','EXCLUDED'].includes(row.status));
  if(this.view==='converted')rows=rows.filter(row=>row.status==='CONVERTED');
  if(this.view==='excluded')rows=rows.filter(row=>row.status==='EXCLUDED');
  this.visible=rows;
  const result=this.lastResult;
  this.main.set(`<div class="card">${this.main.top(button('convert','선택 자료 수주·작업지시 전환','','primary'))}
   ${notice('등록된 원문을 확인한 뒤 실제 수주·LOT·작업지시로 전환합니다. LOT 수량과 현재 상태를 확인하고, 품번·TYPE이 같은 자료끼리 선택하세요. 이미 전환한 LOT는 중복 생성하지 않습니다.')}
   ${input('transferFile','업로드했던 JSON 선택 (기존 LOT 대조·원문 공정 불러오기)','','file','id="transferFile" accept=".json,.dnm.json"')}
   ${sourceRows(this.bundle).length?notice('선택 자료묶음: '+this.bundle.bundle_id+' · '+num(sourceRows(this.bundle).length)+'개 LOT'):notice('현재 DB 원문을 표시합니다. 예전 형식으로 저장된 자료는 업로드했던 JSON을 선택하면 올바른 원문 항목과 대조할 수 있습니다.')}
   ${result?`<section class="notice" id="transferResult"><strong>운영 전환 ${num(result.created)}개 LOT · 확인사항 ${num(result.issues?.length||0)}건</strong><p>${!result.created?'이번 요청에서 새로 전환된 LOT가 없습니다. 아래 확인사항을 검토하세요.':result.released?'전환된 LOT는 작업지시가 배포되었습니다. 실제 작업자·설비를 선택하여 작업실적을 등록하세요.':'전환된 LOT는 초안입니다. 민수 LOT에서 공정 확인 후 작업지시를 배포하세요.'}</p><div class="actions">${result.order_id?button('order','연결 수주 보기',result.order_id):''}${button('routes','민수 LOT 보기')}${button('work','작업지시 보기')}</div>${result.issues?.length?table(['LOT','확인할 내용'],result.issues.map(row=>[esc(row.lot),esc(row.message)])):''}</section>`:''}
   <div class="filter-bar">${select('transferView','처리 상태',[['pending','전환대기·문제 확인'],['converted','전환 완료'],['excluded','제외'],['all','전체']],this.view,'id="transferView"')}
   ${select('transferPart','품번 / TYPE',[['','전체 품번'],...parts.map(key=>[key,JSON.parse(key).filter(Boolean).join(' · ')||'품번 미기재'])],this.part,'id="transferPart"')}${select('transferBatch','한 번에 선택할 LOT 수',[[100,'100개'],[200,'200개'],[500,'500개']],this.batchLimit,'id="transferBatch"')}</div>
   <div class="actions">${button('select','검색결과 선택')}${button('clear','선택 해제')}${button('exclude','선택 자료 제외')}${button('reopen','선택 자료 재검토')}${button('export','문제·보완 목록 CSV')}<strong id="transferSelected">선택 ${num(this.selected.size)}건</strong></div>
   ${table(['선택','원본 LOT','품번 / 품명 / TYPE','LOT 수량','현재 상태','처리 상태','확인·보완 사항','관리'],this.main.pagedCells(rows,row=>[
    `<input type="checkbox" data-transfer-select="${esc(row.id)}" aria-label="${esc(row.code)} 선택" ${this.selected.has(row.id)?'checked':''} ${!row.source||row.route?'disabled':''}>`,
    esc(row.code),esc(row.data.part_no)+'<br>'+esc(row.data.part_name)+'<br>'+esc(row.data.part_type),row.data.qty==null?'미기재':num(row.data.qty),esc(stateLabel(row.data.current_state)),esc(transferLabels[row.status]),
    esc([...row.problems,...(row.lastError?[row.lastError]:[])].join(' / ')||'필수 원문 항목 확인됨'),
    row.route?button('route','LOT·작업 등록',row.route.id):button('review','확인·보완',row.id)
   ]))}<div id="v4pager" class="pagination"></div></div>`);
  this.main.pageFooter(rows);
  all('[data-transfer-select]').forEach(field=>field.onchange=()=>{if(field.checked&&this.selected.size>=500){field.checked=false;message('한 번에 500건까지 선택하세요.');return;}field.checked?this.selected.add(field.dataset.transferSelect):this.selected.delete(field.dataset.transferSelect);$('#transferSelected').textContent='선택 '+num(this.selected.size)+'건';});
  $('#transferBatch').onchange=event=>{this.batchLimit=Number(event.target.value);};
  $('#transferView').onchange=event=>{this.view=event.target.value;this.main.pageNo=1;this.load().catch(error=>message(error.message));};
  $('#transferPart').onchange=event=>{this.part=event.target.value;this.main.pageNo=1;this.load().catch(error=>message(error.message));};
  const fileInput=$('#transferFile');fileInput.onchange=async event=>{try{
   const file=event.target.files[0];if(!file)return;if(file.size>35*1024*1024)throw Error('파일은 35MB 이내입니다.');
   const bundle=JSON.parse(await file.text());validateBundle(bundle);if(!sourceRows(bundle).length)throw Error('원본 LOT가 포함된 JSON을 선택하세요.');
   if(!fileInput.isConnected||this.main.page!=='civilTransfer')return;
   this.main.sourceBundle=bundle;this.main.sourceBundleName=file.name;this.selected.clear();this.resolved.clear();this.main.pageNo=1;this.main.search='';await this.load();
  }catch(error){message(error.message);}};
 }
 async review(key){
  this.require();const row=this.rows.find(r=>r.id===key);if(!row)throw Error('원문 목록을 다시 조회하세요.');
  if(!row.source){
   if(!row.matches.length)return modal('원문 등록 확인',notice('이 LOT의 원문이 DB에 없습니다. 「초기구축·운영 → 첨부자료 일괄등록」에서 원문 파일 등록을 완료한 뒤 다시 조회하세요.'));
   return modal('같은 LOT 원문 확인',notice('같은 LOT의 원문이 여러 건입니다. 실제 사용할 원문 한 건을 확인하세요. 기존 원문을 삭제하거나 합치지 않습니다.')+
    table(['관리코드','기존 품번','기존 품명'],row.matches.map(r=>[esc(r.code),esc(r.data.part_no||r.data.part_revision),esc(r.data.part_name)]))+
    select('source_id','사용할 원문',[['','선택'],...row.matches.map(r=>[r.id,r.code])],'','required'),async form=>{this.resolved.set(key,form.source_id);await this.load();},'이 원문으로 검토');
  }
  const v=row.data;
  modal('원문 확인·보완 · '+v.lot,notice('원본 값은 보존하고 운영 전환용 보완값을 따로 저장합니다. 수량·현재 상태가 미확인인 행은 작업지시로 전환하지 않습니다.')+
   `<div class="fields">${input('part_no','품번',v.part_no,'text','required maxlength="100"')}${input('part_name','품명',v.part_name,'text','required maxlength="200"')}
   ${input('part_type','TYPE',v.part_type,'text','maxlength="100"')}${input('qty','LOT 수량 (미확인은 공란)',v.qty??'','number','min="1" step="1"')}
   ${select('current_state','현재 진행상태',currentStates,v.current_state)}${input('input_date','원본 투입일',v.input_date,'date')}
   ${input('shop_order_no','Shop Order No',v.shop_order_no,'text','maxlength="100"')}${input('heat_code','Heat Code',v.heat_code,'text','maxlength="100"')}</div>${area('note','원문 보완 메모',v.note,'maxlength="2000"')}${area('reason','보완 근거·사유','','required maxlength="1000"')}`,async(form,key)=>{
    const {reason,...values}=form;await this.main.rpc('dnm_v4103_source_review',{p:{action:'save',rows:[{id:row.source.id,version:row.source.version,values}],reason},k:key});await this.main.refreshAfterSave({ok:true});
   },'보완내용 저장');
 }
 async mark(action){
  this.require();const rows=this.selectedRows();if(!rows.length)throw Error('자료를 선택하세요.');
  if(rows.some(row=>!row.source||row.route))throw Error('운영 전환되지 않은 원문을 선택하세요.');
  modal(action==='exclude'?'선택 원문 제외':'선택 원문 재검토',notice(`${rows.length}개 원문을 ${action==='exclude'?'전환 대상에서 제외합니다. 원본은 보존합니다.':'검토대기로 돌립니다. 삭제·취소된 운영 LOT 이력도 보존합니다.'}`)+area('reason','처리 사유','','required maxlength="1000"'),async(form,key)=>{
   await this.main.rpc('dnm_v4103_source_review',{p:{action,rows:rows.map(row=>({id:row.source.id,version:row.source.version})),reason:form.reason},k:key});this.selected.clear();await this.main.refreshAfterSave({ok:true});
  },action==='exclude'?'제외 처리':'재검토 처리');
 }
 async convert(){
  this.require();const rows=this.selectedRows(),{part,type}=assertTransferGroup(rows);
  const [refs,templates]=await Promise.all([this.main.refData(),this.main.rec('route_template')]);
  const orders=civilOrderChoices(this.orders,this.routes,{openOnly:true}).filter(order=>order.data.part_no===part);
  const templateChoices=templates.filter(t=>(t.data.part_no||t.code)===part&&t.data.active!==false&&t.data.review_required===false&&t.data.steps?.length);
  const raw=sourceProcessSteps(this.bundle,type);
  const sources=[...(raw.length?[{id:'source',title:'원문 TYPE '+type+' 공정 초안 (확인 필요)',steps:raw}]:[]),...templateChoices.map(t=>({id:t.id,title:t.code+' · 검토완료 공정',steps:t.data.steps})),{id:'manual',title:'공정 직접 작성',steps:[{...blankStep(),independent:false}]}];
  let source=sources[0],editor,frozenPayload;
  const managers=(this.main.ctx.people||[]).filter(p=>p.production||p.role==='admin');
  const manager=managers.some(p=>p.id===this.main.ctx.profile.id)?this.main.ctx.profile.id:'';
  const allocated=id=>this.routes.filter(r=>r.parent_id===id&&r.data.daily&&!['CANCELLED','SUPERSEDED'].includes(r.state)).reduce((n,r)=>n+Number(r.data.qty||0),0);
  modal('원문 → 수주·LOT·작업지시 전환',notice(`품번 ${part} / TYPE ${type||'미기재'} · ${rows.length}개 LOT. 원본 LOT 번호는 유지하며 내부 Routing 관리번호는 별도로 부여됩니다.`)+
   select('order_id','연결 수주 / Shop Order',[['','새 민수 수주 생성'],...orders.map(o=>[o.id,[o.data.shop_order_no||o.code,o.title,'미배정 '+num(Number(o.data.qty)-allocated(o.id))+'개'].join(' · ')])],orders.length===1?orders[0].id:'','id="transferOrder"')+
   `<section id="transferNewOrder"><div class="fields">${input('customer','고객명','','text','required maxlength="80"')}${input('part_name','수주 품명',rows[0].data.part_name,'text','required maxlength="200"')}
   ${input('order_qty','수주 전체 수량','','number','required min="1" step="1" id="transferOrderQty"')}${input('shop_order_no','수주 Shop Order No',rows[0].data.shop_order_no,'text','maxlength="100"')}
   ${input('heat_code','기본 Heat Code',rows[0].data.heat_code,'text','maxlength="100"')}${input('due_date','납기일','','date')}</div></section>
   <div class="fields">${input('plan_date','작업 예정일',today(),'date','required')}${select('manager_id','담당 생산관리자',[['','선택'],...managers.map(p=>[p.id,p.name])],manager,'required')}</div>
   <div class="fields">${input('default_qty','빈칸에 넣을 LOT 수량','','number','min="1" step="1" id="transferDefaultQty"')}${select('default_state','확인대기 행에 넣을 현재 상태',currentStates,'','id="transferDefaultState"')}</div>
   <button type="button" class="secondary" id="transferFill">위 값으로 미확인 빈칸 채우기</button>
   ${table(['원본 LOT','LOT 수량','현재 상태'],rows.map((row,i)=>[esc(row.code),input('qty_'+i,row.code+' 수량',row.data.qty??'','number',`min="1" step="1" data-transfer-qty="${i}"`),select('state_'+i,row.code+' 현재 상태',currentStates,row.data.current_state,`data-transfer-state="${i}"`)]))}
   <p id="transferTotal" role="status"></p>
   ${select('steps_source','사용할 공정',sources.map(s=>[s.id,s.title]),source.id,'id="transferStepsSource"')}
   ${notice('원문 공정은 초안입니다. 처리구분·검사·순서 무관 여부를 확인하세요. 설비와 작업자는 계획 시 배정하거나 실제 작업일보 등록 시 선택할 수 있습니다.')}
   <div id="transferSteps" class="civil-sequence civil-step-editor"></div>
   <label class="check"><input type="checkbox" name="release_now" checked>작업지시를 배포하여 바로 실적등록 가능하게 합니다.</label>
   <label class="check"><input type="checkbox" name="skip_invalid" checked>수량·상태 등 문제가 있는 행은 제외하고 가능한 행만 전환합니다.</label>
   <label class="check"><input type="checkbox" name="allow_missing_refs">S/O·Heat Code 미기재 항목을 확인했으며, 별도로 보완하겠습니다.</label>
   ${area('reason','전환 근거·확인 내용','','required maxlength="1000"')}
   <label class="check"><input type="checkbox" name="reviewed" required>LOT 수량·현재 상태·연결 수주·공정을 확인했습니다. 과거 실적은 자동 생성되지 않음을 확인했습니다.</label>`,async(form,key)=>{
    if(form.reviewed!=='on')throw Error('전환 내용을 확인하세요.');
    if(!frozenPayload){
     const order=orders.find(o=>o.id===form.order_id);
     frozenPayload={rows:rows.map((row,i)=>({id:row.source.id,version:row.source.version,values:{...row.data,qty:form['qty_'+i]||null,current_state:form['state_'+i]||''}})),
      part_no:part,part_type:type,order_id:order?.id||null,order_version:order?.version||null,
      order:order?null:{order_type:'CIVIL',customer:form.customer,part_no:part,part_name:form.part_name,qty:Number(form.order_qty),shop_order_no:form.shop_order_no||'',heat_code:form.heat_code||'',due_date:form.due_date||'',order_date:today()},
      plan_date:form.plan_date,manager_id:form.manager_id,steps:editor.read(),release:form.release_now==='on',skip_invalid:form.skip_invalid==='on',allow_missing_refs:form.allow_missing_refs==='on',reviewed:true,reason:form.reason};
    }
    try{this.lastResult=await this.main.rpc('dnm_v4103_convert_sources',{p:frozenPayload,k:key});this.selected.clear();await this.main.refreshAfterSave(this.lastResult);}
    catch(error){if(!error.unknown)frozenPayload=null;throw error;}
   },'수주·LOT·작업지시 전환');
  editor=mountSteps('#transferSteps',source.steps,refs);
  let autoQty=true;const total=()=>{const sum=all('[data-transfer-qty]').reduce((n,field)=>n+(Number.isSafeInteger(Number(field.value))&&Number(field.value)>0?Number(field.value):0),0);$('#transferTotal').textContent='입력된 LOT 수량 합계 '+num(sum)+'개';if(autoQty)$('#transferOrderQty').value=sum||'';};
  all('[data-transfer-qty]').forEach(field=>field.oninput=total);$('#transferOrderQty').oninput=()=>{autoQty=false;};
  $('#transferFill').onclick=()=>{const qty=$('#transferDefaultQty').value,state=$('#transferDefaultState').value;if(qty&&(!Number.isSafeInteger(Number(qty))||Number(qty)<1)){message('LOT 수량은 1 이상의 정수로 입력하세요.');return;}all('[data-transfer-qty]').filter(f=>!f.value).forEach(f=>f.value=qty);all('[data-transfer-state]').filter(f=>!f.value).forEach(f=>f.value=state);total();};
  const orderFields=()=>{const fresh=!$('#transferOrder').value;$('#transferNewOrder').hidden=!fresh;all('input',$('#transferNewOrder')).forEach(field=>field.disabled=!fresh);};
  $('#transferOrder').onchange=orderFields;orderFields();total();
  $('#transferStepsSource').onchange=event=>{source=sources.find(s=>s.id===event.target.value);editor=mountSteps('#transferSteps',source.steps,refs);};
 }
 async routeRefs(id){
  this.require();const route=await this.main.s.one(id);
  if(!route.data.source_routing_id||['CANCELLED','SUPERSEDED'].includes(route.state))throw Error('사용 중인 전환 LOT를 선택하세요.');
  modal('LOT 문서항목 보완 · '+(route.data.lot||route.code),notice('원본과 작업실적을 보존하며 이 LOT의 S/O·Heat Code를 보완합니다. 연결 수주의 S/O가 비어 있으면 함께 채웁니다.')+
   `<div class="fields">${input('shop_order_no','Shop Order No',route.data.shop_order_no||'','text','required maxlength="100"')}${input('heat_code','Heat Code',route.data.heat_code||'','text','required maxlength="100"')}</div>`+
   area('reason','보완 근거·사유','','required maxlength="1000"'),async(form,key)=>{
    const result=await this.main.rpc('dnm_v4103_route_refs',{p:{...form,id,version:route.version},k:key});await this.main.refreshAfterSave(result);
   },'문서항목 저장');
 }
 help(){return modal('민수 자료 전환 · 사용방법',notice('1. 업로드한 JSON을 선택하여 기존 원문과 연결합니다.\n2. 품번/TYPE으로 좁혀 수량·현재 상태를 확인합니다. 원문이 여러 건이면 사용할 원문을 선택합니다.\n3. 문제가 있는 자료는 제외하거나 확인·보완합니다.\n4. 선택 자료 전환에서 수주 연결 또는 신규 생성, LOT별 수량·공정을 확인합니다.\n5. 배포한 LOT는 민수 LOT·작업지시에서 실제 실적을 등록합니다. 이전 작업실적은 자동으로 만들지 않습니다.\n6. 전환 LOT를 삭제한 원문은 재검토로 돌려 다시 사용할 수 있습니다.'));}
 async action(act,id){
  this.require();if(act==='refs')return this.routeRefs(id);if(act==='review')return this.review(id);if(act==='convert')return this.convert();if(act==='exclude'||act==='reopen')return this.mark(act);
  if(act==='select'){this.visible.filter(row=>row.source&&!row.route).slice(0,this.batchLimit).forEach(row=>this.selected.add(row.id));if(this.selected.size>500)this.selected=new Set([...this.selected].slice(0,500));return this.load();}
  if(act==='clear'){this.selected.clear();return this.load();}
  if(act==='route')return this.main.civil.routeDetail(id);
  if(act==='order')return this.main.go('orders',id);
  if(act==='routes')return this.main.go('civilRouting');if(act==='work')return this.main.go('instructions');
  if(act==='export')return exportCSV('DNM_민수원문_보완목록.csv',[['원본LOT','품번','품명','TYPE','LOT수량','현재상태','처리상태','문제·보완사항'],...this.visible.map(r=>[r.code,r.data.part_no,r.title,r.data.part_type,r.data.qty,stateLabel(r.data.current_state),transferLabels[r.status],[...r.problems,r.lastError].filter(Boolean).join(' / ')])]);
 }
}
