import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration = fs.readFileSync('supabase/migrations/20261117150503_encounter_public_character_schedule_eligibility.sql', 'utf8');
const existingReadRpc = fs.readFileSync('supabase/migrations/20261114200000_batch_character_story_and_encounter_schedule_reads.sql', 'utf8');

const enqueue = migration.split('CREATE OR REPLACE FUNCTION public.enqueue_encounter_schedule_generation_test_batch(')[1]?.split('\n$$;')[0] || '';
const publishScenes = migration.split('CREATE OR REPLACE FUNCTION public.publish_encounter_scene_metadata(')[1]?.split('\n$$;')[0] || '';
const usage = migration.split('CREATE OR REPLACE FUNCTION public.get_encounter_dynamic_scene_usage(')[1]?.split('\n$$;')[0] || '';
const catalog = migration.split('CREATE OR REPLACE FUNCTION public.get_encounter_scene_catalog(')[1]?.split('\n$$;')[0] || '';

assert.ok(enqueue, 'Public-character enqueue function must be replaced.');
assert.doesNotMatch(enqueue, /is_nsfw|modern_setting_compatible|time_travel_explicit|古代|奇幻/,
  'All approved public characters must be eligible regardless of NSFW rating or setting era.');
assert.doesNotMatch(publishScenes, /is_nsfw/,
  'Scene metadata generation must count all public characters, including NSFW characters.');
assert.doesNotMatch(usage, /is_nsfw/,
  'Dynamic scene usage must include all public characters, including NSFW characters.');
assert.match(catalog, /auth\.role\(\) = 'service_role' OR \(auth\.uid\(\) IS NOT NULL AND private\.current_user_is_adult\(\)\)/,
  'Internal schedule generation can see all roles; public viewers still need verified adult status for NSFW roles.');
assert.match(existingReadRpc, /private\.current_user_is_adult\(\)/,
  'The public scene roster must continue to enforce the existing server-side adult gate.');
assert.match(existingReadRpc, /c\.visibility = 'public'[\s\S]*?c\.is_nsfw IS NOT TRUE[\s\S]*?private\.current_user_is_adult\(\)/,
  'NSFW character schedule reads must remain age-gated at the database RPC.');

console.log('Encounter public-character eligibility and age-gated visibility contracts passed.');
