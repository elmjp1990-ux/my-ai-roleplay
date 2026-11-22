import assert from "node:assert/strict";
import fs from "node:fs";

const route = fs.readFileSync("api/encounter-schedule-organizer.ts", "utf8");
const handler = fs.readFileSync("supabase/functions/_shared/encounter-schedule-organizer-handler.ts", "utf8");
const edgeEntry = fs.readFileSync("supabase/functions/encounter-schedule-organizer/index.ts", "utf8");
const html = fs.readFileSync("index.html", "utf8");
const vercel = JSON.parse(fs.readFileSync("vercel.json", "utf8"));
const packageJson = JSON.parse(fs.readFileSync("package.json", "utf8"));
const tsconfig = JSON.parse(fs.readFileSync("tsconfig.json", "utf8"));
const apiPackageJson = JSON.parse(fs.readFileSync("api/package.json", "utf8"));

assert.match(route, /handleEncounterScheduleOrganizer/);
assert.match(route, /from "\.\.\/supabase\/functions\/_shared\/encounter-schedule-organizer-handler\.ts";/, "Vercel ESM route must explicitly import the TypeScript handler so its dependency is bundled");
assert.equal(apiPackageJson.type, "module", "API route scope must be ESM for the TypeScript handler import");
assert.match(route, /270_000/);
assert.match(route, /setInterval\(\(\) =>/);
assert.match(route, /res\.write\(" "\)/);
assert.match(route, /body\.mode !== "manual"/);
assert.match(route, /VERCEL_ENV === "production"/);
assert.match(route, /runtimeProcess\.env\[name\]/);
assert.match(route, /runtimeProcess\.env\.VERCEL_ENV/);
assert.equal(tsconfig.compilerOptions.allowImportingTsExtensions, true);
assert.equal(tsconfig.compilerOptions.noEmit, true);
assert.ok(tsconfig.include.includes("api/encounter-schedule-organizer.ts"));
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
assert.match(html, /Number\(data\?\.http_status\)>=400/);
assert.doesNotMatch(
  html,
  /functions\.invoke\('encounter-schedule-organizer',\{body:\{mode:'manual'\}\}/,
  "Manual schedule generation must not call the 150s Supabase Edge Function directly",
);

console.log("Vercel 300s Encounter schedule route, ESM TypeScript shared-handler bundling, auth forwarding, and timeout isolation contracts passed.");
