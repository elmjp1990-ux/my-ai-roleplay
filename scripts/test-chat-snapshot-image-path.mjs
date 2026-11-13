import assert from 'node:assert/strict';
import fs from 'node:fs';

const story = fs.readFileSync('supabase/functions/story-session/index.ts','utf8');
const encounter = fs.readFileSync('supabase/functions/encounter-session/index.ts','utf8');
const html = fs.readFileSync('index.html','utf8');

for (const [name,source] of [['story',story],['encounter',encounter]]) {
  assert.match(source,/from\("character_illustrations"\)/,name+' must look up primary Storage metadata');
  assert.match(source,/\.eq\("asset_type", "primary"\)/,name+' must use the primary asset');
  assert.match(source,/image: primaryIllustration\?\.storage_path \? "" : \(character\.avatar_url \|\| ""\)/,name+' must preserve legacy fallback while avoiding embedded images when Storage exists');
  assert.match(source,/imagePath: primaryIllustration\?\.storage_path \|\| ""/,name+' must persist stable path metadata');
}
assert.match(html,/async function hydrateCloudSessionCharacterImage\(s\)/);
assert.match(html,/getCharacterIllustrationSignedUrl\(path,\{forceRefresh:!!cached\}\)/);
assert.match(html,/cloudSessionImageUrlCache\.set\(key,\{url,expiresAt:Date\.now\(\)\+55\*60\*1000\}\)/);
assert.match(html,/forceRefresh:!!cached/);
assert.match(html,/data-character-illustration-path=.*c\.imagePath/);
assert.match(html,/priorSnapshot\.imagePath \? '' : \(character\?\.image \|\| priorSnapshot\.image \|\| ''\)/);
assert.match(html,/hydrateCloudSessionCharacterImage\(session\)/);
assert.match(html,/hydrateCloudSessionCharacterImage\(s\)/);
assert.match(html,/snap\.imagePath&&uid&&s\.id/);
console.log('Chat snapshot image-path contract passed.');
