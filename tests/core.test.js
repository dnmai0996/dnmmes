import test from 'node:test';
import assert from 'node:assert/strict';
import {settings,cleanRecord,listQuery,esc} from '../public/core.js';
const url='https://example.supabase.co';
const jwt=role=>'header.'+Buffer.from(JSON.stringify({role})).toString('base64url')+'.signature';
test('blank configuration fails visibly; HTTPS project URL is required',()=>{
 assert.throws(()=>settings('',''),/config.js/);
 for(const u of ['http://example.supabase.co','https://supabase.co.evil.test','https://example.supabase.co/rest/v1','https://name:pass@example.supabase.co'])assert.throws(()=>settings(u,'sb_publishable_example'));
 assert.equal(settings(url+'/','sb_publishable_example').url,url);
});
test('browser accepts public keys and rejects privileged keys',()=>{
 assert.equal(settings(url,jwt('anon')).key,jwt('anon'));
 for(const key of ['sb_secret_example',jwt('service_role'),jwt('authenticated'),'broken'])assert.throws(()=>settings(url,key));
});
test('copied outer whitespace is removed; invalid key characters are rejected before fetch',()=>{
 assert.equal(settings(' '+url+'\n',' sb_publishable_example\n').key,'sb_publishable_example');
 for(const key of ['sb_publishable_여기에붙여넣기','sb_publishable_ab cd','sb_publishable_ab\ncd'])assert.throws(()=>settings(url,key),/공개용 키/);
});
test('required and oversized data cannot reach the write call',()=>{
 assert.throws(()=>cleanRecord('notes',{title:'  ',body:'내용'}),/필수/);
 assert.throws(()=>cleanRecord('products',{code:'X',name:'a'.repeat(201)}),/길이/);
 assert.throws(()=>cleanRecord('partners',{code:'X',name:'거래처',category:'admin'}),/구분/);
 const x=cleanRecord('products',{code:' A-1 ',name:' 사무용품 ',project:' 사무 ',unit:' EA ',active:'on',created_by:'spoof',role:'admin'});
 assert.deepEqual(x,{code:'A-1',name:'사무용품',project:'사무',unit:'EA',active:true});
});
test('pagination and search preserve quoted input as one filter value',()=>{
 const q=new URLSearchParams(listQuery('products',3,'품번, "A"\\B','inactive'));
 assert.equal(q.get('offset'),'50');assert.equal(q.get('active'),'eq.false');
 assert.equal(q.get('or'),'(code.ilike."*품번, \\"A\\"\\\\B*",name.ilike."*품번, \\"A\\"\\\\B*")');
 const n=new URLSearchParams(listQuery('notes',1,'memo','all'));assert.equal(n.get('order'),'updated_at.desc');assert.equal(n.has('active'),false);
});
test('untrusted content is escaped before HTML rendering',()=>{
 assert.equal(esc('<img src=x onerror="alert(1)">'), '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;');
 assert.equal(esc(undefined),'');
});
