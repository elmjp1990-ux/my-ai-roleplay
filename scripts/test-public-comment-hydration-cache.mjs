import assert from "node:assert/strict";
import fs from "node:fs";

const html = fs.readFileSync("index.html", "utf8");
const commentRenderer = fs.readFileSync("comment-renderer.js", "utf8");
const start = html.indexOf("const CLOUD_COMMENT_CACHE_TTL_MS");
const end = html.indexOf("function renderComments()", start);
assert.ok(start >= 0 && end > start, "comment hydration cache block must exist");
const source = html.slice(start, end);

assert.match(source, /CLOUD_COMMENT_CACHE_TTL_MS\s*=\s*30_000/);
assert.match(source, /cloudCommentHydrationCache\s*=\s*new Map\(\)/);
assert.match(source, /cloudCommentHydrationInflight\s*=\s*new Map\(\)/);
assert.match(source, /async function loadCloudComments\(characterId,\{force=false,loadMore=false\}=\{\}\)/);
assert.match(source, /const requestUid=currentUser\(\)\?\.uid\|\|null/);
assert.match(source, /const cacheKey=\(requestUid\|\|'anonymous'\)\+':'\+characterId/);
assert.match(source, /if\(!loadMore&&!force&&cached&&Date\.now\(\)-cached\.loadedAt<CLOUD_COMMENT_CACHE_TTL_MS\)/);
assert.match(source, /state\.comments\[characterId\]=cached\.rows/);
assert.match(source, /cloudCommentHydrationInflight\.has\(cacheKey\)/);
assert.match(source, /cloudCommentHydrationCache\.set\(cacheKey,\{loadedAt:Date\.now\(\),rows:state\.comments\[characterId\]\}\)/);
assert.match(source, /currentUser\(\)\?\.uid!==requestUid/);
assert.match(source, /cloudCommentHydrationInflight\.get\(cacheKey\)===request/);
assert.match(source, /cloudCommentHydrationInflight\.delete\(cacheKey\)/);
assert.match(source, /\.rpc\('get_character_comments_safe_page'/);
assert.match(source, /\.select\('comment_id,user_id'\)/);

const renderSource = commentRenderer;
assert.match(renderSource, /const cacheUid=currentUser\(\)\?\.uid\|\|null/);
assert.match(renderSource, /if\(cached\)cached\.rows=allComments/);

console.log("Public comment hydration cache and account-isolation checks passed.");
