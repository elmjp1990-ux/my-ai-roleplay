import fs from "node:fs";
import assert from "node:assert/strict";

const frontend = fs.readFileSync("index.html", "utf8");
const chatTurn = fs.readFileSync("supabase/functions/chat-turn/index.ts", "utf8");
const phaseOne = fs.readFileSync(
  "supabase/migrations/20261104062017_move_character_personality_profile_to_private_info.sql",
  "utf8",
);
const phaseOneAccess = fs.readFileSync(
  "supabase/migrations/20261104095000_restrict_legacy_personality_profile_select.sql",
  "utf8",
);

// The public characters table must never be queried for the author-only profile.
assert.doesNotMatch(
  frontend,
  /\.from\(["']characters["']\)[\s\S]{0,700}?\.select\(["'][^"']*personality_profile/i,
  "frontend must not select personality_profile from public.characters",
);
assert.doesNotMatch(
  chatTurn,
  /from\(["']characters["']\)[\s\S]{0,300}?select\(["'][^"']*personality_profile/i,
  "Story AI must not select personality_profile from public.characters",
);

// Avoid wildcard selects: they would silently re-expose the legacy public column.
assert.doesNotMatch(
  frontend,
  /\.from\(["']characters["']\)[\s\S]{0,500}?\.select\(["']\*["']\)/i,
  "frontend must not wildcard-select public characters rows",
);
assert.doesNotMatch(
  chatTurn,
  /from\(["']characters["']\)[\s\S]{0,300}?select\(["']\*["']\)/i,
  "Story AI must not wildcard-select public characters rows",
);

// The owner-only table remains the only source for author-only personality data.
assert.match(
  frontend,
  /\.from\(["']character_private_info["']\)[\s\S]{0,300}?\.select\(["']character_id, private_info, personality_profile["']\)/,
  "frontend must load personality_profile from character_private_info",
);
assert.match(
  chatTurn,
  /from\(["']character_private_info["']\)[\s\S]{0,300}?select\(["']private_info,personality_profile["']\)/,
  "Story AI must load personality_profile from character_private_info",
);

// Legacy chat snapshots must not re-expose author-only private settings to players.
assert.match(
  frontend,
  /personalityProfile:\s*_legacyPersonalityProfile,[\s\S]{0,250}personality_profile:\s*_legacyPersonalityProfileSnakeCase,[\s\S]{0,120}\.\.\.safePriorSnapshot/,
  "chat sync must strip camelCase and snake_case private fields before writing snapshots",
);
assert.match(
  frontend,
  /const rawSnapshot = row\.character_snapshot[\s\S]{0,500}personalityProfile:\s*_legacyPersonalityProfile,[\s\S]{0,250}\.\.\.snapshot\s*\} = rawSnapshot/,
  "chat hydration must strip legacy private fields before exposing snapshots to client state",
);

assert.match(
  frontend,
  /personalityProfile:\s*_legacyPersonalityProfile,[\s\S]{0,250}personality_profile:\s*_legacyPersonalityProfileSnakeCase,[\s\S]{0,150}\.\.\.safeCloudSnapshot/,
  "character deletion must strip legacy private fields from the cloud snapshot too",
);

// Phase 1 must remain additive; dropping the public column is a separate post-deploy contract migration.
assert.doesNotMatch(
  phaseOne,
  /drop\s+column\s+(if\s+exists\s+)?personality_profile/i,
  "Phase 1 must not drop the legacy public column",
);

// During the compatibility window, public roles may read only an explicit safe-column allowlist.
assert.match(
  phaseOneAccess,
  /revoke\s+select\s+on\s+table\s+public\.characters\s+from\s+anon\s*,\s*authenticated/i,
  "public roles must lose table-level SELECT on characters",
);
const safeSelectGrant = phaseOneAccess.match(/grant\s+select\s*\(([\s\S]*?)\)\s+on\s+table\s+public\.characters\s+to\s+anon\s*,\s*authenticated/i);
assert.ok(safeSelectGrant, "approved character columns must be granted explicitly");
assert.doesNotMatch(
  safeSelectGrant[1],
  /personality_profile/i,
  "legacy personality_profile must not be in the public column allowlist",
);

console.log("Private personality column usage and two-phase migration contract checks passed.");
