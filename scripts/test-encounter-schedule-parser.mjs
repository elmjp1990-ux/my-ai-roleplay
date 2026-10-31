import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const cleanupMigration = fs.readFileSync("supabase/migrations/20261031211200_character_illustration_cleanup_queue.sql", "utf8");

// The author-facing field must accept ordinary prose, not a pipe-delimited schema.
assert.match(html, /name="encounterScheduleDescription"/);
assert.match(html, /簡單描述角色平日、假日的生活作息/);
assert.match(html, /不需要填寫固定格式或精確時段/);
assert.doesNotMatch(html, /可直接用自然語言描述；不需要輸入星期代碼、時間格式或地點代碼。這份描述僅作者可查看。/);
assert.doesNotMatch(html, /name="clearEncounterSchedules"/);
assert.doesNotMatch(html, /function parseEncounterScheduleText\(raw\)/);
assert.doesNotMatch(html, /星期\(0=日、1=一/);

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
assert.match(html, /createSignedUrl\(storagePath,3600\)/);
assert.match(html, /data-character-illustration-path/);
assert.match(html, /document\.addEventListener\('error',[\s\S]*refreshCharacterIllustrationSignedUrl/);
assert.match(html, /document\.addEventListener\('load'/);
assert.match(html, /image: publicIllustrations\.get\(row\.id\)\?\.primary\?\.src \|\| row\.avatar_url/);
assert.match(html, /image: ownerIllustrations\.get\(row\.id\)\?\.primary\?\.src \|\| row\.avatar_url/);

// Gallery sync must keep nextGallery in function scope for post-upload persistence and cleanup.
assert.match(html, /async function syncCharacterIllustrations\([\s\S]*?let nextPrimaryPath=draftPrimaryIllustrationPath\|\|\x27\x27;\s*const nextGallery=\[\];\s*try\{/);
assert.doesNotMatch(html, /const usedSlots=new Set\([\s\S]*?\n\s*const nextGallery=\[\];/);

// Failed Storage deletions are durably queued, owner-scoped, and retried on asset loads/saves.
assert.ok(html.includes("async function enqueueCharacterIllustrationCleanup(storagePath,userId)"));
assert.ok(html.includes("async function processCharacterIllustrationCleanupJob(job,userId)"));
assert.ok(html.includes("async function retryCharacterIllustrationCleanup(userId)"));
assert.ok(html.includes("from('character_illustration_cleanup_jobs')"));
assert.ok(html.includes("await retryCharacterIllustrationCleanup(userId)"));
assert.match(cleanupMigration, /ENABLE ROW LEVEL SECURITY/);
assert.match(cleanupMigration, /GRANT SELECT, INSERT, UPDATE, DELETE/);
assert.match(cleanupMigration, /CREATE POLICY character_illustration_cleanup_jobs_select_own[\s\S]*?auth\.uid\(\)/);
assert.match(cleanupMigration, /CREATE POLICY character_illustration_cleanup_jobs_insert_own[\s\S]*?auth\.uid\(\)/);

// The card primary image is not reused as encounter-scene art.
assert.match(html, /const sceneIllustration=safeImage\(character\?\.galleryIllustrations\?\.\[0\]\?\.src\|\|\x27\x27\)/);
assert.match(html, /const halfBodyImage=dedicatedSprite\|\|sceneIllustration/);
assert.doesNotMatch(html, /const cardPortrait=safeImage\(character\?\.image/);
assert.match(html, /相遇模式立繪（最多 5 張）/);
assert.match(html, /主要角色圖預覽/);

console.log("Author schedule and illustration signed-URL refresh contract tests passed.");
