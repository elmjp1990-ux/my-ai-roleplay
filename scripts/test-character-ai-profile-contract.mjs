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
assert.ok(frontend.indexOf("enqueue_character_profile_organization") < frontend.indexOf("const { data: existingStory"),
  "Profile enqueue must not be skipped by a later opening-story lookup/save failure");
assert.match(frontend, /storyError: '角色已儲存，但讀取故事資料失敗：' \+ lookupError\.message, profileQueueError/,
  "Story lookup failure must still report the independent profile enqueue result");

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
assert.match(worker, /data_collection: "deny"/, "Profile requests must enforce POYOZZ's no-provider-data-collection policy");
assert.match(worker, /only: \["deepinfra"\]/, "Profile requests must use the same approved provider route as Story generation");
assert.match(migration, /character_profile_organization_usage/,
  "Profile generation must have a separate private usage/cost ledger, not reuse the queue");
assert.match(worker, /character_profile_organization_usage/,
  "Worker must record token and cost metadata for each generation");
assert.match(worker, /prompt_tokens:[\s\S]*completion_tokens:[\s\S]*total_tokens:[\s\S]*cost_usd:/,
  "Profile usage ledger must capture provider token and cost fields");
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
assert.match(migration, /pg_try_advisory_xact_lock/,
  "Concurrent cron invocations must not claim multiple profile jobs");
assert.match(migration, /cleanup_character_profile_organization_on_soft_delete/,
  "Soft-deleting a character must clear its pending jobs and private derived profile");
assert.match(schedulerMigration, /poyozz_supabase_url/,
  "Worker scheduling must read the project URL from Supabase Vault");
assert.match(schedulerMigration, /poyozz_service_role_key/,
  "Worker scheduling must read the service role key from Vault, never source code");
const cronCommandStart = schedulerMigration.indexOf("v_command := $command$");
const cronCommandEnd = schedulerMigration.indexOf("$command$;", cronCommandStart);
const cronCommand = cronCommandStart >= 0 && cronCommandEnd > cronCommandStart
  ? schedulerMigration.slice(cronCommandStart, cronCommandEnd)
  : "";
assert.ok(cronCommand.includes("vault.decrypted_secrets"),
  "Cron must resolve credentials from Vault at execution time");
assert.ok(!cronCommand.includes("v_service_key"),
  "Decrypted service-role key must never be interpolated into the persistent cron command");
assert.ok(!schedulerMigration.includes("PERFORM public.schedule_character_profile_organization_worker()"),
  "Migration must not activate the Worker schedule automatically");
assert.ok(schedulerMigration.includes("Intentionally no migration-time DO block"),
  "Worker scheduling must require explicit operator activation");
assert.ok(schedulerMigration.includes("p_enabled boolean DEFAULT false"),
  "Worker scheduling must be disabled unless explicitly enabled");
assert.ok(schedulerMigration.includes("IF p_enabled IS NOT TRUE"),
  "The explicit scheduler switch must support disabling and unscheduling");
assert.ok(schedulerMigration.includes("'* * * * *'"),
  "Worker cron should poll the queue every minute");
assert.ok(schedulerMigration.includes("vault_secrets_missing"),
  "Missing Vault secrets must fail closed without creating a schedule");
assert.ok(migration.includes("WHERE public.character_profile_organization_jobs.source_hash IS DISTINCT FROM EXCLUDED.source_hash"),
  "Unchanged source hashes must not reset an existing queue job");
assert.ok(migration.includes("reused_existing_job"),
  "Enqueue response must identify when an existing same-source job was reused");
assert.ok(migration.includes("lease_source_hash"),
  "The queue must fence an active Worker against its claimed source while coalescing newer saves");
assert.ok(migration.includes("v_terminal boolean") && migration.includes("provider_outcome_unknown"),
  "Ambiguous provider outcomes must become terminal instead of triggering automatic duplicate generations");
assert.ok(worker.includes("provider_request_timeout") && worker.includes("provider_outcome_unknown"),
  "Worker must classify timeout/network failures as ambiguous provider outcomes");
assert.ok(worker.includes("response.json();") && worker.includes("requestId: response.headers.get"),
  "Malformed provider responses must be treated as ambiguous outcomes with a traceable request ID");

console.log("Character AI Profile schema, queue, Worker, scheduling, save enqueue, Story integration and privacy contracts passed.");
