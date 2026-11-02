import fs from "node:fs";
import assert from "node:assert/strict";
import { buildDisposableSchemaSql } from "./build-disposable-schema-fixture.mjs";

const base = "supabase/drafts/";
const structure = JSON.parse(fs.readFileSync(`${base}current-state-structure.json`, "utf8"));
const routines = JSON.parse(fs.readFileSync(`${base}current-state-routines.json`, "utf8"));
const security = JSON.parse(fs.readFileSync(`${base}current-state-security.json`, "utf8"));
const grants = JSON.parse(fs.readFileSync(`${base}current-state-effective-grants.json`, "utf8"));
const sql = buildDisposableSchemaSql(structure, routines, security, grants);

assert.match(sql, /GENERATED ALWAYS AS IDENTITY/);
assert.match(sql, /CREATE SEQUENCE IF NOT EXISTS "public"\."messages_sequence_order_seq" AS integer/);
assert.doesNotMatch(sql, /CREATE SEQUENCE IF NOT EXISTS "public"\."chat_turn_events_event_id_seq"/, "identity sequence must be created by its table definition");
assert.match(sql, /MAXVALUE 2147483647/);
assert.match(sql, /CREATE TABLE IF NOT EXISTS "public"\."characters"/);
assert.match(sql, /ALTER TABLE "public"\."characters" ADD CONSTRAINT/);
const chatMessagePk = sql.indexOf('ADD CONSTRAINT "chat_messages_pkey" PRIMARY KEY');
const assistantMessageFk = sql.indexOf('ADD CONSTRAINT "ai_generation_records_assistant_message_id_fkey" FOREIGN KEY');
assert.ok(chatMessagePk >= 0 && assistantMessageFk > chatMessagePk, "referenced primary keys must be created before foreign keys");
assert.match(sql, /CREATE OR REPLACE FUNCTION public\.account_is_active\(\)/);
assert.match(sql, /CREATE TRIGGER/);
assert.match(sql, /CREATE POLICY/);
assert.doesNotMatch(sql, /CREATE EXTENSION/, "the disposable harness uses PostgreSQL core and does not install platform extensions");
assert.doesNotMatch(sql, /CREATE EXTENSION/, "the disposable harness uses PostgreSQL core and does not install platform extensions");
assert.match(sql, /ALTER TABLE "public"\."characters" ENABLE ROW LEVEL SECURITY/);
assert.match(sql, /ALTER SCHEMA "private" OWNER TO/);
assert.match(sql, /GRANT EXECUTE ON FUNCTION/);
assert.match(sql, /ALTER DEFAULT PRIVILEGES/);
assert.match(sql, /SET check_function_bodies = off/);
assert.match(sql, /SET check_function_bodies = on/);
assert.equal((sql.match(/CREATE TABLE IF NOT EXISTS /g) ?? []).length, 47);
assert.ok(!sql.includes("COPY public."), "fixture must not contain row COPY data");
assert.ok(!sql.includes("\\copy"), "fixture must not contain psql data-copy commands");

console.log("Disposable schema SQL generation checks passed (not a PostgreSQL replay test).");
