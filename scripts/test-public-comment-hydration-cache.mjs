import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const start = html.indexOf("const CLOUD_COMMENT_CACHE_TTL_MS");
const end = html.indexOf("function renderComments()", start);
assert.ok(start >= 0 && end > start, "comment hydration cache block must exist");
const source = html.slice(start, end);

assert.match(source, /CLOUD_COMMENT_CACHE_TTL_MS\s*=\s*30_000/);
assert.match(source, /cloudCommentHydrationCache\s*=\s*new Map\(\)/);
assert.match(source, /cloudCommentHydrationInflight\s*=\s*new Map\(\)/);
assert.match(source, /async function loadCloudComments\(characterId,\{force=false\}=\{\}\)/);
assert.match(source, /const requestUid=currentUser\(\)\?\.uid\|\|null/);
assert.match(source, /const cacheKey=\(requestUid\|\|'anonymous'\)\+':'\+characterId/);
assert.match(source, /if\(!force&&Array\.isArray\(state\.comments\[characterId\]\)&&Date\.now\(\)-loadedAt<CLOUD_COMMENT_CACHE_TTL_MS\)return/);
assert.match(source, /cloudCommentHydrationInflight\.has\(cacheKey\)/);
assert.match(source, /cloudCommentHydrationCache\.set\(cacheKey,Date\.now\(\)\)/);
assert.match(source, /currentUser\(\)\?\.uid!==requestUid/);
assert.match(source, /cloudCommentHydrationInflight\.get\(cacheKey\)===request/);
assert.match(source, /cloudCommentHydrationInflight\.delete\(cacheKey\)/);
assert.match(source, /\.rpc\('get_character_comments_safe'/);
assert.match(source, /\.select\('comment_id,user_id'\)/);

console.log("Public comment hydration cache and account-isolation checks passed.");
