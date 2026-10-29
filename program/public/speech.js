export function voiceFor(textarea,button,status){
 const Engine=window.SpeechRecognition||window.webkitSpeechRecognition;
 if(!Engine||!window.isSecureContext){button.disabled=true;status.textContent='이 환경은 앱 음성 입력을 지원하지 않습니다. 직접 입력하거나 키보드의 음성 받아쓰기를 사용하세요.';return ()=>{};}
 let engine=null,base='';
 button.onclick=()=>{
  if(engine){engine.stop();return;}
  base=textarea.value;engine=new Engine();engine.lang='ko-KR';engine.continuous=false;engine.interimResults=true;
  engine.onresult=e=>{let final='',partial='';for(let i=0;i<e.results.length;i++){if(e.results[i].isFinal)final+=e.results[i][0].transcript;else partial+=e.results[i][0].transcript;}if(final)textarea.value=base+(base?'\n':'')+final;status.textContent=partial||'인식된 문장을 확인·수정한 후 저장하세요.';};
  engine.onerror=e=>{status.textContent=({'not-allowed':'마이크 사용 권한이 거부됐습니다. 주소창의 사이트 권한을 확인하세요.','audio-capture':'사용 가능한 마이크가 없습니다.','no-speech':'음성이 인식되지 않았습니다. 다시 눌러 말해주세요.','network':'음성인식 서비스 연결을 확인하세요.','aborted':'음성 입력을 중지했습니다.'}[e.error])||'음성 입력이 중단됐습니다. 직접 입력할 수 있습니다.';};
  engine.onend=()=>{engine=null;button.textContent='음성 입력';};
  try{engine.start();button.textContent='듣기 중 · 중지';status.textContent='말씀하세요. 음성은 브라우저 제공자의 인식 서비스에서 처리될 수 있습니다.';}catch{engine=null;button.textContent='음성 입력';status.textContent='음성 입력을 시작하지 못했습니다. 직접 입력하세요.';}
 };
 return ()=>{if(engine){engine.onend=null;engine.onerror=null;engine.abort();engine=null;}button.textContent='음성 입력';};
}
