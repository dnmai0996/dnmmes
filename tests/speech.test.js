import test from 'node:test';
import assert from 'node:assert/strict';
import {voiceFor} from '../public/speech.js';
test('unsupported browser keeps typing available and disables only voice',()=>{
 global.window={isSecureContext:true};const text={value:'직접 입력'},button={},status={};
 const stop=voiceFor(text,button,status);assert.equal(button.disabled,true);assert.match(status.textContent,/직접 입력/);assert.equal(text.value,'직접 입력');stop();
});
test('voice starts on click only, adds text without saving, and can abort',()=>{
 let instance,started=0,aborted=0;
 class Engine{constructor(){instance=this;}start(){started++;}abort(){aborted++;}stop(){this.onend();}}
 global.window={SpeechRecognition:Engine,isSecureContext:true};const text={value:'메모'},button={},status={};
 const stop=voiceFor(text,button,status);assert.equal(started,0);button.onclick();assert.equal(started,1);assert.equal(instance.lang,'ko-KR');
 const r=[{transcript:'추가 내용'}];r.isFinal=true;instance.onresult({results:[r]});assert.equal(text.value,'메모\n추가 내용');
 stop();assert.equal(aborted,1);assert.equal(button.textContent,'음성 입력');
});
