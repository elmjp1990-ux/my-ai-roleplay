import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");

// The author-facing field must accept ordinary prose, not a pipe-delimited schema.
assert.match(html, /name="encounterScheduleDescription"/);
assert.match(html, /簡單描述角色平日、假日的生活作息/);
assert.match(html, /不需要填寫固定格式或精確時段/);
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

console.log("Author schedule and illustration signed-URL refresh contract tests passed.");
