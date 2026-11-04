import {V46Controller} from './v46.js';
import {$,area,input,modal,notice,num,select} from './ui.js';
import {counts} from './domain.js';
import {INSPECTION_METHODS} from './inspection.js';

export class V493Controller extends V46Controller{
 async saveRpc(name,args){return this.refreshAfterSave(await this.rpc(name,args));}

 async fieldStart(preselected=''){
  const {jobs,machines,worker}=await this.rpc('dnm_v493_field_choices',{});
  if(!jobs.length)return modal('민수 현장 작업 시작',notice('시작할 민수 공정이 없습니다. 현장 바로 시작으로 저장한 일일 시트와 선행 공정 완료 여부를 확인하세요.'));
  if(!machines.length)return modal('민수 현장 작업 시작',notice('사용 중인 설비가 없습니다. 담당자에게 기준정보 → 설비 등록을 요청하세요.'));
  const options=jobs.map(j=>[j.id,[j.day,j.route,j.part,j.seq+' '+j.name,'잔량 '+num(j.remaining)+'개'].join(' · ')]);
  const equipment=[...machines].sort((a,b)=>a.name.localeCompare(b.name,'ko',{numeric:true})||a.code.localeCompare(b.code,'ko'));
  modal('민수 현장 작업 시작',notice('작업자 '+worker+' 님의 이름과 선택한 설비가 이번 작업일보에 기록됩니다.')+
   select('job','일일 시트 / 공정',[['','작업을 선택하세요'],...options],preselected,'required')+
   select('equipment','실제 사용할 설비',[['','설비를 선택하세요'],...equipment.map(e=>[e.id,e.name+' · '+e.code])],'','required'),
   async(f,k)=>{
    const job=jobs.find(j=>j.id===f.job);
    if(!job)throw Error('시작할 공정을 선택하세요.');
    return this.saveRpc('dnm_v493_field_start',{p_id:job.id,p_version:job.version,p_equipment:f.equipment,k});
   },'이 설비로 작업 시작');
 }

 async qualityForm(order){
  const {rows}=await this.rpc('dnm_v493_inspection_ops',{p_order:order.id});
  modal('검사 등록 · '+order.code,
   select('stage','검사단계',[['INPROCESS','공정검사'],['FINAL','최종검사']],'FINAL')+
   select('inspection_method','검사방법',[['','방법 선택'],...INSPECTION_METHODS],'','required')+
   select('operation_id','대상 Routing / 공정',[['','선택하세요'],...rows.map(o=>[o.id,o.name])])+
   input('criterion','검사 기준·확인 항목','','text','maxlength="500" placeholder="승인된 기준서 번호와 확인할 외관 항목"')+
   '<div class="fields">'+input('total','검사수량','','number','required min="1" step="1"')+
   input('defect','불합격수량',0,'number','required min="0" step="1"')+
   input('report_no','성적서 / 검사기록번호')+'</div>'+
   area('serials','검사대상 일련번호 원문')+area('note','결함·조치 내용 / 증빙 참조','','maxlength="2000"')+
   notice('육안검사는 승인된 기준서나 한도견본에 따라 확인합니다. 공정검사는 중간 기록이며 출하수량에는 최종검사 합격분이 반영됩니다.'),
   async(f,k)=>{
    const c=counts(f.total,f.defect);
    return this.saveRpc('dnm_v493_quality',{p:{...f,id:order.id,version:order.version,total:c.total,defect:c.defect},k});
   },'검사 기록 저장');
  const form=$('#v4form').elements;
  const sync=()=>{
   const visual=form.inspection_method.value==='visual';
   form.criterion.required=visual;
   form.operation_id.required=visual&&form.stage.value==='INPROCESS';
   form.note.required=visual&&Number(form.defect.value)>0;
  };
  form.inspection_method.onchange=sync;form.stage.onchange=sync;form.defect.oninput=sync;sync();
 }

 async action(action,id){
  if(action==='fieldStart')return this.fieldStart(id);
  if(action==='voidDaily'){
   const r=await this.s.one(id);
   return modal('미착수 시트 취소 · '+r.code,notice('시트를 취소하면 계획 가능 수량에 '+num(r.data.qty)+'개가 돌아갑니다. 작업이나 검사 이력이 있으면 취소할 수 없습니다.')+
    area('reason','취소 사유','','required maxlength="500"'),async f=>{
     return this.saveRpc('dnm_v493_void_daily',{p_id:r.id,p_version:r.version,p_reason:f.reason});
    },'이 시트 취소');
  }
  return super.action(action,id);
 }
}
