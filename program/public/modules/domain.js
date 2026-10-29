export const V4='4.2.0';
export const CAPS={master:'기준정보 관리',production:'생산관리',purchase:'구매·입고·정산',quality:'품질·출하',approve:'구매 결재',work:'본인 작업실적'};
export const KINDS={material_master:'자재',process_master:'공정',order:'고객 수주',order_source:'수주 원본',equipment:'설비',instrument:'계측기',catalog:'공구·공급업체',employee:'작업자',assignment:'설비·작업자 연결',route_template:'공정 템플릿',routing:'Routing Sheet',operation:'공정 작업지시',worklog:'작업일보',purchase:'구매요청',receipt:'구매입고',settlement:'정산',quality:'검사기록',shipment:'출하',customer_return:'고객 반품',material:'자재·외주 처리',urgency:'긴급지시',quality_doc:'품질문서',batch:'자료 업로드',part_detail:'품목 원본'};
export const STATUS={DRAFT:'초안',OPEN:'진행',CLOSED:'마감',CANCELLED:'취소',RELEASED:'배포',SUPERSEDED:'이전 버전',WAIT:'대기',ACTIVE:'작업 중',PENDING:'수량 확인대기',PAUSED:'일시중지',CONFIRMED:'확정',DONE:'완료',HOLD:'보류',SUBMITTED:'결재 중',APPROVED:'승인',REJECTED:'반려',ORDERED:'발주',PARTIAL:'부분입고',RECEIVED:'입고완료',MATCHED:'대사완료',PAID:'지급기록',REQUESTED:'요청',ACKNOWLEDGED:'현장확인',ACCEPT:'합격',REJECT:'불합격',REVIEW:'검토대기',INACTIVE:'사용중지'};
export const TYPES={WORK:'가공·작업',MATERIAL:'자재입고',INSPECTION:'검사',OUTSOURCE:'외주',PACK:'포장·출하준비'};
export const clone=x=>JSON.parse(JSON.stringify(x));
export const text=(v,max=1000)=>{const s=String(v??'').trim();if(s.length>max)throw Error(`입력은 ${max}자 이내로 작성하세요.`);return s;};
export const required=(v,label,max=200)=>{const s=text(v,max);if(!s)throw Error(label+'을(를) 입력하세요.');return s;};
export const qty=(v,label='수량',zero=true)=>{if(v===''||v===null||v===undefined)throw Error(label+'을(를) 입력하세요.');const n=Number(v);if(!Number.isSafeInteger(n)||n<(zero?0:1)||n>1000000000)throw Error(label+'은 '+(zero?'0':'1')+' 이상의 정수여야 합니다.');return n;};
export function money(v){const s=String(v).trim();if(!/^\d+(\.\d{1,2})?$/.test(s))throw Error('금액은 0 이상, 소수점 두 자리까지 입력하세요.');const [a,b='']=s.split('.');const cents=BigInt(a)*100n+BigInt((b+'00').slice(0,2));if(cents>999999999999999n)throw Error('금액이 너무 큽니다.');return Number(cents)/100;}
export function validDate(s){if(!/^\d{4}-\d{2}-\d{2}$/.test(String(s)))return false;const d=new Date(s+'T00:00:00Z');return !Number.isNaN(+d)&&d.toISOString().slice(0,10)===s;}
export function excelDate(v,date1904=false){
 if(v===''||v===null||v===undefined)return '';
 if(typeof v==='number'){if(v<1||v>100000)throw Error('Excel 날짜 범위를 확인하세요.');const n=Math.floor(v);if(!date1904&&n===60)throw Error('Excel 1900-02-29는 실제 날짜가 아닙니다.');return new Date(Date.UTC(date1904?1904:1899,date1904?0:11,date1904?1:31)+(n-(date1904?0:n>=60?1:0))*86400000).toISOString().slice(0,10);}
 const s=String(v).trim().replace(/[./]/g,'-').replace(/\s.*$/,'');const m=s.match(/^(\d{4})-?(\d{1,2})-?(\d{1,2})$/);const r=m?`${m[1]}-${m[2].padStart(2,'0')}-${m[3].padStart(2,'0')}`:'';if(!validDate(r))throw Error('날짜를 YYYY-MM-DD로 확인하세요.');return r;
}
export const nowLocal=()=>new Date(Date.now()+32400000).toISOString().slice(0,16);
export function toUTC(s){if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(s)||!validDate(s.slice(0,10)))throw Error('일시 입력을 확인하세요.');const d=new Date(s+':00+09:00');if(Number.isNaN(+d))throw Error('일시 입력 오류');return d.toISOString();}
export function workMinutes(start,end,breaks=[[570,580],[690,750],[870,880]]){
 const a=Date.parse(start),b=Date.parse(end);if(!Number.isFinite(a)||!Number.isFinite(b)||b<=a)throw Error('종료시간은 시작시간 이후여야 합니다.');if(b-a>72*3600000)throw Error('72시간을 넘는 실적은 날짜별로 나누세요.');let overlap=0;
 let day=Math.floor((a+32400000)/86400000)*86400000-32400000;
 for(;day<b;day+=86400000)for(const [s,e]of breaks)overlap+=Math.max(0,Math.min(b,day+e*60000)-Math.max(a,day+s*60000));
 return Math.max(0,Math.floor((b-a-overlap)/60000));
}
export const duration=m=>`${Math.floor(Number(m||0)/60)}시간 ${Number(m||0)%60}분`;
export function counts(total,defect){const t=qty(total,'총수량'),d=qty(defect,'불량수량');if(d>t)throw Error('불량수량은 총수량을 초과할 수 없습니다.');return{total:t,defect:d,good:t-d};}
export function voiceDraft(s){
 s=text(s,2000);const r={original:s,action:/완료|종료/.test(s)?'finish':/시작/.test(s)?'start':'unknown',total:null,defect:null,needsConfirmation:true};
 const n=x=>{const m=s.match(x);return m?Number(m[1].replace(/,/g,'')):null;};
 r.total=n(/(?:총(?:수량)?|생산수량|작업수량)\s*(\d[\d,]*)\s*(?:개|EA)?/i);r.defect=n(/불량(?:수량)?\s*(\d[\d,]*)\s*(?:개|EA)?/i);
 if(r.total!==null&&r.defect!==null&&r.defect>r.total)r.error='불량수량이 총수량보다 큽니다.';
 if(r.action==='unknown')r.error='시작 또는 완료 의도를 다시 확인하세요.';return r;
}
export function csvCell(v){const s=String(v??'');return '"'+(/^(?:\s*[=+\-@]|[\t\r])/.test(s)?"'":'')+s.replace(/"/g,'""')+'"';}
export const csv=rows=>'\ufeff'+rows.map(r=>r.map(csvCell).join(',')).join('\r\n');
export function orderProgress(order,routings,ops,logs,quality){
 const rid=new Set(routings.filter(x=>x.parent_id===order.id&&['RELEASED','DONE'].includes(x.state)).map(x=>x.id));const o=ops.filter(x=>rid.has(x.parent_id));
 const accepted=quality.filter(x=>x.parent_id===order.id&&x.state==='CONFIRMED'&&x.data.stage==='FINAL').reduce((a,x)=>a+Number(x.data.good||0),0);
 const q=Number(order.data.qty||0);return {ops:o.length,done:o.filter(x=>x.state==='DONE').length,accepted,percent:q?Math.min(100,Math.floor(accepted/q*100)):0,pending:logs.filter(x=>x.state==='PENDING'&&o.some(op=>op.id===x.parent_id)).length};
}
export function can(ctx,cap){return ctx?.profile?.active&&(ctx.profile.role==='admin'||(ctx.profile.role==='member'&&ctx.capabilities?.includes(cap)));}
