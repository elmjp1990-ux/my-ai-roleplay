import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const between = (start, end) => {
  const from = html.indexOf(start);
  const to = html.indexOf(end, from + start.length);
  assert.notEqual(from, -1, "missing source block: " + start);
  assert.notEqual(to, -1, "missing end marker: " + end);
  return html.slice(from, to);
};

const primaryLoader = between("async function loadCharacterPrimaryIllustrationAssets", "async function loadCharacterIllustrationAssets");
assert.match(primaryLoader, /\.eq\('asset_type','primary'\)/);
assert.match(primaryLoader, /getCharacterIllustrationSignedUrl\(row\.storage_path\)/);
assert.match(primaryLoader, /primary:\{id:row\.id,path:row\.storage_path,src:signedUrl/);
assert.match(primaryLoader, /const key='primary:'\+scope\+':'\+ids\.join\(','\)/);

const ownerLoader = between("async function loadSupabaseCharacters(user)", "const characterIllustrationSignedUrlCache");
assert.match(ownerLoader, /loadCharacterPrimaryIllustrationAssets\(ids,user\.id\)/);
assert.doesNotMatch(ownerLoader, /loadCharacterIllustrationAssets\(ids,user\.id\)/,
  "login must not fetch all gallery assets for every owned character");
assert.match(ownerLoader, /galleryIllustrations:local\.galleryIllustrations\|\|\[\]/);
assert.match(ownerLoader, /void retryCharacterIllustrationCleanup\(user\.id\)/);

const editorLoader = between("async function hydrateCharacterIllustrationsIntoEditor(characterId)", "function renderCharacterIllustrationGallery");
assert.match(editorLoader, /loadCharacterIllustrationAssets\(\[characterId\]\)/,
  "the editor must still hydrate the selected character's full gallery");
const encounterLoader = between("async function hydrateEncounterGalleryIllustration(characterId)", "async function refreshCharacterIllustrationSignedUrl");
assert.match(encounterLoader, /loadCharacterIllustrationAssets\(\[characterId\]\)/,
  "Encounter must still hydrate gallery assets on demand");

console.log("Owned-character primary-only login hydration and on-demand gallery checks passed.");
