import {readXlsx} from './xlsx.js';
self.onmessage=async e=>{try{const book=await readXlsx(e.data,{onProgress:message=>postMessage({progress:message})});postMessage({book});}catch(err){postMessage({error:err.message});}};
