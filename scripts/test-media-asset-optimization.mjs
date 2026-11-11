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
assert.match(profileCompressor,/canvas\.width=size;canvas\.height=size/);
assert.match(profileCompressor,/toDataURL\('image\/webp',0\.62\)/);
assert.match(profileCompressor,/result\.length>220000/);

const memoryCompressor=block("async function compressMemoryImage","function setAlbumUploadStatus");
assert.match(memoryCompressor,/maxSide=1200,targetBytes=450\*1024/);
assert.match(memoryCompressor,/blob\.size>1024\*1024/);
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

console.log("Mobile image standards, video transcode, encounter-only media, and lazy memory-photo checks passed.");
