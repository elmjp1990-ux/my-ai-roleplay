import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const publicLoaderStart = html.indexOf("async function loadPublicSupabaseCharactersImpl()");
const publicLoaderEnd = html.indexOf("async function loadSupabaseCharacters(user)", publicLoaderStart);
assert.ok(publicLoaderStart >= 0 && publicLoaderEnd > publicLoaderStart, "public character loader boundaries must exist");
const publicLoader = html.slice(publicLoaderStart, publicLoaderEnd);

// Explore still loads the full public character list for search, filters, recommendations and map use,
// but it must not fan out illustration metadata reads or signed URL requests for every public role.
assert.doesNotMatch(publicLoader, /loadCharacterIllustrationAssets|character_illustrations|createSignedUrl/);
assert.match(publicLoader, /image: ownerLocal\?\.image \|\| row\.avatar_url/);
assert.match(publicLoader, /galleryIllustrations:ownerLocal\?\.galleryIllustrations \|\| \[\]/);
assert.match(publicLoader, /publicIllustrationsLoaded:ownerLocal\?\.publicIllustrationsLoaded === true/);

// Full art is fetched for one role only when its detail page is opened, with in-flight deduplication.
assert.match(html, /const publicCharacterIllustrationHydration = new Map\(\)/);
assert.match(html, /async function hydratePublicCharacterIllustrations\(characterId\)/);
assert.match(html, /publicCharacterIllustrationHydration\.has\(characterId\)/);
assert.match(html, /async function loadPublicCharacterPrimaryIllustration\(characterId\)/);
assert.match(html, /\.eq\(['"]asset_type['"],['"]primary['"]\)/);
assert.match(html, /\.limit\(1\)/);
assert.match(html, /loadPublicCharacterPrimaryIllustration\(characterId\)/);
assert.match(html, /current\.publicIllustrationsLoaded=true/);
assert.match(html, /document\.querySelector\('\.detail-portrait \.detail-image'\)/);
assert.match(html, /data-character-primary-illustration=/);
assert.match(html, /function observePublicCharacterIllustrationCards\\(root\\)/);
assert.match(html, /observePublicCharacterIllustrationCards\\(grid\\)/);
assert.match(html, /new IntersectionObserver\\(entries=>/);
assert.match(html, /person\\.cloudPublic===true&&!image&&person\\.publicIllustrationsLoaded!==true/);
assert.match(html, /cityVideo\\.poster=safeImage\\(person\\.image\\)/);
assert.match(html, /route\.page==='detail'&&c\.cloudPublic===true&&!c\.owner&&c\.publicIllustrationsLoaded!==true/);

// Encounter art remains independently lazy-loaded; owner/editor hydration remains unchanged.
assert.match(html, /async function hydrateEncounterGalleryIllustration\(characterId\)/);
assert.match(html, /async function hydrateCharacterIllustrationsIntoEditor\(characterId\)/);
console.log("Public character illustration lazy-loading tests passed.");
