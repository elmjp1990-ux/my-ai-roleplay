import fs from "node:fs";
import assert from "node:assert/strict";

const sql = fs.readFileSync(
  "supabase/drafts/chat-deletion-cumulative-turn-statistics-proposal.sql",
  "utf8",
);

function functionBody(name) {
  const start = sql.indexOf(`CREATE OR REPLACE FUNCTION public.${name}`);
  assert.ok(start >= 0, `missing function: ${name}`);
  const next = sql.indexOf("\nCREATE OR REPLACE FUNCTION ", start + 1);
  return sql.slice(start, next < 0 ? sql.length : next);
}

const allowedStart = sql.indexOf("  allowed AS (");
const soloStart = sql.indexOf("  solo_counts AS (", allowedStart);
assert.ok(allowedStart >= 0 && soloStart > allowedStart, "allowed CTE is missing");
const allowed = sql.slice(allowedStart, soloStart);

// A character's own author may still inspect their historical turn statistics
// after soft deletion. Public access must continue to require a live public work.
assert.match(allowed, /c\.author_id\s*=\s*\(SELECT auth\.uid\(\)\)/);
assert.match(allowed, /c\.deleted_at\s+IS\s+NULL\s+AND\s+c\.visibility\s*=\s*'public'/);
assert.doesNotMatch(
  allowed,
  /WHERE\s+c\.deleted_at\s+IS\s+NULL\s+AND\s*\(\s*c\.author_id/,
  "global deleted_at filter would incorrectly hide an author's own deleted-character statistics",
);

const publicCount = functionBody("get_public_character_turn_count");
assert.match(publicCount, /c\.visibility\s*=\s*'public'/);
assert.match(publicCount, /c\.deleted_at\s+IS\s+NULL/);

for (const name of [
  "delete_chat_session_content",
  "delete_chat_group_with_related_data",
  "purge_chat_deletion_job",
]) {
  assert.match(
    functionBody(name),
    /snapshot_chat_deletion_character_turn_stats\(/,
    `${name} must snapshot per-character turns before content is hidden or purged`,
  );
}

assert.match(sql, /UNIQUE\s*\(resource_type,\s*resource_id,\s*character_id\)/);
assert.match(sql, /ALTER TABLE public\.chat_deletion_character_turn_stats ENABLE ROW LEVEL SECURITY/);
assert.match(sql, /REVOKE ALL ON TABLE public\.chat_deletion_character_turn_stats\s+FROM PUBLIC, anon, authenticated, service_role/);

console.log("Chat deletion cumulative turn-stat draft guards passed.");
