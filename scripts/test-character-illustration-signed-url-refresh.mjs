import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync('index.html', 'utf8');
const helperStart = html.indexOf('const characterIllustrationSignedUrlCache = new Map();');
const helperEnd = html.indexOf('const memoryPhotoSignedUrlCache', helperStart);
const refreshStart = html.indexOf('async function refreshCharacterIllustrationSignedUrl(storagePath) {');
const refreshEnd = html.indexOf('\n}', refreshStart) + 2;
assert.notEqual(helperStart, -1);
assert.notEqual(helperEnd, -1);
assert.notEqual(refreshStart, -1);
assert.ok(refreshEnd > refreshStart);

const pending = [];
let createCalls = 0;
const sandbox = {
  window: {mySupabase:{storage:{from(bucket){
    assert.equal(bucket,'character-illustrations');
    return {createSignedUrl(path,expiresIn){
      assert.equal(expiresIn,3600);
      createCalls++;
      return new Promise(resolve=>pending.push({path,resolve}));
    }};
  }}}},
  Map,Date,Error
};
const source=html.slice(helperStart,helperEnd)+'\n'+html.slice(refreshStart,refreshEnd)+
  '\nglobalThis.testApi={getCharacterIllustrationSignedUrl,refreshCharacterIllustrationSignedUrl};';
vm.runInNewContext(source,sandbox);

const path='owner/character/illustration.webp';
const oldRequest=sandbox.testApi.getCharacterIllustrationSignedUrl(path);
const forced=sandbox.testApi.refreshCharacterIllustrationSignedUrl(path);
const forcedAgain=sandbox.testApi.refreshCharacterIllustrationSignedUrl(path);
assert.equal(createCalls,2,'parallel forced refreshes must coalesce');
pending[0].resolve({data:{signedUrl:'https://storage.example/old'},error:null});
assert.equal(await oldRequest,'https://storage.example/old');
const joined=sandbox.testApi.getCharacterIllustrationSignedUrl(path);
assert.equal(createCalls,2,'old finally must not remove the replacement in-flight request');
pending[1].resolve({data:{signedUrl:'https://storage.example/fresh'},error:null});
const [fresh,freshAgain,joinedFresh]=await Promise.all([forced,forcedAgain,joined]);
assert.equal(fresh,'https://storage.example/fresh');
assert.equal(freshAgain,fresh);
assert.equal(joinedFresh,fresh);
assert.equal(await sandbox.testApi.getCharacterIllustrationSignedUrl(path),fresh);
assert.equal(createCalls,2);

const racePath='owner/character/late-response.webp';
const lateOld=sandbox.testApi.getCharacterIllustrationSignedUrl(racePath);
const winner=sandbox.testApi.refreshCharacterIllustrationSignedUrl(racePath);
pending[3].resolve({data:{signedUrl:'https://storage.example/winner'},error:null});
assert.equal(await winner,'https://storage.example/winner');
pending[2].resolve({data:{signedUrl:'https://storage.example/late-old'},error:null});
await lateOld;
assert.equal(await sandbox.testApi.getCharacterIllustrationSignedUrl(racePath),'https://storage.example/winner',
  'late superseded response must not overwrite the newer cached URL');
console.log('Passed: refresh coalescing, in-flight joining, and stale-request race protection.');
