import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const source=readFileSync(new URL('../../landing-page/_worker.js',import.meta.url),'utf8');
const {default:worker}=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
test('ordinary website downloads stay with existing Stable assets',async()=>{
 let forwarded;
 const response=await worker.fetch(new Request('https://justspeaktoit.com/download'),{ASSETS:{fetch:async request=>{forwarded=request.url;return new Response('Stable');}}});
 assert.equal(forwarded,'https://justspeaktoit.com/download');assert.equal(await response.text(),'Stable');
});
test('Alpha feed and downloads resolve the same immutable pointer',async t=>{
 t.mock.method(globalThis,'fetch',async()=>Response.json({tag:'alpha-build-42'}));
 for(const [path,asset] of [['/alpha/appcast-arm64.xml','appcast-arm64.xml'],['/alpha/download/arm64','JustSpeakToItAlpha-arm64.dmg'],['/alpha/cli/speak-cli-manifest.json','speak-cli-manifest.json']]){
  const response=await worker.fetch(new Request(`https://justspeaktoit.com${path}`),{});
  assert.equal(response.status,302);assert.equal(response.headers.get('Location'),`https://github.com/crmitchelmore/justspeaktoit/releases/download/alpha-build-42/${asset}`);
 }
});
test('Alpha cannot redirect to Stable or untrusted pointer targets',async t=>{
 t.mock.method(globalThis,'fetch',async()=>Response.json({tag:'mac-v3.2.0'}));
 assert.equal((await worker.fetch(new Request('https://justspeaktoit.com/alpha/appcast.xml'),{})).status,503);
});

test('deployment invokes the Worker only for Alpha paths',()=>{
 const routes=JSON.parse(readFileSync(new URL('../../landing-page/_routes.json',import.meta.url),'utf8'));
 assert.deepEqual(routes,{version:1,include:['/alpha/*'],exclude:[]});
});
