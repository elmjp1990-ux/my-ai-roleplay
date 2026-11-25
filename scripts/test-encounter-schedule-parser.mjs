import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const encounterScene = fs.readFileSync("encounter-scene.js", "utf8");
const cityMap = fs.readFileSync("city-map.js", "utf8");
const cityMapUiCss = fs.readFileSync("city-map-ui.css", "utf8");
const cleanupMigration = fs.readFileSync("supabase/migrations/20261031211200_character_illustration_cleanup_queue.sql", "utf8");
const scheduleOrganizer = fs.readFileSync("supabase/functions/_shared/encounter-schedule-organizer-handler.ts", "utf8");
const scheduleGeneration = fs.readFileSync("supabase/functions/_shared/encounter-schedule-generation.ts", "utf8");
const worldviewReviewMigration = fs.readFileSync("supabase/migrations/20261119000500_encounter_schedule_worldview_review_decisions.sql", "utf8");
const modernContextMigration = fs.readFileSync("supabase/migrations/20261123115500_encounter_schedule_modern_context_signals.sql", "utf8");
assert.ok(modernContextMigration.includes("男公關|牛郎|夜生活|地下樂團"));
assert.match(scheduleGeneration, /室內設計師\|室內設計\|空間設計師\|空間規劃\|設計事務所/);
assert.match(modernContextMigration, /poyozz-encounter-schedule-v10-modern-context-signals-2026-11-23/);


// The author-facing field must accept ordinary prose, not a pipe-delimited schema.
assert.match(html, /name="encounterScheduleDescription"/);
assert.match(html, /簡單描述角色平日、假日的生活作息/);
assert.match(html, /不需要填寫固定格式或精確時段/);
assert.doesNotMatch(html, /可直接用自然語言描述；不需要輸入星期代碼、時間格式或地點代碼。這份描述僅作者可查看。/);
assert.doesNotMatch(html, /name="clearEncounterSchedules"/);
assert.doesNotMatch(html, /function parseEncounterScheduleText\(raw\)/);
assert.doesNotMatch(html, /星期\(0=日、1=一/);

// City weather and dynamic scenes are session-cached to avoid repeat RPC egress on map re-entry.
assert.match(cityMap, /CITY_MAP_WEATHER_CACHE_TTL_MS = 50 \* 60 \* 1000/);
assert.match(cityMap, /CITY_MAP_SCENES_CACHE_TTL_MS = 30 \* 60 \* 1000/);
assert.match(cityMap, /sessionStorage\.getItem\('poyozz-city-map-/);
assert.match(cityMap, /readCityMapCache\('weather-v2'/);
assert.match(cityMap, /readCityMapCache\('scenes-v3'/);
assert.match(cityMap, /if\(cached\?\.fresh\)return/);

// Save/load must use the separate author-only description table.
assert.match(html, /async function saveEncounterScheduleDescription\(/);
assert.match(html, /async function loadEncounterScheduleDescriptionIntoEditor\(/);
assert.match(html, /from\('character_schedule_descriptions'\)/);
assert.match(html, /author_id: userId/);
assert.match(html, /\.eq\('author_id', user\.uid\)/);
assert.match(html, /await saveEncounterScheduleDescription\(c\.id, user\.uid, scheduleDescription\)/);

// Existing structured city schedules must not be overwritten with raw prose.
assert.doesNotMatch(html, /save_character_schedules/);
assert.doesNotMatch(html, /saveEncounterSchedules\(/);


 // Private Storage images must refresh expired signed URLs without exposing object paths.
assert.match(html, /async function refreshCharacterIllustrationSignedUrl\(storagePath\)/);
assert.match(html, /from\('character-illustrations'\)\.createSignedUrl\(path,3600\)/);
assert.match(html, /from\('character-illustrations'\)\.createSignedUrls\(paths,3600\)/);
assert.match(html, /data-character-illustration-path/);
assert.match(html, /document\.addEventListener\('error',[\s\S]*refreshCharacterIllustrationSignedUrl/);
assert.match(html, /document\.addEventListener\('load'/);
const publicLoader = html.slice(html.indexOf("function mapPublicCharacterRow(row)"), html.indexOf("async function loadSupabaseCharacters(user,options={})"));
assert.doesNotMatch(publicLoader, /loadCharacterIllustrationAssets|character_illustrations|createSignedUrl/);
assert.match(publicLoader, /image:ownerLocal\?\.image\|\|cachedPublic\?\.image\|\|row\.avatar_url/);
assert.match(publicLoader, /galleryIllustrations:ownerLocal\?\.galleryIllustrations\|\|cachedPublic\?\.galleryIllustrations\|\|\[\]/);
assert.match(html, /async function hydratePublicCharacterIllustrations\(characterId\)/);
assert.match(html, /loadCharacterIllustrationAssets\(\[characterId\]\)/);
assert.match(html, /current\.publicIllustrationsLoaded=true/);
assert.match(html, /route\.page==='detail'&&c\.cloudPublic===true&&!c\.owner/);
assert.match(html, /image: ownerPrimaryIllustrations\.get\(row\.id\)\?\.primary\?\.src \|\| row\.avatar_url/);
assert.match(html, /galleryIllustrations:local\.galleryIllustrations \|\| \[\]/);

// Gallery sync must keep nextGallery in function scope for post-upload persistence and cleanup.
assert.ok(html.includes("function retryCharacterIllustrationCleanup(userId) {"));
assert.match(html, /function planCharacterIllustrationGallerySync\(oldGallery,draftItems\)/);
assert.match(html, /const galleryPlan=planCharacterIllustrationGallerySync\(oldGallery,draftIllustrations\)/);
assert.match(html, /const usedSlots=new Set\(retainedRows\.map\(row=>Number\(row\.sort_order\)\)\)/);
assert.match(html, /reusableRow:obsoleteBySlot\.get\(freeSlot\)\|\|null/);

// Editing an existing character must finish illustration hydration before save.
// A failed load blocks save so an empty draft cannot be mistaken for intentional image removal.
assert.match(html, /let editorIllustrationHydration = \{characterId:null,status:'idle',promise:null,error:null\}/);
assert.match(html, /editorIllustrationHydration=\{characterId,status:'loading',promise:null,error:null\}/);
assert.match(html, /await hydration\.promise/);
assert.match(html, /editorIllustrationHydration\.status!=='loaded'/);
assert.match(html, /為避免誤刪既有圖片，本次未儲存/);
assert.match(html, /if\(!client\|\|!uid\|\|!characterId\|\|!owned\(state\.characters\.find\(item=>item\.id===characterId\)\)\)throw new Error/);

// An unchanged primary image reuses its existing Storage path instead of uploading a duplicate.
assert.match(html, /if\(!character\.avatarVideoPath&&\/\^data:image\\\/\//);
assert.match(html, /\(!oldPrimary\|\|draftPrimaryIllustrationPath!==oldPrimary\.storage_path\)/);

// Failed Storage deletions are durably queued, owner-scoped, and retried on asset loads/saves.
assert.ok(html.includes("async function enqueueCharacterIllustrationCleanup(storagePath,userId)"));
assert.ok(html.includes("async function processCharacterIllustrationCleanupJob(job,userId)"));
assert.ok(html.includes("帳號狀態或角色素材引用尚未允許清理"));
assert.ok(html.includes("can_process_character_illustration_cleanup"));
assert.ok(html.includes("uuidPattern.test(parts[1])"));
assert.ok(html.includes("function retryCharacterIllustrationCleanup(userId) {"));
assert.ok(html.includes("from('character_illustration_cleanup_jobs')"));
assert.ok(html.includes("await retryCharacterIllustrationCleanup(userId)"));
assert.match(cleanupMigration, /ENABLE ROW LEVEL SECURITY/);
assert.match(cleanupMigration, /GRANT SELECT, INSERT, UPDATE, DELETE/);
assert.match(cleanupMigration, /CREATE POLICY character_illustration_cleanup_jobs_select_own[\s\S]*?auth\.uid\(\)/);
assert.match(cleanupMigration, /CREATE POLICY character_illustration_cleanup_jobs_insert_own[\s\S]*?auth\.uid\(\)/);

// Scene portrait images and videos must not reintroduce a gray placeholder backdrop.
assert.match(html, /#cityCharacterCard \.city-character-portrait-video\{[^}]*background:transparent!important/);
assert.match(html, /\.city-character-portrait,\.city-character-portrait-video\{background:transparent!important/);
 
// City-scene avatars must be clipped by a dedicated transparent circular frame;
// the clickable button must not inherit the legacy square avatar backing.
assert.match(cityMap, /city-location-person-avatar-frame/);
assert.match(cityMap, /characterAvatarMarkup\(\{\.\.\.person,image,avatar_url:image\}/,
  "City map avatars must prefer the refreshed image URL over a stale raw avatar_url");
assert.match(cityMap, /characterAvatarMarkup\(\{\.\.\.person,image,avatar_url:image\}[^\n]*loading:'eager'/,
  "The selected character detail portrait must load eagerly");
assert.match(cityMap, /image\.dataset\.characterAvatarId\)return/,
  "City map must not replace shared avatar images before the signed-URL recovery handler retries them");
assert.match(html, /const loading=options\.loading==='eager'\?'eager':'lazy'/,
  "The shared avatar renderer must keep lazy loading by default and support eager detail portraits");
assert.doesNotMatch(cityMap, /class="city-location-avatar city-location-person"/);
assert.match(html, /\.city-location-person-avatar-frame\{[^}]*overflow:hidden[^}]*border-radius:50%[^}]*background:transparent!important/);
assert.match(html, /\.city-location-person-image\{[^}]*clip-path:circle\(50% at 50% 50%\)!important/);
assert.match(html, /#cityMapAvatarStrip > button\.city-location-person\{[^}]*all:unset!important[^}]*background:none!important[^}]*background-color:transparent!important[^}]*background-image:none!important/);
assert.match(html, /#cityMapAvatarStrip > button\.city-location-person::before,#cityMapAvatarStrip > button\.city-location-person::after\{content:none!important/);

// The card primary image is not reused as encounter-scene art.
assert.match(encounterScene, /const sceneIllustration=safeImage\(selectedGalleryImage\|\|character\?\.galleryIllustrations\?\.\[0\]\?\.src\|\|\x27\x27\)/);
// Restore muted inline card video playback while retaining lazy signed-URL hydration.
assert.ok(html.includes('<video data-character-video="${e(c.avatarVideoPath)}" poster="${e(safeImage(c.image))}" autoplay muted loop playsinline preload="none"'));
assert.ok(html.includes("function hydrateEncounterGalleryIllustration(characterId,illustrationId=null) {"));
assert.ok(encounterScene.includes("正在載入角色立繪…"));
assert.ok(encounterScene.includes("角色半立繪素材待補"));
assert.ok(html.includes("const ownerLocal=state.characters.find(character=>"));
assert.ok(html.includes("ownerLocal?.galleryIllustrations||cachedPublic?.galleryIllustrations||[]"));
assert.match(encounterScene, /const halfBodyImage=selectedGalleryImage\|\|dedicatedSprite\|\|sceneIllustration/);
assert.doesNotMatch(html, /const cardPortrait=safeImage\(character\?\.image/);
assert.match(html, /相遇模式立繪（最多 5 張）/);
assert.match(html, /主要角色圖預覽/);

// Lazy video observer must dispatch to each observed element through the dwell gate.
assert.ok(html.includes("const characterVideoLoaders = new WeakMap()"));
assert.ok(html.includes("characterVideoLoaders.set(video,load)"));
assert.doesNotMatch(html, /characterVideoDebugSequence|videoDebugId|\[character-video\]/, "Temporary media diagnostics must not ship in production UI code");
assert.ok(html.includes("scheduleCharacterVideoLoad(target)"));
assert.ok(html.includes("const load=characterVideoLoaders.get(video)"));
// Scrolling away or backgrounding pauses playback but preserves src and preload state;
// changing preload while attached can restart the same full MP4 request.
const pauseFnStart=html.indexOf("function pauseCharacterVideo(video){");
const pauseFnEnd=html.indexOf("\n}",pauseFnStart);
const pauseFn=html.slice(pauseFnStart,pauseFnEnd);
assert.ok(pauseFn.includes("video.pause();"));
assert.ok(!pauseFn.includes("video.preload="));
assert.ok(html.includes("if(target.dataset.videoHydrated==='true'){if(target.paused)target.play().catch(()=>{});}"));
assert.ok(html.includes("function releaseCharacterVideo(video){"));
// Assigning src already starts media loading; an immediate load() would restart a full-range request.
const videoHydrationStart=html.indexOf("function hydrateCharacterVideo(video){");
const videoLoadStart=html.indexOf("const load=async()=>{",videoHydrationStart);
const videoLoadEnd=html.indexOf("\n  };",videoLoadStart);
const videoLoadBlock=html.slice(videoLoadStart,videoLoadEnd);
assert.ok(videoLoadBlock.indexOf("video.preload='metadata';") < videoLoadBlock.indexOf("video.src=signedUrl;"));
assert.ok(!videoLoadBlock.includes("video.load();"));

assert.ok(html.includes("pauseCharacterVideo(target);"));
assert.ok(html.includes("videos.forEach(video=>{"));
assert.ok(html.includes("video.dataset.videoVisibilityEligible='false';"));
assert.ok(html.includes("clearCharacterVideoVisibilityTimer(video);"));
assert.ok(html.includes("pauseCharacterVideo(video);"));
// Only a real pagehide releases the media source.
assert.ok(html.includes("document.querySelectorAll('video[data-character-video]').forEach(releaseCharacterVideo);"));
assert.ok(!html.includes("function stopCharacterVideo(video){"));
assert.ok(html.includes("document.addEventListener('visibilitychange'"));
assert.ok(html.includes("window.addEventListener('pagehide'"));
assert.ok(html.includes("},{rootMargin:'0px',threshold:[0,0.15,0.35]}"));
 // Infinite-scroll appends only new cards so existing video DOM nodes remain attached.
assert.ok(html.includes("function renderGrid({append=false}={})"));
assert.ok(html.includes("const existingCardCount=append?grid.querySelectorAll(':scope > article.card').length:0;"));
assert.ok(html.includes("const newCards=append&&existingCardCount>0?shown.slice(existingCardCount):shown;"));
assert.ok(html.includes("if(append&&existingCardCount>0){"));
assert.ok(html.includes("grid.insertAdjacentHTML('beforeend',cardMarkup)"));
assert.ok((html.match(/renderGrid\(\{append:true\}\);/g)||[]).length >= 2);

 // Search/filter redraws preserve the same character's existing media DOM when the path is unchanged.
 assert.ok(html.includes('data-character-card-id="${e(c.id)}"'));
 assert.ok(html.includes("const existingVideosByCharacter=new Map()"));
 assert.ok(html.includes("previousVideo.dataset.characterVideo===nextVideo.dataset.characterVideo"));
 assert.ok(html.includes("nextVideo.replaceWith(previousVideo)"));
 assert.ok(html.includes("grid.querySelectorAll('video[data-character-video]').forEach(video=>void hydrateCharacterVideo(video))"));
 // City-character tab/page redraws must reuse the existing portrait video for the same Storage path.
 assert.ok(cityMap.includes("const previousCharacterVideo=body.querySelector('video.city-character-portrait-video[data-character-video]')"));
 assert.ok(cityMap.includes("previousCharacterVideo.dataset.characterVideo===characterVideo.dataset.characterVideo"));
 assert.ok(cityMap.includes("characterVideo.replaceWith(previousCharacterVideo)"));
 // Route-level rerenders preserve card videos outside Explore's renderGrid path.
 assert.ok(html.includes("function captureCharacterCardVideos(root)"));
 assert.ok(html.includes("function restoreCharacterCardVideos(root,previousVideos)"));
 assert.ok(html.includes("const previousCardVideos=captureCharacterCardVideos($('view'));"));
 assert.ok(html.includes("restoreCharacterCardVideos($('view'),previousCardVideos);"));

 // Detail-page rerenders must reuse the same video DOM when the Storage path is unchanged.
 assert.ok(html.includes("const previousDetailVideo = view?.querySelector('.detail-portrait video[data-character-video]') || null"));
 assert.ok(html.includes("previousDetailVideo.dataset.characterVideo===detailVideo.dataset.characterVideo"));
 assert.ok(html.includes("detailVideo.replaceWith(previousDetailVideo)"));
 assert.ok(html.includes("releaseCharacterVideo(previousDetailVideo)"));
 // Discarded Explore and city portrait nodes must release their detached media resources.
 assert.ok(html.includes("existingVideosByCharacter.forEach(video=>{\n      characterVideoObserver?.unobserve(video);\n      releaseCharacterVideo(video);"));
 assert.match(cityMap, /else if\(previousCharacterVideo\)\{\s*characterVideoObserver\?\.unobserve\(previousCharacterVideo\);\s*releaseCharacterVideo\(previousCharacterVideo\);/);
 assert.ok(html.includes("video.dataset.videoObservePending='false';"));
 assert.ok(html.includes("window.addEventListener('pageshow',()=>{"));
 assert.ok(html.includes("void hydrateCharacterVideo(video);"));
 assert.ok(html.includes("if(previousDetailVideo){\n      characterVideoObserver?.unobserve(previousDetailVideo);\n      releaseCharacterVideo(previousDetailVideo);\n    }"));



// Illustration metadata reads are single-flight and author cleanup is never implicit for public loads.
assert.ok(html.includes("const characterIllustrationMetadataInflight = new Map()"));
assert.ok(html.includes("async function loadCharacterIllustrationAssets(characterIds, cleanupUserId=null)"));
assert.ok(html.includes("if(cleanupUserId)await retryCharacterIllustrationCleanup(cleanupUserId)"));

// Owned character hydration fetches the latest story through the bounded RPC.
// Public character detail no longer reads opening text; it belongs only to chat startup.
assert.ok(html.includes("client.rpc('get_latest_owned_character_stories'"), "Owned character hydration must fetch only the latest story per character through the bounded RPC.");
const detailMetadataStart = html.indexOf("async function hydratePublicCharacterDetailMetadata");
const detailMetadataEnd = html.indexOf("async function hydratePublicCharacterIllustrations", detailMetadataStart);
assert.ok(detailMetadataStart >= 0 && detailMetadataEnd > detailMetadataStart, "public character detail metadata block must exist");
const detailMetadata = html.slice(detailMetadataStart, detailMetadataEnd);
assert.ok(!detailMetadata.includes("character_stories") && !detailMetadata.includes("opening_message"), "Public character detail must not fetch opening text.");
assert.ok(!html.includes(".select('id, character_id, story_name, description, opening_message, visibility, created_at')"));

// Manual schedule repair must use only supported rainy-day scene labels and canonicalize common aliases.
const scheduleRepairStart = html.indexOf("function autoCorrectEncounterScheduleOutput");
const scheduleRepairEnd = html.indexOf("async function loadEncounterScheduleRepairOutputs", scheduleRepairStart);
assert.ok(scheduleRepairStart >= 0 && scheduleRepairEnd > scheduleRepairStart, "schedule repair normalizer must exist");
const scheduleRepair = html.slice(scheduleRepairStart, scheduleRepairEnd);
assert.match(scheduleRepair, /\['livehouse','展演空間'\]/);
assert.match(scheduleRepair, /\['練團室','展演空間'\]/);
assert.match(scheduleRepair, /\['頂樓出租屋','308公寓'\]/);
assert.match(scheduleRepair, /'便利商店','高級會所'/);
assert.match(scheduleRepair, /option\.rain_fallback_location='便利商店'/);
assert.match(scheduleRepair, /改到便利商店內避雨，買杯熱飲休息/);
assert.doesNotMatch(scheduleRepair, /option\.rain_fallback_location='咖啡廳'/);
assert.doesNotMatch(scheduleRepair, /'書店','咖啡廳'/);

// Unknown worldview review is author-scoped and decisions never invoke AI inline.
assert.match(scheduleOrganizer, /\.eq\("status", "needs_review"\)\.eq\("author_id", actorUserId\)/);
assert.match(scheduleOrganizer, /\.eq\("status", "pending"\)\.eq\("author_id", actorUserId\)/);
assert.match(scheduleOrganizer, /\.eq\("status", "processing"\)\.eq\("author_id", actorUserId\)/);
assert.match(worldviewReviewMigration, /p_force IS NOT TRUE OR j\.author_id = p_actor_user_id/);

assert.match(scheduleOrganizer, /getEncounterWorldviewScheduleDisposition\([\s\S]*?source\.worldview_review_decision/);
assert.match(html, /data-action="worldview-review-decision"/);
assert.match(html, /review_encounter_schedule_worldview/);
assert.match(html, /只會加入待生成佇列，不會立即呼叫 AI/);
assert.match(html, /保留既有行程與招呼池/);
assert.match(html, /modern_map_compatible/);
assert.match(html, /not_applicable/);

console.log("Author schedule and illustration signed-URL refresh contract tests passed.");

assert.match(cityMap, /get_encounter_city_weather_v2/);
assert.doesNotMatch(cityMap, /get_encounter_city_weather\(\)/);