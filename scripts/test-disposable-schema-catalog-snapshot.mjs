import fs from "node:fs";
import assert from "node:assert/strict";

const base = "supabase/drafts/";
const structure = JSON.parse(fs.readFileSync(`${base}current-state-structure.json`, "utf8"));
const routines = JSON.parse(fs.readFileSync(`${base}current-state-routines.json`, "utf8"));
const security = JSON.parse(fs.readFileSync(`${base}current-state-security.json`, "utf8"));
const grants = JSON.parse(fs.readFileSync(`${base}current-state-effective-grants.json`, "utf8"));
const manifest = fs.readFileSync(`${base}current-state-schema-catalog-manifest-2026-11-02.md`, "utf8");

assert.equal(structure.capture.purpose, "current-state schema-only disposable fixture; not historical migration provenance");
assert.deepEqual(structure.capture.scope, ["public", "private"]);
assert.equal(structure.relations.filter((r) => r.schema === "public" && r.kind === "r").length, 47);
assert.equal(structure.relations.filter((r) => r.schema === "public" && r.kind === "v").length, 1);
assert.equal(structure.relations.filter((r) => r.schema === "public" && r.kind === "S").length, 2);
assert.equal(structure.columns.length, 416);
assert.equal(structure.constraints.length, 288);
assert.equal(structure.indexes.length, 140);
assert.equal(structure.views.length, 1);
assert.equal(structure.sequences.length, 2);
assert.ok(structure.sequences.every((s) => typeof s.start === "string" && typeof s.max === "string"));
assert.ok(structure.sequences.some((s) => s.owned_by?.dependency_type === "i"), "Identity-owned sequences must be distinguished from serial sequences");
assert.equal(structure.extensions.length, 7);
assert.equal(routines.routines.length, 77);
assert.ok(routines.routines.every((r) => typeof r.definition === "string" && r.definition.startsWith("CREATE OR REPLACE")));
assert.equal(security.policies.length, 95);
assert.equal(security.triggers.length, 23);
assert.equal(security.relation_privileges.length, 937);
assert.equal(security.column_acl.length, 17);
assert.equal(security.sequence_privileges.length, 18);
assert.equal(grants.table_privileges.length, 810);
assert.equal(grants.column_privileges.length, 4147);
assert.equal(grants.routine_privileges.length, 194);
assert.equal(security.schema_privileges.length, 2);
assert.equal(security.default_privileges.length, 6);
assert.ok(structure.relations.filter((r) => r.schema === "public" && r.kind === "r").every((r) => r.rls_enabled === true));
assert.ok(manifest.includes("DISPOSABLE ONLY"));
assert.ok(manifest.includes("No application table rows"));
assert.match(manifest, /not a historical migration/i);

assert.ok(routines.routines.every((r) => Array.isArray(r.privileges)));

for (const snapshot of [structure, routines, security, grants]) {
  for (const forbidden of ["application_rows", "chat_transcripts", "wallet_balances", "storage_objects"]) {
    assert.equal(Object.hasOwn(snapshot, forbidden), false, `Snapshot must not contain ${forbidden}`);
  }
}

console.log("Disposable schema catalog snapshot integrity passed (schema-only metadata; not a PostgreSQL replay test).");
