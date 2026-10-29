import {V42Controller} from './v42.js';
import {pageAllowed} from './permissions.js';
import {instructionRows} from './instruction-domain.js';
import {$,esc,num,pill,btn,select,table,notice,message,modal} from './ui.js';
export class V421Controller extends V42Controller{
 constructor(...args){super(...args);this.instructionState='open';}
 async load(page){
  if(page!=='instructions')return super.load(page);
  if(this.loadingImport)throw Error('일괄등록 처리 중에는 이 화면을 유지하세요.');
  if(page!==this.page){this.search='';this.pageNo=1;this.detail=null;this.selected.clear();}
  this.page=page;
  if(!pageAllowed(this.ctx,page)){this.set(notice('작업지시 조회권한이 없습니다. 관리자에게 Routing 조회권한을 요청하세요.','warning'));return;}
  if(this.ctx?.version!=='4.2.0'){this.set(notice('업데이트 설치 확인이 필요합니다. 자료를 초기화하지 말고 관리자에게 문의하세요.','warning'));return;}
  return this.instructions();
 }
 async instructions(){
  const [routes,operations]=await Promise.all([this.rec('routing'),this.rec('operation')]);
  if(this.page!=='instructions')return;
  const rows=this.filter(instructionRows(routes,operations,this.instructionState));
  this.set(`<div class="card">${this.top()}<div class="filter-bar">${select('instructionState','작업 상태',[['open','진행'],['closed','종료'],['all','전체']],this.instructionState,'id="instructionState"')}<span>정렬: 품번 → 납기일 → Routing → 공정순서</span></div>${notice('배포된 Routing의 공정별 작업지시입니다. 초안·이전 개정은 제외합니다. 새 Routing 작성·배포는 수주관리에서, 작업실적은 터치·음성 작업입력에서 처리하세요.')}${table(['품번 / 제품명','납기 / 생산오더','Routing / 공정','설비 / 작업자','지시 / 처리','상태','확인'],this.pagedCells(rows,o=>[esc(o.data.part_no)+'<br>'+esc(o.data.route_title),esc(o.data.due_date||'미확정')+'<br>'+esc(o.data.production_no),esc(o.data.route_code)+'<br>'+esc(o.data.op_code)+' · '+esc(o.title),esc(o.data.equipment_code||'미배정')+'<br>'+esc(o.data.employee_name||'미배정'),num(o.data.qty)+' / '+num(o.data.confirmed_qty),pill(o.state),btn('routeDetail','공정·배정',o.route.id)+btn('printRoute','출력',o.route.id)]))}<div id="v4pager" class="pagination"></div></div>`);
  $('#instructionState').onchange=e=>{this.instructionState=e.target.value;this.pageNo=1;this.instructions().catch(x=>message(x.message));};
  this.pageFooter(rows);
 }
 filter(rows){
  if(this.page!=='instructions')return super.filter(rows);
  const q=this.search.trim().toLocaleLowerCase();if(!q)return rows;
  return rows.filter(r=>[r.data.part_no,r.data.production_no,r.data.route_code,r.data.route_title,r.data.due_date,r.data.equipment_code,r.data.employee_name,r.data.op_code,r.title].some(x=>String(x||'').toLocaleLowerCase().includes(q)));
 }
 help(){
  if(this.page==='instructions')return modal('작업지시 · 배포현황 사용방법','<ol class="help-list"><li>수주관리에서 작성·배포한 Routing의 공정별 지시만 표시합니다.</li><li>진행·종료·전체를 선택하고 품번·생산오더·설비·작업자·Routing 번호를 입력하여 검색합니다.</li><li>공정·배정에서 지시내용을 확인하고 출력에서 기존 Routing 양식을 인쇄합니다.</li><li>작업자는 허용된 터치 작업입력 또는 음성 작업입력에서 시작·종료·완료를 등록합니다.</li><li>기존 Routing 조회권한과 데이터 범위를 그대로 적용합니다. 메뉴 이동만으로 권한이 늘어나지 않습니다.</li></ol>');
  return super.help();
 }
}
