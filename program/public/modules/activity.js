// Shared visual feedback. No timers or DOM access when running unit tests in Node.
const active=new Map();let seq=0;
function render(){
 if(typeof document==='undefined')return;
 let panel=document.getElementById('dnmActivity');
 if(!panel){panel=document.createElement('div');panel.id='dnmActivity';panel.className='activity-panel';panel.setAttribute('role','status');panel.setAttribute('aria-live','polite');document.body.append(panel);}
 const items=[...active.values()],last=items.sort((a,b)=>(a.priority||0)-(b.priority||0)).at(-1);
 document.body.classList.toggle('dnm-working',items.length>0);
 document.getElementById('content')?.setAttribute('aria-busy',String(items.length>0));
 panel.hidden=!last;if(!last)return;
 panel.replaceChildren();const spinner=document.createElement('span');spinner.className='activity-spinner';spinner.setAttribute('aria-hidden','true');panel.append(spinner);
 const text=document.createElement('span');text.textContent=last.label;panel.append(text);
 if(Number.isFinite(last.percent)){const p=document.createElement('progress');p.max=100;p.value=last.percent;p.setAttribute('aria-label','작업 진행률');panel.append(p);}
}
export function beginActivity(label='처리 중입니다…',priority=1){
 const id=++seq;active.set(id,{label,priority});render();let closed=false;
 return {update(label,percent){if(!closed){active.set(id,{label,percent,priority});render();}},end(){if(!closed){closed=true;active.delete(id);render();}}};
}
export async function withActivity(label,fn){const a=beginActivity(label);try{return await fn(a);}finally{a.end();}}
export function activeOperations(){return active.size;}
