// VM-only diagnostic proxy. Logs only model/effort/protocol; never headers or prompts.
import http from 'node:http';
import fs from 'node:fs';
import {Readable} from 'node:stream';
const allowed=new Set(['/anthropic/v1/messages','/anthropic/v1/messages/count_tokens','/v1/openai/chat/completions','/v1/openai/responses']);
const log=new URL('./wire-metadata.jsonl',import.meta.url);
http.createServer(async(req,res)=>{
  const path=req.url.split('?')[0];
  if(!allowed.has(path)){res.writeHead(404).end();return;}
  try{
    const chunks=[];let bytes=0;
    for await(const chunk of req){bytes+=chunk.length;if(bytes>16*1024*1024)throw Error('oversize');chunks.push(chunk);}
    const body=Buffer.concat(chunks);const data=JSON.parse(body);
    if(data.model!=='zai-org/GLM-5.3'){res.writeHead(400).end('Proof requires GLM-5.3');return;}
    const info={at:new Date().toISOString(),path,model:data.model,reasoning_effort:data.reasoning_effort,reasoning:data.reasoning,thinking:data.thinking,output_config:data.output_config,tools:data.tools?.length};
    fs.appendFileSync(log,JSON.stringify(info)+'\n');
    const headers={};
    for(const key of ['authorization','x-api-key','anthropic-version','anthropic-beta','content-type'])if(req.headers[key])headers[key]=req.headers[key];
    const upstream=await fetch('https://api.deepinfra.com'+path,{method:'POST',headers,body,signal:AbortSignal.timeout(180000)});
    fs.appendFileSync(log,JSON.stringify({at:new Date().toISOString(),path,status:upstream.status})+'\n');
    res.writeHead(upstream.status,{'content-type':upstream.headers.get('content-type')||'application/json'});
    Readable.fromWeb(upstream.body).pipe(res);
  }catch(err){if(!res.headersSent)res.writeHead(502);res.end('Proof proxy error: '+err.message);}
}).listen(18191,'127.0.0.1',()=>console.log('metadata proxy ready'));
