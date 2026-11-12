import test from 'node:test';
import assert from 'node:assert/strict';
import {sourceRows,compareSourceRows} from '../public/modules/source-review.js';
import {actionAllowed,permissionPreset} from '../public/modules/permissions.js';

const row=(code,lot,extra={})=>({kind:'source_routing',code,title:lot,data:{lot,qty:null,...extra}});
const bundle=rows=>({rows});
test('source preview never includes live orders or production records',()=>{
 assert.equal(sourceRows(bundle([row('A','L'),{kind:'order',code:'O'},{kind:'worklog',code:'W'}])).length,1);
});
test('same code is recognized without requiring the new source-family tag',()=>{
 const result=compareSourceRows(bundle([row('A','L')]),[{...row('A','L'),id:'old'}]);
 assert.equal(result.matched,1);assert.equal(result.existing,0);assert.equal(result.rows[0].status,'same-code');
});
test('older same-LOT code remains visible without mutating the legacy row',()=>{
 const file=row('HIST-BUSH-L','L',{part_no:'NEW'}),old={...row('HIST-OLD','L',{part_revision:'OLD'}),id:'old'};
 const before=JSON.stringify([file,old]);const result=compareSourceRows(bundle([file]),[old]);
 assert.equal(result.matched,1);assert.equal(result.existing,1);assert.equal(result.rows[0].matches[0].data.part_revision,'OLD');
 assert.equal(JSON.stringify([file,old]),before);
});
test('original LOT stored only in data is recognized',()=>{
 const old={...row('OLD','L'),id:'old',title:'Other title'};
 assert.equal(compareSourceRows(bundle([row('A','L')]),[old]).existing,1);
});
test('non-reference rows with identical codes never prove a source was imported',()=>{
 const old={...row('A','L'),id:'live',kind:'routing'};
 assert.equal(compareSourceRows(bundle([row('A','L')]),[old]).missing,1);
});
test('missing rows stay missing, with quantities unknown rather than zero',()=>{
 const result=compareSourceRows(bundle([row('A','L')]),[]);
 assert.equal(result.missing,1);assert.equal(result.rows[0].source.data.qty,null);assert.deepEqual(result.rows[0].matches,[]);
});
test('identity is exact, not a fuzzy or case-insensitive LOT guess',()=>{
 const result=compareSourceRows(bundle([row('A','L-001')]),[{...row('OTHER','l-001'),id:'old'}]);
 assert.equal(result.missing,1);
});
test('blank titles and LOTs cannot match unrelated source records',()=>{
 const result=compareSourceRows(bundle([row('A','')]),[{...row('OTHER',''),id:'old'}]);
 assert.equal(result.missing,1);
});
test('one row matching both code and LOT counts once',()=>{
 const result=compareSourceRows(bundle([row('A','L')]),[{...row('A','L'),id:'one'}]);
 assert.equal(result.rows[0].matches.length,1);assert.equal(result.multiple,0);
});
test('multiple legacy sources are shown and exact code is ordered first',()=>{
 const result=compareSourceRows(bundle([row('A','L')]),[{...row('OLD','L'),id:'1'},{...row('A','L'),id:'2'}]);
 assert.equal(result.matched,1);assert.equal(result.multiple,1);assert.equal(result.rows[0].matches[0].id,'2');
});
test('1863 previously imported LOTs are all found even with only legacy metadata',()=>{
 const files=Array.from({length:1863},(_,i)=>row('NEW-'+i,'LOT-'+i));
 const old=files.map((r,i)=>({...r,code:'OLD-'+i,id:String(i)}));
 const result=compareSourceRows(bundle(files),old);
 assert.equal(result.total,1863);assert.equal(result.matched,1863);assert.equal(result.existing,1863);assert.equal(result.missing,0);
});
test('source comparison obeys archive read permission',()=>{
 const ctx={profile:{role:'member',active:true},permissions:permissionPreset('none')};
 for(const action of ['showImportedSources','sourceCompare']){
  assert.equal(actionAllowed(ctx,action,'','archives'),false);ctx.permissions.archives.read=true;
  assert.equal(actionAllowed(ctx,action,'','archives'),true);ctx.permissions.archives.read=false;
 }
});
