import assert from 'node:assert/strict';
import fs from 'node:fs';

const path = 'supabase/migrations/20261113050000_allow_existing_chat_character_media_read.sql';
const sql = fs.readFileSync(path, 'utf8');
const executableSql = sql.replace(/--.*$/gm, '');

assert.match(executableSql, /CREATE OR REPLACE FUNCTION private\.user_has_existing_character_session\(\s*p_character_id uuid\s*\)/);
assert.match(executableSql, /public\.account_is_active\(\) IS TRUE/);
assert.match(executableSql, /s\.character_id = p_character_id[\s\S]*s\.user_id = auth\.uid\(\)[\s\S]*s\.deleted_at IS NULL/);
assert.match(executableSql, /gm\.character_id = p_character_id[\s\S]*g\.owner_id = auth\.uid\(\)[\s\S]*g\.deleted_at IS NULL/);
assert.match(executableSql, /CREATE OR REPLACE FUNCTION private\.can_read_character_asset/);
assert.match(executableSql, /WHEN 'character-illustrations' THEN EXISTS/);
assert.match(executableSql, /ci\.storage_path = p_object_name/);
assert.match(executableSql, /private\.user_has_existing_character_session\(ci\.character_id\)/);
assert.match(executableSql, /CREATE POLICY "Existing session owners can read character illustration metadata"/);
assert.match(executableSql, /CREATE POLICY "Existing session owners can read archived character assets"/);
assert.match(executableSql, /bucket_id = 'character-illustrations'[\s\S]*private\.can_read_character_asset\(bucket_id, name\)/);

// The change is read-only authorization for an exact referenced asset path.
// It must not add write policies, loosen public/anon access, or alter chat data.
assert.doesNotMatch(executableSql, /TO\s+(?:anon|PUBLIC)\s+USING/i);
assert.doesNotMatch(executableSql, /FOR\s+(?:INSERT|UPDATE|DELETE)/i);
assert.doesNotMatch(executableSql, /CREATE POLICY[\s\S]*FOR\s+ALL/i);
assert.doesNotMatch(executableSql, /UPDATE\s+public\./i);
assert.doesNotMatch(executableSql, /DELETE\s+FROM\s+public\./i);
assert.doesNotMatch(executableSql, /TRUNCATE\s/i);
assert.doesNotMatch(executableSql, /DROP\s+TABLE/i);

console.log('Existing-chat character media read policy contract passed.');
