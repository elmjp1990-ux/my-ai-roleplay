import assert from "node:assert/strict";
import fs from "node:fs";

const schema = JSON.parse(fs.readFileSync("supabase/drafts/character-ai-profile-v1.schema.json", "utf8"));
const registry = JSON.parse(fs.readFileSync("supabase/drafts/character-ai-profile-source-registry-v1.json", "utf8"));
const frontend = fs.readFileSync("index.html", "utf8");
const migration = fs.readFileSync("supabase/migrations/20261107120000_character_ai_profile_organization_queue.sql", "utf8");
const schedulerMigration = fs.readFileSync("supabase/migrations/20261107123000_schedule_character_profile_organization_worker.sql", "utf8");
const worker = fs.readFileSync("supabase/functions/character-profile-organization-worker/index.ts", "utf8");
const workerCore = fs.readFileSync("supabase/functions/_shared/character-profile-organization.ts", "utf8");
const storyTurn = fs.readFileSync("supabase/functions/chat-turn/index.ts", "utf8");

assert.equal(schema.$schema, "https://json-schema.org/draft/2020-12/schema");
assert.equal(schema.properties.schema_version.const, "1.0");
assert.equal(schema.additionalProperties, false);

const required = new Set(schema.required);
for (const key of [
  "identity_background", "core_personality", "inner_motivations",
  "emotional_response_patterns", "relationship_dynamics", "behavior_and_agency",
  "knowledge_boundaries", "speech_style", "appearance_markers",
  "author_private_context", "ooc_rules", "unknowns", "source_conflicts",
]) assert.ok(required.has(key), `Profile schema must require ${key}`);
assert.ok(!required.has("life_schedule_context"), "Schedules must remain runtime context, not stale derived profile data");

const ooc = schema.properties.ooc_rules;
assert.ok(ooc.allOf.some(rule => rule.if?.properties?.status?.const === "ready" && rule.then?.properties?.rules?.minItems === 3),
  "Ready OOC profiles must contain at least three supported rules");
assert.ok(ooc.allOf.some(rule => rule.if?.properties?.status?.const === "insufficient_source" && rule.then?.properties?.rules?.maxItems === 2),
  "Insufficient source data must not force fabricated OOC rules");
assert.ok(schema.properties.speech_style.properties.example_lines.maxItems === 0,
  "Generated example dialogue must be prohibited");
assert.equal(
  schema.properties.speech_style.properties.creator_defined_quirks.items.allOf[0].properties.source_type.const,
  "author_explicit",
  "Catchphrases must only come from explicit author sources",
);
assert.equal(schema.properties.author_private_context.properties.visibility.const, "server_only",
  "Author private context must be backend-only");

const refreshPaths = new Set(registry.profile_refresh_sources.map(item => item.path));
const runtimePaths = new Set(registry.runtime_only_sources.map(item => item.path));
for (const path of [
  "characters.intro", "characters.race", "characters.style",
  "character_private_info.private_info",
  "character_private_info.personality_profile.coreTraits",
  "character_private_info.personality_profile.values",
  "character_private_info.personality_profile.speechStyle",
  "character_private_info.personality_profile.behaviorRules",
  "character_private_info.personality_profile.likes",
  "character_private_info.personality_profile.dislikes",
  "character_private_info.personality_profile.boundaries",
  "character_private_info.personality_profile.relationshipPacing",
]) assert.ok(refreshPaths.has(path), `Missing AI refresh source ${path}`);

for (const path of [
  "characters.phone_settings", "character_schedules", "character_schedule_descriptions",
  "characters.name", "characters.gender", "characters.age",
]) {
  assert.ok(runtimePaths.has(path), `Missing runtime-only source ${path}`);
  assert.ok(!refreshPaths.has(path), `${path} must not trigger derived profile refresh`);
}

const aiProfileFields = frontend.slice(frontend.indexOf("const aiProfileFields"), frontend.indexOf("for (const [key, label] of Object.entries(aiProfileFields))"));
assert.ok(aiProfileFields.length > 0, "Character save classifier must define its personality field allowlist");
for (const key of ["coreTraits", "values", "speechStyle", "behaviorRules", "likes", "dislikes", "boundaries", "relationshipPacing"]) {
  assert.match(aiProfileFields, new RegExp(`\\b${key}:`), `Classifier must diff ${key}`);
}
for (const key of ["intro", "race", "style", "private_info"]) {
  assert.ok(frontend.includes(`compareCharacterField(aiRelevantChanges, '${key}'`),
    `Classifier must diff AI source field ${key}`);
}
assert.match(frontend, /compareCharacterField\(runtimeAiChanges, 'phone_settings'/,
  "Phone settings must stay in runtime AI configuration changes");
assert.match(frontend, /compareCharacterField\(nonAiChanges, 'name'/,
  "Character renaming must not trigger profile generation");
assert.match(frontend, /shouldCallModel: false/,
  "The browser must never call the model directly");
assert.match(frontend, /enqueue_character_profile_organization/,
  "A verified character save must enqueue a derived-profile refresh");
assert.match(frontend, /if \(aiOrganizationDecision\.requiresDerivedRefresh === true\)/,
  "Only AI-relevant source changes may enqueue a refresh");
assert.ok(frontend.indexOf("const { data: savedCharacter") < frontend.indexOf("enqueue_character_profile_organization"),
  "Profile enqueue must happen only after persisted character data is verified");

for (const rpc of [
  "enqueue_character_profile_organization",
  "claim_character_profile_organization_jobs",
  "complete_character_profile_organization_job",
  "fail_character_profile_organization_job",
  "get_character_ai_profile_for_chat",
]) assert.ok(migration.includes(rpc), `Migration must define ${rpc}`);
assert.match(migration, /FOR UPDATE SKIP LOCKED/, "Worker claims must be atomic and skip locked jobs");
assert.match(migration, /extensions\.digest[\s\S]*sha256/, "Source versions must use SHA-256");
assert.match(migration, /REVOKE ALL ON public\.character_profile_organization[\s\S]*FROM PUBLIC, anon, authenticated/,
  "Derived profile tables must not be directly readable by players");
assert.match(worker, /deepseek\/deepseek-v4-flash-20260423|CHARACTER_PROFILE_MODEL/,
  "Worker must use the confirmed DeepSeek V4 Flash 0423 model");
assert.match(worker, /OPENROUTER_API_KEY/, "Worker must read the provider key only from server environment");
assert.match(workerCore, /validateCharacterAiProfile/, "Worker output must pass strict profile validation");
assert.match(workerCore, /source_refs/, "Every derived statement must cite allowlisted source paths");
assert.match(storyTurn, /get_character_ai_profile_for_chat/,
  "Story chat-turn must load only a source-current derived profile");
assert.match(storyTurn, /collectDerivedPrivateProfileValues/,
  "Private-derived evidence must join the server-side output leak guard");
assert.match(storyTurn, /CHAR_AI_PROFILE/,
  "Story system prompt must receive the derived profile and OOC context");
assert.match(migration, /Keep profile organization serial by default/,
  "The queue should serialize model work to control generation spend");
assert.match(migration, /cleanup_character_profile_organization_on_soft_delete/,
  "Soft-deleting a character must clear its pending jobs and private derived profile");
assert.match(schedulerMigration, /poyozz_supabase_url/,
  "Worker scheduling must read the project URL from Supabase Vault");
assert.match(schedulerMigration, /poyozz_service_role_key/,
  "Worker scheduling must read the service role key from Vault, never source code");
assert.match(schedulerMigration, /\* \* \* \* \*/,
  "Worker cron should poll the queue every minute");
assert.match(schedulerMigration, /vault_secrets_missing/,
  "Missing Vault secrets must fail closed without creating a schedule");

console.log("Character AI Profile schema, queue, Worker, scheduling, save enqueue, Story integration and privacy contracts passed.");
