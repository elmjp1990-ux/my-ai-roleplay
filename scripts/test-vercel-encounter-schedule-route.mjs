import assert from "node:assert/strict";
import fs from "node:fs";

const route = fs.readFileSync("api/encounter-schedule-organizer.ts", "utf8");
const handler = fs.readFileSync("supabase/functions/_shared/encounter-schedule-organizer-handler.ts", "utf8");
const edgeEntry = fs.readFileSync("supabase/functions/encounter-schedule-organizer/index.ts", "utf8");
const html = fs.readFileSync("index.html", "utf8");
const vercel = JSON.parse(fs.readFileSync("vercel.json", "utf8"));
const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));

assert.match(route, /handleEncounterScheduleOrganizer/);
assert.match(route, /270_000/);
assert.match(route, /body\.mode !== "manual"/);
assert.match(route, /VERCEL_ENV === "production"/);
assert.match(route, /process\.env\[name\]/);
assert.doesNotMatch(route, /Deno\./);
assert.match(handler, /export async function handleEncounterScheduleOrganizer/);
assert.match(handler, /providerTimeoutMs = 100_000/);
assert.match(handler, /Math\.min\(\s*270_000/);
assert.doesNotMatch(handler, /Deno\./);
assert.match(edgeEntry, /handleEncounterScheduleOrganizer\(request, Deno\.env, createClient, 100_000\)/);
assert.equal(vercel.functions?.["api/encounter-schedule-organizer.ts"]?.maxDuration, 300);
assert.equal(packageJson.dependencies?.["@supabase/supabase-js"], "2.119.2");
assert.match(html, /window\.mySupabase\.auth\.getSession\(\)/);
assert.match(html, /fetch\('\/api\/encounter-schedule-organizer'/);
assert.doesNotMatch(
  html,
  /functions\.invoke\('encounter-schedule-organizer',\{body:\{mode:'manual'\}\}/,
  "Manual schedule generation must not call the 150s Supabase Edge Function directly",
);

console.log("Vercel 300s Encounter schedule route, shared runtime handler, auth forwarding, and timeout isolation contracts passed.");
