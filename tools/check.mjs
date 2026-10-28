import {readdir,readFile} from 'node:fs/promises';import {join} from 'node:path';import {spawnSync} from 'node:child_process';
async function walk(p){const a=[];for(const e of await readdir(p,{withFileTypes:true})){const q=join(p,e.name);if(e.isDirectory())a.push(...await walk(q));else a.push(q);}return a;}
const files=(await Promise.all(['public','server','netlify/functions','tools','tests'].map(walk))).flat().filter(x=>/\.(m?js)$/.test(x));for(const f of files){const x=spawnSync(process.execPath,['--check',f],{encoding:'utf8'});if(x.status){console.error(x.stderr);process.exit(1);}}
console.log(`JavaScript syntax OK: ${files.length} files`);
