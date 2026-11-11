import assert from "node:assert/strict";
import fs from "node:fs";

const html=fs.readFileSync("index.html","utf8");
function block(start,end){
  const a=html.indexOf(start),b=html.indexOf(end,a+start.length);
  assert.ok(a>=0&&b>a,"missing source block: "+start);
  return html.slice(a,b);
}

const imageCompressor=block("async function compressUploadImage","/* Chat sessions:");
assert.match(imageCompressor,/maxEdge\)\|\|1440/);
assert.match(imageCompressor,/targetBytes\)\|\|500\*1024/);
assert.match(imageCompressor,/bestBlob\.size>1\*1024\*1024/);
assert.match(html,/compressUploadImage\(file,\{maxEdge:1440,targetBytes:500\*1024,preserveAlpha:true\}\)/);
assert.doesNotMatch(html,/compressUploadImage\(file,\{maxEdge:(?:1600|1800),targetBytes:(?:500|700)\*1024,preserveAlpha:true\}\)/);

const profileCompressor=block("async function compressProfileImage","// IMG-01:");
assert.match(profileCompressor,/compressUploadImage\(file,\{maxEdge:256,targetBytes:120\*1024,preserveAlpha:true\}\)/);
assert.match(profileCompressor,/return compressed\.dataUrl/);

const memoryCompressor=block("async function compressMemoryImage","function setAlbumUploadStatus");
assert.match(memoryCompressor,/maxSide=1200,targetBytes=450\*1024/);
assert.match(memoryCompressor,/bestBlob\.size>1024\*1024/);
assert.match(memoryCompressor,/toBlob\([\s\S]*?'image\/webp'/);
assert.match(html,/upload\(path,compressed,\{contentType:'image\/webp',upsert:false,cacheControl:'3600'\}\)/);

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

const encounterWrapper=block("const installEncounterRenderWrapper","installEncounterRenderWrapper();");
assert.match(encounterWrapper,/if\(!session\?\.encounterMode\)return/);
assert.match(encounterWrapper,/panel\.style\.setProperty\('--encounter-scene-photo'/);
assert.match(encounterWrapper,/void hydrateEncounterGalleryIllustration\(character\.id\)/);
assert.match(encounterWrapper,/existingSprite\.dataset\.encounterSource!==halfBodyImage/);
assert.match(encounterWrapper,/defaultSceneImage='\.\/encounter-default-scene\.webp'/);

const groupOpen=block("async function groupOpen(groupId)","async function openGroupBackgroundSettings");
assert.doesNotMatch(groupOpen,/from\('chat_memory_photos'\)/,
  "opening a group must not query or sign unused memory photos");
assert.match(groupOpen,/memoryPhotos:\[\]/);
const groupBackgroundSettings=block("async function openGroupBackgroundSettings","function ");
assert.match(groupBackgroundSettings,/from\('chat_memory_photos'\)/);
assert.match(groupBackgroundSettings,/createSignedUrl/);

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
