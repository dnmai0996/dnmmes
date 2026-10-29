// Printable DNM source-aligned documents: 구매의뢰서/견적의뢰서/발주서.
// PDF: browser print "Save as PDF". PNG: generated locally; no file uploaded to external servers.
import {esc,num} from './ui.js';
import {seoulDate} from './purchase-utils.js';
const types={request:'구매의뢰서',quote:'견적의뢰서',order:'발주서'};
const KRW=v=>Number(v||0).toLocaleString('ko-KR',{maximumFractionDigits:2});
export const purchaseDocName=(r,type)=>`${types[type]||'구매문서'}_${String(type==='order'?r.data?.po_no:type==='quote'?r.data?.quote_request?.quote_no:r.code||'').replace(/[^a-zA-Z0-9가-힣_.-]/g,'_')||'미발급'}`;
export function purchaseDocData(r,type){
 const d=r.data||{},q=d.quote_request||{},lines=d.lines||[];
 const number=type==='request'?r.code:type==='quote'?q.quote_no:d.po_no;
 if(!types[type]||!number)throw Error('발행된 문서를 선택하세요.');
 const issue=type==='request'?String(r.created_at||'').slice(0,10):type==='quote'?q.issued_date:d.po_date;
 return {type,title:types[type],number,issue:issue||seoulDate(),recipient:d.supplier||r.title||'',subject: type==='request'?'아래 품목의 구매를 의뢰합니다.':type==='quote'?'아래 품목에 대한 견적을 의뢰합니다.':'아래와 같이 발주합니다.',lines,notes:type==='request'?d.note:type==='quote'?q.note:d.po_note,requestedBy:r.created_by,delivery:type==='quote'?q.response_due:type==='order'?d.po_delivery_date:d.due_date,subtotal:Number(d.subtotal||0),tax:Number(d.tax||0),total:Number(d.total||0)};
}
export function purchaseDocumentMarkup(r,type){
 const d=purchaseDocData(r,type),isQuote=type==='quote';
 const approvers=r.data?.approvals||[];
 const head= type==='request'?`<div class="dnm-doc-sign"><span>작성</span><span>검토</span><span>승인</span></div>`:`<div class="dnm-doc-company"><strong>㈜디엔엠</strong><div>사업자등록번호 459-81-00157</div><div>전화 055-294-0996</div></div>`;
 const detail=`<div class="dnm-doc-info"><p><b>문서번호</b> ${esc(d.number)}</p><p><b>작성일</b> ${esc(d.issue)}</p><p><b>수신</b> ${esc(d.recipient||'담당자 귀하')}</p><p><b>${isQuote?'회신희망일':'요청납기'}</b> ${esc(d.delivery||'별도 협의')}</p></div>`;
 const rows=d.lines.map((l,i)=>`<tr><td>${i+1}</td><td>${esc(l.item)}</td><td>${esc(l.specification||'')}</td><td>${esc(l.unit||'')}</td><td class="num">${KRW(l.qty)}</td>${isQuote?'':`<td class="num">${KRW(l.unit_price)}</td><td class="num">${KRW(l.amount)}</td>`}<td>${esc(l.note||'')}</td></tr>`).join('');
 return `<div class="dnm-purchase-doc"><header class="dnm-doc-header"><div class="dnm-doc-mark">DNM <small>㈜디엔엠 · DNM CO., LTD.</small></div>${head}</header><div class="dnm-doc-title">${d.title}</div>${detail}<p class="dnm-doc-intro">${esc(d.subject)}</p><table class="dnm-doc-lines"><thead><tr><th>No.</th><th>품명</th><th>규격 / 사양</th><th>단위</th><th>수량</th>${isQuote?'':'<th>단가</th><th>금액</th>'}<th>비고</th></tr></thead><tbody>${rows}</tbody></table>${isQuote?'':`<div class="dnm-doc-totals"><span>공급가액 ${KRW(d.subtotal)}원</span><span>부가세 ${KRW(d.tax)}원</span><strong>총액 ${KRW(d.total)}원</strong></div>`}<div class="dnm-doc-note"><b>특기사항 / 비고</b><p>${esc(d.notes||'')}</p></div>${type==='request'?`<div class="dnm-doc-foot">결재선: ${approvers.length}명 · 시스템 기록 기준</div>`:'<div class="dnm-doc-foot">공식 발행 및 수신 여부는 담당자가 확인하십시오.</div>'}<footer class="dnm-doc-bottom">F7020-01(0) · ㈜디엔엠 · DNM 구매업무관리</footer></div>`;
}
export function printPurchaseDocument(r,type){
 let old=document.getElementById('printArea');if(old)old.remove();
 const p=document.createElement('section');p.id='printArea';p.innerHTML=purchaseDocumentMarkup(r,type);document.body.append(p);window.print();
}
export function purchaseCanvas(r,type){
 const d=purchaseDocData(r,type),W=1240,padding=68,lineH=58,tableTop=495,canvas=document.createElement('canvas');
 const height=Math.max(1760,tableTop+lineH*(d.lines.length+1)+470);canvas.width=W;canvas.height=height;
 const g=canvas.getContext('2d');if(!g)throw Error('이미지 생성 기능을 지원하지 않는 브라우저입니다.');
 const ink='#102c46',sub='#51677b',line='#bcc9d3',accent='#176cb5';
 g.fillStyle='#ffffff';g.fillRect(0,0,W,height);
 const write=(s,x,y,size=22,color=ink,align='left',bold=false,max=Infinity)=>{g.fillStyle=color;g.font=`${bold?'700':'400'} ${size}px "Malgun Gothic","Apple SD Gothic Neo",sans-serif`;g.textAlign=align;g.textBaseline='middle';g.fillText(String(s??''),x,y,Math.max(1,max));};
 const rule=(y,x1=padding,x2=W-padding,width=1,color=line)=>{g.strokeStyle=color;g.lineWidth=width;g.beginPath();g.moveTo(x1,y);g.lineTo(x2,y);g.stroke();};
 write('DNM',padding,92,60,accent,'left',true);write('㈜디엔엠 · DNM CO., LTD.',padding,132,18,sub);
 write(d.title,W/2,214,46,ink,'center',true);rule(249,padding,W-padding,3,ink);
 write('문서번호',padding,300,21,sub);write(d.number,padding+165,300,22,ink,'left',true,350);
 write('작성일',W/2+15,300,21,sub);write(d.issue,W/2+135,300,22,ink);
 write('수신',padding,350,21,sub);write(d.recipient,padding+165,350,22,ink,'left',true,600);
 write(type==='quote'?'회신희망일':'요청납기',padding,398,21,sub);write(d.delivery||'별도 협의',padding+165,398,22,ink);
 write(d.subject,padding,456,22,ink,'left',false,W-padding*2);
 const widths=type==='quote'?[56,276,318,85,106,218]:[52,202,270,77,84,108,132,179],heads=type==='quote'?['No','품명','규격 / 사양','단위','수량','비고']:['No','품명','규격 / 사양','단위','수량','단가','금액','비고'];
 const scale=(W-2*padding)/widths.reduce((a,b)=>a+b,0);let xs=[padding];widths.forEach(w=>xs.push(xs.at(-1)+w*scale));
 g.fillStyle='#eaf1f6';g.fillRect(padding,tableTop,W-2*padding,lineH);rule(tableTop,padding,W-padding,2,ink);
 heads.forEach((h,j)=>write(h,(xs[j]+xs[j+1])/2,tableTop+lineH/2,19,ink,'center',true,xs[j+1]-xs[j]-8));
 d.lines.forEach((l,i)=>{const y=tableTop+lineH*(i+1);if(i%2===1){g.fillStyle='#f7f9fb';g.fillRect(padding,y,W-2*padding,lineH);}const vals=type==='quote'?[i+1,l.item,l.specification,l.unit,KRW(l.qty),l.note||'']:[i+1,l.item,l.specification,l.unit,KRW(l.qty),KRW(l.unit_price),KRW(l.amount),l.note||''];vals.forEach((v,j)=>write(v, j===0||j===3||j===4||(type!=='quote'&&(j===5||j===6))?(xs[j]+xs[j+1])/2:xs[j]+9,y+lineH/2,18,ink,j===0||j===3||j===4||(type!=='quote'&&(j===5||j===6))?'center':'left',false,xs[j+1]-xs[j]-15));rule(y+lineH);});
 for(let j=0;j<xs.length;j++){g.strokeStyle=line;g.beginPath();g.moveTo(xs[j],tableTop);g.lineTo(xs[j],tableTop+lineH*(d.lines.length+1));g.stroke();}
 const bottom=tableTop+lineH*(d.lines.length+1);rule(bottom,padding,W-padding,2,ink);
 if(type!=='quote'){write(`공급가 ${KRW(d.subtotal)}원  |  VAT ${KRW(d.tax)}원`,padding,bottom+55,21,sub);write(`총액 ${KRW(d.total)}원`,W-padding,bottom+55,28,ink,'right',true);}
 const ty=bottom+(type==='quote'?65:112);write('특기사항 / 비고',padding,ty,22,ink,'left',true);write(d.notes||'—',padding,ty+42,19,sub,'left',false,W-2*padding);
 rule(height-135);write('㈜디엔엠  ·  구매업무관리',padding,height-96,19,sub);write(`출력 ${seoulDate()}`,W-padding,height-96,18,sub,'right');
 return canvas;
}
export async function sharePurchaseImage(r,type){
 const canvas=purchaseCanvas(r,type);const blob=await new Promise((resolve,reject)=>canvas.toBlob(x=>x?resolve(x):reject(Error('이미지 변환에 실패했습니다.')),'image/png'));
 const file=new File([blob],purchaseDocName(r,type)+'.png',{type:'image/png'});
 if(navigator.canShare?.({files:[file]})&&navigator.share){try{await navigator.share({title:purchaseDocData(r,type).title,files:[file]});return '공유';}catch(e){if(e.name==='AbortError')return '취소';throw e;}}
 const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=file.name;a.click();setTimeout(()=>URL.revokeObjectURL(url),60000);return '다운로드';
}
