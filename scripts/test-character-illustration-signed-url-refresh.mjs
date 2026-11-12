import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync('index.html', 'utf8');
assert.ok(html.includes('<script src="./signed-url-manager.js"></script>'));
const helperStart = html.indexOf('const characterIllustrationSignedUrlManager');
const helperEnd = html.indexOf('const characterIllustrationMetadataInflight', helperStart);
const refreshStart = html.indexOf('async function refreshCharacterIllustrationSignedUrl(storagePath) {');
const refreshEnd = html.indexOf('\n}', refreshStart) + 2;
assert.notEqual(helperStart, -1);
assert.notEqual(helperEnd, -1);
assert.notEqual(refreshStart, -1);
assert.ok(refreshEnd > refreshStart);

const adapters = html.slice(helperStart, helperEnd);
assert.match(adapters, /cacheTtlMs:3300000/);
assert.match(adapters, /refreshSkewMs:60000/);
assert.match(adapters, /from\('character-illustrations'\)\.createSignedUrl\(storagePath,3600\)/);
assert.match(adapters, /characterIllustrationSignedUrlManager\.get\(storagePath,\{forceRefresh:options\?\.forceRefresh===true\}\)/);
assert.match(html.slice(refreshStart, refreshEnd), /getCharacterIllustrationSignedUrl\(storagePath,\{forceRefresh:true\}\)/,
  'an image load error must bypass the possibly expired signed URL cache');

const pending = [];
const managers = [];
const sandbox = {
  window: {
    PoyozzSignedUrlManager: {
      create(options) {
        managers.push(options);
        return {
          get(key, requestOptions) {
            pending.push({key,requestOptions});
            return Promise.resolve('https://storage.example/'+key);
          },
          invalidate(key) { pending.push({invalidate:key}); }
        };
      }
    },
    mySupabase: {storage:{from(bucket){return {createSignedUrl(path,expiresIn){return Promise.resolve({data:{signedUrl:'https://storage.example/'+bucket+'/'+path+'/'+expiresIn},error:null});}};}}}
  },
  currentUser:()=>({uid:'user-a'}),
  Map,Date,Error
};
vm.runInNewContext(adapters+'\nglobalThis.testApi={getCharacterIllustrationSignedUrl,getMemoryPhotoSignedUrl,invalidateMemoryPhotoSignedUrl};',sandbox);
assert.equal(managers.length,2);
assert.equal(managers[0].cacheTtlMs,3300000);
assert.equal(managers[0].refreshSkewMs,60000);
assert.equal(managers[1].cacheTtlMs,240000);
assert.equal(managers[1].refreshSkewMs,15000);
assert.equal(managers[1].maxEntries,250);
assert.equal(await sandbox.testApi.getCharacterIllustrationSignedUrl('owner/role.webp',{forceRefresh:true}),
  'https://storage.example/owner/role.webp');
assert.equal(JSON.stringify(pending[0]),JSON.stringify({key:'owner/role.webp',requestOptions:{forceRefresh:true}}));
assert.equal(await sandbox.testApi.getMemoryPhotoSignedUrl('owner/memory.webp'),
  'https://storage.example/user-a:owner/memory.webp');
assert.equal(JSON.stringify(pending[1]),JSON.stringify({key:'user-a:owner/memory.webp',requestOptions:{context:{uid:'user-a',storagePath:'owner/memory.webp'}}}));
sandbox.testApi.invalidateMemoryPhotoSignedUrl('owner/memory.webp','user-a');
assert.equal(JSON.stringify(pending[2]),JSON.stringify({invalidate:'user-a:owner/memory.webp'}));

const encounterRenderStart = html.indexOf("const dedicatedSprite=safeImage(character?.encounterPortraitImage");
const encounterRenderEnd = html.indexOf("const title=panel.querySelector('.chat-heading')", encounterRenderStart);
assert.notEqual(encounterRenderStart, -1, 'encounter sprite renderer must exist');
assert.ok(encounterRenderEnd > encounterRenderStart, 'encounter sprite renderer boundary must exist');
const encounterRender = html.slice(encounterRenderStart, encounterRenderEnd);
assert.match(encounterRender, /if\(existingSprite\.dataset\.encounterSource!==halfBodyImage\)\s*\{/);
assert.match(encounterRender, /existingSprite\.src=halfBodyImage;/);
assert.match(encounterRender, /existingSprite\.dataset\.encounterSource=halfBodyImage;/);
assert.match(html, /\.upload\(path,blob,\{upsert:false,contentType:blob\.type,cacheControl:'3600'\}\)/);

const galleryHydrationStart = html.indexOf('async function hydrateEncounterGalleryIllustration(characterId) {');
const galleryHydrationEnd = html.indexOf('\nasync function refreshCharacterIllustrationSignedUrl', galleryHydrationStart);
assert.notEqual(galleryHydrationStart, -1);
assert.ok(galleryHydrationEnd > galleryHydrationStart);
const galleryHydration = html.slice(galleryHydrationStart, galleryHydrationEnd);
assert.match(galleryHydration, /\.order\('sort_order',\{ascending:true\}\)\s*\.limit\(1\)/);

const refreshHandlerStart = html.indexOf("if(!window.__characterIllustrationRefreshHandlerInstalled){");
const refreshHandlerEnd = html.indexOf("\nasync function enqueueCharacterIllustrationCleanup", refreshHandlerStart);
assert.notEqual(refreshHandlerStart, -1);
assert.ok(refreshHandlerEnd > refreshHandlerStart);
const refreshHandler = html.slice(refreshHandlerStart, refreshHandlerEnd);
assert.match(refreshHandler, /image\.dataset\.refreshingSignedUrl==='true'\|\|image\.dataset\.signedUrlRefreshAttempted==='true'\)return;/);
assert.match(refreshHandler, /if\(image\.isConnected&&url\)image\.src=url;/);
assert.match(refreshHandler, /image\.dataset\.signedUrlRefreshAttempted='false';/);
assert.match(refreshHandler, /document\.addEventListener\('load',[\s\S]*?image\.dataset\.signedUrlRefreshAttempted='false';/);
console.log('Passed: signed URL adapter settings, forced refresh delegation, and existing image retry guards.');
