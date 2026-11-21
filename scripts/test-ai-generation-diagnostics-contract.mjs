import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const read = (file) => fs.readFileSync(path.join(process.cwd(), file), "utf8");
const helper = read("supabase/functions/_shared/ai-generation-diagnostics.ts");
const migration = read("supabase/migrations/20261121120000_ai_generation_diagnostics_14_day_retention.sql");

assert.match(helper, /raw_output_text:\s*input\.rawOutputText/);
assert.match(helper, /raw_response_body:\s*input\.rawResponseBody/);
assert.match(helper, /refusal_text:\s*input\.refusalText/);
assert.match(helper, /never change generation,[\s\S]*billing/);
assert.match(migration, /raw_response_body text/);
assert.match(migration, /interval '14 days'/);
assert.match(migration, /ENABLE ROW LEVEL SECURITY/);
assert.match(migration, /REVOKE ALL ON TABLE public\.ai_generation_diagnostics FROM PUBLIC, anon, authenticated/);
assert.match(migration, /poyozz-ai-generation-diagnostics-purge/);
assert.match(migration, /encounter_schedule_generation_output_revisions/);
assert.match(migration, /encounter_schedule_generation_outputs/);

const callSites = [
  ["supabase/functions/chat-turn/index.ts", "story_chat"],
  ["supabase/functions/group-chat-turn/index.ts", "group_chat"],
  ["supabase/functions/encounter-turn/index.ts", "encounter_chat"],
  ["supabase/functions/_shared/story-memory-summary.ts", "memory_summary"],
  ["supabase/functions/character-profile-organization-worker/index.ts", "character_profile"],
  ["supabase/functions/encounter-schedule-organizer/index.ts", "encounter_schedule"],
  ["supabase/functions/encounter-evaluation-worker/index.ts", "encounter_evaluation"],
];
for (const [file, generationType] of callSites) {
  const source = read(file);
  assert.match(source, /recordAiGenerationDiagnostic/, file + " must persist every provider output");
  assert.ok(source.includes('"'+generationType+'"'), file + " must identify " + generationType);
}
console.log("AI generation diagnostics coverage and 14-day retention contract passed.");
