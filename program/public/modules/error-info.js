let last='';
export function userMessage(value){
 const text=String(value||'처리하지 못했습니다.');
 if(/statement timeout|HTTP [45]\d\d|CONNECTION_FAILED|PGRST|PostgreSQL|schema cache|Netlify Functions/i.test(text))last=text.replace(/sb_(secret|publishable)_[^\s"']+/g,'[키 가림]').slice(0,1400);
 if(/statement timeout/i.test(text))return '처리시간이 초과되었습니다. 잠시 후 다시 시도하거나 사용방법에서 담당자 안내를 확인하세요.';
 if(/CONNECTION_FAILED|Failed to fetch|Netlify Functions/i.test(text))return '업무시스템에 연결하지 못했습니다. 인터넷 연결을 확인하고 다시 시도하세요. 계속되면 관리자에게 문의하세요.';
 return text.replace(/\s*\[HTTP \d+\]/g,'');
}
export function lastError(){return last;}
