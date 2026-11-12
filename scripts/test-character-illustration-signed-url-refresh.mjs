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

// Guard encounter rendering against reassigning an unchanged image URL.
// Reassigning img.src on every AI/render update can trigger unnecessary image requests.
const encounterRenderStart = html.indexOf("const dedicatedSprite=safeImage(character?.encounterPortraitImage");
const encounterRenderEnd = html.indexOf("const title=panel.querySelector('.chat-heading')", encounterRenderStart);
assert.notEqual(encounterRenderStart, -1, 'encounter sprite renderer must exist');
assert.ok(encounterRenderEnd > encounterRenderStart, 'encounter sprite renderer boundary must exist');
const encounterRender = html.slice(encounterRenderStart, encounterRenderEnd);
assert.match(encounterRender, /if\(existingSprite\.dataset\.encounterSource!==halfBodyImage\)\s*\{/,
  'existing encounter sprite must only update its source when the selected URL changes');
assert.match(encounterRender, /existingSprite\.src=halfBodyImage;/,
  'new or changed encounter sprite must receive its selected URL');
assert.match(encounterRender, /existingSprite\.dataset\.encounterSource=halfBodyImage;/,
  'encounter sprite must remember the URL already assigned');
assert.match(html, /\.upload\(path,blob,\{upsert:false,contentType:blob\.type,cacheControl:'3600'\}\)/,
  'illustration uploads must retain one-hour HTTP cache headers for immutable unique storage paths');

const galleryHydrationStart = html.indexOf('async function hydrateEncounterGalleryIllustration(characterId) {');
const galleryHydrationEnd = html.indexOf('\nasync function refreshCharacterIllustrationSignedUrl', galleryHydrationStart);
assert.notEqual(galleryHydrationStart, -1, 'encounter gallery hydration must exist');
assert.ok(galleryHydrationEnd > galleryHydrationStart, 'encounter gallery hydration boundary must exist');
const galleryHydration = html.slice(galleryHydrationStart, galleryHydrationEnd);
assert.match(galleryHydration, /\.order\('sort_order',\{ascending:true\}\)\s*\.limit\(1\)/,
  'encounter must not eagerly sign and download all five gallery images');

const refreshHandlerStart = html.indexOf("if(!window.__characterIllustrationRefreshHandlerInstalled){");
const refreshHandlerEnd = html.indexOf("\nasync function enqueueCharacterIllustrationCleanup", refreshHandlerStart);
assert.notEqual(refreshHandlerStart, -1, 'signed URL image error handler must exist');
assert.ok(refreshHandlerEnd > refreshHandlerStart, 'signed URL image error handler boundary must exist');
const refreshHandler = html.slice(refreshHandlerStart, refreshHandlerEnd);
assert.match(html.slice(refreshStart, refreshEnd), /getCharacterIllustrationSignedUrl\(storagePath,\{forceRefresh:true\}\)/,
  'an image load error must bypass the possibly expired signed URL cache');
assert.match(refreshHandler, /image\.dataset\.refreshingSignedUrl==='true'\|\|image\.dataset\.signedUrlRefreshAttempted==='true'\)return;/,
  'each image element must be protected from overlapping or repeated refresh attempts');
assert.match(refreshHandler, /if\(image\.isConnected&&url\)image\.src=url;/,
  'a refreshed URL must not be assigned to an image element that has been removed');
assert.match(refreshHandler, /image\.dataset\.signedUrlRefreshAttempted='false';/,
  'a failed refresh must release the per-image retry guard');
assert.match(refreshHandler, /document\.addEventListener\('load',[\s\S]*?image\.dataset\.signedUrlRefreshAttempted='false';/,
  'a successfully loaded replacement image must reset its retry guard');

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
