import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const publicLoaderStart = html.indexOf("async function loadPublicSupabaseCharactersImpl()");
const publicLoaderEnd = html.indexOf("async function loadSupabaseCharacters(user)", publicLoaderStart);
assert.ok(publicLoaderStart >= 0 && publicLoaderEnd > publicLoaderStart, "public character loader boundaries must exist");
const publicLoader = html.slice(publicLoaderStart, publicLoaderEnd);

// Keep all public roles available for search, filters, sorting and city schedules,
// while avoiding bulk profile/story/illustration reads for the entire catalogue.
assert.doesNotMatch(publicLoader, /loadCharacterIllustrationAssets|character_illustrations|createSignedUrl|public_profiles|character_stories/);
assert.doesNotMatch(publicLoader, /phone_settings|nsfw_workplace_warning/);
assert.match(publicLoader, /Object\.prototype\.hasOwnProperty\.call\(ownerLocal,'phoneSettings'\)/);
assert.match(publicLoader, /image: ownerLocal\?\.image \|\| cachedPublic\?\.image \|\| row\.avatar_url/);
assert.match(publicLoader, /primaryIllustrationPath:ownerLocal\?\.primaryIllustrationPath \|\| cachedPublic\?\.primaryIllustrationPath/);
assert.match(publicLoader, /galleryIllustrations:ownerLocal\?\.galleryIllustrations \|\| cachedPublic\?\.galleryIllustrations \|\| \[\]/);
assert.match(publicLoader, /publicIllustrationsLoaded:ownerLocal\?\.publicIllustrationsLoaded === true \|\| cachedPublic\?\.publicIllustrationsLoaded === true/);
assert.match(publicLoader, /opening: ownerLocal\?\.opening \|\| cachedPublic\?\.opening \|\| ''/);

// Opening text and complete public author profile are loaded only when their pages need them.
assert.match(html, /async function hydratePublicCharacterDetailMetadata\(characterId\)/);
assert.match(html, /publicCharacterStoryOpeningLoaded\.has\(characterId\)/);
assert.match(html, /async function hydratePublicAuthorProfile\(authorId\)/);
assert.match(html, /publicAuthorProfileLoaded\.has\(authorId\)/);
assert.match(html, /publicAuthorProfileLoaded\.has\(route\.id\)/);
assert.match(html, /if\(c\.authorId\)void hydratePublicAuthorProfile\(c\.authorId\)/);
assert.match(html, /\.select\('opening_message'\)/);
assert.match(html, /\.select\('id,handle,nickname,avatar_url,bio,follower_count'\)/);
assert.match(html, /data-character-opening/);
assert.match(html, /data-character-author-name/);

// Primary art is fetched only for visible cards, an opened detail, or a selected city character.
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
assert.match(html, /function observePublicCharacterIllustrationCards\(root\)/);
assert.match(html, /observePublicCharacterIllustrationCards\(grid\)/);
assert.match(html, /observePublicCharacterIllustrationCards\(\$\('view'\)\)/);
assert.match(html, /new IntersectionObserver\(entries=>/);
assert.match(html, /person\.cloudPublic===true&&!image&&person\.publicIllustrationsLoaded!==true/);
assert.match(html, /cityVideo\.poster=safeImage\(person\.image\)/);
assert.match(html, /locationModal\.dataset\.cardMode===mode&&card\.dataset\.page===String\(page\)/);
assert.match(html, /route\.page==='detail'&&c\.cloudPublic===true&&!c\.owner/);

// Encounter gallery and owner/editor asset hydration remain unchanged.
assert.match(html, /async function hydrateEncounterGalleryIllustration\(characterId\)/);
assert.match(html, /async function hydrateCharacterIllustrationsIntoEditor\(characterId\)/);
console.log("Public character detail payload lazy-loading tests passed.");
