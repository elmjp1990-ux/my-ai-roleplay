import assert from "node:assert/strict";
import fs from "node:fs";

const html=fs.readFileSync("index.html","utf8");
const compressor=fs.readFileSync("image-compression.js","utf8");
assert.ok(html.includes('<script src="./image-compression.js"></script>'));
assert.ok(compressor.includes("window.PoyozzImageCompression=Object.freeze(api)"));
assert.ok(compressor.includes("createImageBitmap"));
assert.ok(compressor.includes("URL.revokeObjectURL"));
function block(start,end){
  const a=html.indexOf(start),b=html.indexOf(end,a+start.length);
  assert.ok(a>=0&&b>a,"missing source block: "+start);
  return html.slice(a,b);
}

const imageCompressor=block("async function compressUploadImage","/* Chat sessions:");
assert.ok(imageCompressor.includes("window.PoyozzImageCompression.compress(file"));
assert.ok(imageCompressor.includes("maxEdge:Number(options.maxEdge)||1440"));
assert.ok(imageCompressor.includes("targetBytes:Number(options.targetBytes)||500*1024"));
assert.ok(imageCompressor.includes("maxOutputBytes:1*1024*1024"));
assert.ok(imageCompressor.includes("preserveAlpha"));
assert.ok(imageCompressor.includes("return {...result,dataUrl}"));
assert.ok(html.includes("compressUploadImage(file,{maxEdge:1440,targetBytes:500*1024,preserveAlpha:true})"));
assert.ok(!html.includes("compressUploadImage(file,{maxEdge:1600,targetBytes:500*1024,preserveAlpha:true})"));
assert.ok(!html.includes("compressUploadImage(file,{maxEdge:1800,targetBytes:700*1024,preserveAlpha:true})"));

const profileCompressor=block("async function compressProfileImage","// IMG-01:");
assert.ok(profileCompressor.includes("compressUploadImage(file,{maxEdge:256,targetBytes:120*1024,preserveAlpha:true})"));
assert.ok(profileCompressor.includes("return compressed.dataUrl"));

const memoryCompressor=block("async function compressMemoryImage","// Future AI-generated memory images");
assert.ok(memoryCompressor.includes("window.PoyozzImageCompression.compress(file"));
assert.ok(memoryCompressor.includes("decoder:'bitmap'"));
assert.ok(memoryCompressor.includes("maxEdge:1200"));
assert.ok(memoryCompressor.includes("targetBytes:450*1024"));
assert.ok(memoryCompressor.includes("minScale:.25"));
assert.ok(memoryCompressor.includes("contextAttributes:{alpha:false}"));
assert.ok(memoryCompressor.includes("background:'#fff'"));
assert.ok(memoryCompressor.includes("qualities:[.80,.72,.64,.56,.48]"));
assert.ok(html.includes("upload(path,compressed,{contentType:'image/webp',upsert:false,cacheControl:'3600'})"));

const videoCompressor=block("async function compressCharacterAvatarVideo","async function uploadCharacterAvatarVideo");
assert.match(videoCompressor,/maxEdge<=960/);
assert.match(videoCompressor,/videoBitsPerSecond:650000/);
assert.match(videoCompressor,/captureStream\(24\)/);
assert.match(videoCompressor,/blob\.size>2\*1024\*1024/);
assert.match(videoCompressor,/new File\(\[blob\]/);
assert.match(videoCompressor,/stream\.getTracks\(\)\.forEach/);
const videoUploader=block("async function uploadCharacterAvatarVideo","// Signed URL 依 storage path");
assert.match(videoUploader,/const optimized=await compressCharacterAvatarVideo\(file\)/);
assert.match(videoUploader,/upload\(path,optimized/);
assert.doesNotMatch(videoUploader,/upload\(path,file/);

const importFlow=block("async function importCharacter(file)","/* Image errors do not inject HTML. */");
assert.match(importFlow,/compressUploadImage\(importedFile/);
assert.match(importFlow,/syncCharacterIllustrations\(character,user\.uid\)/);

const encounterLoader=block("async function hydrateEncounterGalleryIllustration","async function refreshCharacterIllustrationSignedUrl");
assert.match(encounterLoader,/\.eq\('asset_type','gallery'\)/);
assert.match(encounterLoader,/\.limit\(1\)/);
assert.match(encounterLoader,/getCharacterIllustrationSignedUrl\(row\.storage_path\)/);
assert.doesNotMatch(encounterLoader,/loadCharacterIllustrationAssets\(/);
assert.match(encounterLoader,/encounterGalleryIllustrationCache\.get\(key\)/);
assert.match(encounterLoader,/encounterGalleryIllustrationInflight\.has\(key\)/);
assert.match(encounterLoader,/requestUid=currentUser\(\)\?\.uid\|\|null/);

const encounterLifecycle=block("const encounterRenderLifecycle=window.PoyozzChatRenderLifecycle","document.addEventListener('click',event=>{");
assert.match(encounterLifecycle,/register\('afterSingleConversation','encounter\.single-scene'/);
assert.match(encounterLifecycle,/register\('afterMessages','encounter\.progressive-dialogue'/);
assert.match(encounterLifecycle,/if\(!session\?\.encounterMode\|\|!panel\)return/);
assert.match(encounterLifecycle,/panel\.style\.setProperty\('--encounter-scene-photo'/);
assert.match(encounterLifecycle,/void hydrateEncounterGalleryIllustration\(character\.id\)/);
assert.match(encounterLifecycle,/existingSprite\.dataset\.encounterSource!==halfBodyImage/);
assert.match(encounterLifecycle,/defaultSceneImage='\.\/encounter-default-scene\.webp'/);
assert.doesNotMatch(html,/installEncounterRenderWrapper|wrappedRenderConversation|wrappedRenderMessages/);

const groupOpen=block("async function groupOpen(groupId)","async function openGroupBackgroundSettings");
assert.doesNotMatch(groupOpen,/from\('chat_memory_photos'\)/,
  "opening a group must not query or sign unused memory photos");
assert.match(groupOpen,/memoryPhotos:\[\]/);
const groupBackgroundSettings=block("async function openGroupBackgroundSettings","function ");
assert.match(groupBackgroundSettings,/from\('chat_memory_photos'\)/);
assert.match(groupBackgroundSettings,/getMemoryPhotoSignedUrl\(photo\.storage_path\)/);
assert.match(html,/getMemoryPhotoSignedUrl\(p\.storage_path\)/);
assert.doesNotMatch(html,/createSignedUrl\([^)]*\.storage_path/,
  "all memory-photo signed URL callsites must use the shared UID/path cache");

assert.match(html,/href="\.\/LOGO_WEBICON\.webp"/);
assert.match(html,/src="\.\/LOGO_WEBLOGO\.webp"/);
assert.match(html,/src="\.\/LOGO_WEBICON\.webp"/);
assert.doesNotMatch(html,/raw\.githubusercontent\.com\/elmjp1990-ux\/my-ai-roleplay\/main\/LOGO_WEB/);


const memoryUrlCache=block("async function getMemoryPhotoSignedUrl","const characterIllustrationMetadataInflight");
assert.ok(memoryUrlCache.includes("const key=uid+':'+storagePath"));
assert.ok(memoryUrlCache.includes("memoryPhotoSignedUrlCache.get(key)"));
assert.ok(memoryUrlCache.includes("memoryPhotoSignedUrlInflight.has(key)"));
assert.ok(memoryUrlCache.includes("expiresAt:Date.now()+240000"));
assert.ok(memoryUrlCache.includes("memoryPhotoSignedUrlCache.size>250"));
assert.ok(memoryUrlCache.includes("(currentUser()?.uid||null)!==uid"));
assert.ok(memoryUrlCache.includes("function invalidateMemoryPhotoSignedUrl"));

const albumLoader=block("async function loadAlbum(type,chatId)","async function compressMemoryImage");
assert.ok(albumLoader.includes("getMemoryPhotoSignedUrl(photo.storage_path)"));
assert.doesNotMatch(albumLoader,/if\(!imageUrl\)[^\n]*signedError/);
const photoDelete=block("if(button.dataset.action==='memory-photo-delete')","if(button.dataset.action==='memory-photo-background')");
assert.ok(photoDelete.includes("invalidateMemoryPhotoSignedUrl(photo.storage_path,uid)"));
const photoDownload=block("async function downloadCompressedMemoryPhoto","document.addEventListener");
assert.ok(photoDownload.includes("getMemoryPhotoSignedUrl(cached.photo.storage_path)"));

const profileCompressorUpdated=block("async function compressProfileImage","// IMG-01:");
assert.ok(profileCompressorUpdated.includes("compressUploadImage(file,{maxEdge:256,targetBytes:120*1024,preserveAlpha:true})"));

const illustrationUploader=block("async function uploadCharacterIllustrationDataUrl","async function syncCharacterIllustrations");
assert.match(illustrationUploader,/blob\.size>10\*1024\*1024/);
assert.match(html,/window\.compressMemoryImageForStorage=compressMemoryImage/);
assert.equal([...html.matchAll(/\.upload\(/g)].length,3,
  "all Storage upload paths must stay covered by the image/video compression checks");

const wordmarkBytes=fs.statSync("LOGO_WEBLOGO.webp").size;
const iconBytes=fs.statSync("LOGO_WEBICON.webp").size;
const encounterSceneBytes=fs.statSync("encounter-default-scene.webp").size;
assert.ok(wordmarkBytes<30*1024, "optimized wordmark should remain below 30 KB");
assert.ok(iconBytes<20*1024, "optimized icon should remain below 20 KB");
assert.ok(encounterSceneBytes<300*1024, "optimized encounter scene should remain below 300 KB");

console.log("Mobile image standards, video transcode, encounter-only media, and lazy memory-photo checks passed.");
