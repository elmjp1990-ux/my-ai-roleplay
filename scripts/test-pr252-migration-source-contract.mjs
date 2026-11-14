import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const migrations = [
  {
    file: '20261114130000_add_bounded_character_comment_reads.sql',
    functionName: 'get_character_comments_safe_page',
    tests: ['scripts/test-public-comment-hydration-cache.mjs'],
  },
  {
    file: '20261114180000_group_ai_single_orchestrator.sql',
    functionName: 'reserve_group_chat_turn',
    tests: ['supabase/tests/group-chat-transaction-scenarios.sql', 'scripts/test-group-chat-migration-rollback.sh'],
  },
  {
    file: '20261114200000_batch_character_story_and_encounter_schedule_reads.sql',
    functionName: 'get_encounter_character_schedules',
    tests: ['scripts/test-runtime-egress-optimizations.mjs', 'scripts/test-encounter-schedule-parser.mjs'],
  },
  {
    file: '20261114230000_batch_group_list_previews.sql',
    functionName: 'get_my_group_list_previews',
    tests: ['supabase/tests/group-chat-list-preview-scenarios.sql'],
  },
  {
    file: '20261115090000_batch_followed_author_latest_characters.sql',
    functionName: 'get_public_author_latest_characters',
    tests: ['supabase/tests/followed-author-latest-character-scenarios.sql'],
  },
];

const migrationDir = path.join('supabase', 'migrations');
const draftDir = path.join('supabase', 'drafts');
const versions = new Set();
for (const entry of migrations) {
  const migrationPath = path.join(migrationDir, entry.file);
  assert.ok(fs.existsSync(migrationPath), 'Missing versioned migration source: ' + entry.file);
  const version = entry.file.slice(0, 14);
  assert.match(version, /^\d{14}$/, 'Migration must have a 14-digit version prefix: ' + entry.file);
  assert.ok(!versions.has(version), 'Duplicate version in this PR migration set: ' + version);
  versions.add(version);

  const source = fs.readFileSync(migrationPath, 'utf8');
  assert.match(source, new RegExp('CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+public\\.' + entry.functionName, 'i'),
    'Migration must define its expected RPC: ' + entry.functionName);
  assert.ok(!fs.existsSync(path.join(draftDir, entry.file)),
    'A draft file must not shadow the versioned migration: ' + entry.file);
  for (const testFile of entry.tests) {
    assert.ok(fs.existsSync(testFile), 'Missing regression evidence for ' + entry.file + ': ' + testFile);
  }
}

const ordered = migrations.map(entry => entry.file).slice().sort();
assert.deepEqual(migrations.map(entry => entry.file), ordered,
  'PR migration files must remain in chronological filename order');

console.log('PR #252 migration source map passed. This checks repository provenance only; it does not inspect the hosted migration ledger or apply SQL.');
