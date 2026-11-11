import assert from "node:assert/strict";
import fs from "node:fs";

const html=fs.readFileSync("index.html","utf8");
function block(start,end){
  const a=html.indexOf(start),b=html.indexOf(end,a+start.length);
  assert.ok(a>=0&&b>a,"missing source block: "+start);
  return html.slice(a,b);
}

const imageCompressor=block("async function compressUploadImage","/* Chat sessions:");
assert.match(imageCompressor,/maxEdge\)\|\|1600/);
assert.match(imageCompressor,/targetBytes\)\|\|500\*1024/);
assert.match(imageCompressor,/bestBlob\.size>2\*1024\*1024/);
assert.match(html,/compressUploadImage\(file,\{maxEdge:1600,targetBytes:500\*1024,preserveAlpha:true\}\)/);
assert.match(html,/compressUploadImage\(file,\{maxEdge:1800,targetBytes:700\*1024,preserveAlpha:true\}\)/);

const profileCompressor=block("async function compressProfileImage","// IMG-01:");
assert.match(profileCompressor,/canvas\.width=size;canvas\.height=size/);
assert.match(profileCompressor,/toDataURL\('image\/webp',0\.62\)/);
assert.match(profileCompressor,/result\.length>220000/);

const memoryCompressor=block("async function compressMemoryImage","function setAlbumUploadStatus");
assert.match(memoryCompressor,/maxSide=1600,targetBytes=1536\*1024/);
assert.match(memoryCompressor,/blob\.size>2\*1024\*1024/);
assert.match(memoryCompressor,/toBlob\([\s\S]*?'image\/webp'/);

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
assert.match(importFlow,/character\.image=await getCharacterIllustrationSignedUrl/);
assert.match(importFlow,/image=''/);

const encounterLoader=block("async function hydrateEncounterGalleryIllustration","async function refreshCharacterIllustrationSignedUrl");
assert.match(encounterLoader,/\.eq\('asset_type','gallery'\)/);
assert.match(encounterLoader,/\.limit\(1\)/);
assert.match(encounterLoader,/getCharacterIllustrationSignedUrl\(row\.storage_path\)/);
assert.doesNotMatch(encounterLoader,/loadCharacterIllustrationAssets\(/);
assert.match(encounterLoader,/encounterGalleryIllustrationCache\.has|const cached=encounterGalleryIllustrationCache\.get/);
assert.match(encounterLoader,/encounterGalleryIllustrationInflight\.has\(key\)/);
assert.match(encounterLoader,/requestUid=currentUser\(\)\?\.uid\|\|null/);
assert.match(html,/encounterGalleryIllustrationCache\.delete\(userId\+':'\+character\.id\)/);

const encounterWrapper=block("const installEncounterRenderWrapper","const encounterRenderObserver");
assert.match(encounterWrapper,/if\(!session\?\.encounterMode\)return/);
assert.match(encounterWrapper,/panel\.style\.setProperty\('--encounter-scene-photo'/);
assert.match(encounterWrapper,/if\(halfBodyImage\)/);
assert.match(encounterWrapper,/void hydrateEncounterGalleryIllustration\(character\.id\)/);
assert.match(encounterWrapper,/existingSprite\.dataset\.encounterSource!==halfBodyImage/);

console.log("Media compression, imported image storage, and encounter-only asset hydration checks passed.");
