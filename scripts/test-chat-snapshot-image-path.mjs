import assert from 'node:assert/strict';
import fs from 'node:fs';

const story = fs.readFileSync('supabase/functions/story-session/index.ts','utf8');
const encounter = fs.readFileSync('supabase/functions/encounter-session/index.ts','utf8');
const html = fs.readFileSync('index.html','utf8');

for (const [name,source] of [['story',story],['encounter',encounter]]) {
  assert.match(source,/from\("character_illustrations"\)/,name+' must look up primary Storage metadata');
  assert.match(source,/\.eq\("asset_type", "primary"\)/,name+' must use the primary asset');
  assert.match(source,/image: primaryIllustration\?\.storage_path \? "" : \(character\.avatar_url \|\| ""\)/,name+' must preserve legacy fallback while avoiding embedded images when Storage exists');
  assert.match(source,/imagePath: primaryIllustration\?\.storage_path \|\| ""/,name+' must persist stable path metadata');
}
assert.match(html,/async function hydrateCloudSessionCharacterImage\(s\)/);
assert.match(html,/getCharacterIllustrationSignedUrl\(path,\{forceRefresh:!!cached\}\)/);
assert.match(html,/cloudSessionImageUrlCache\.set\(key,\{url,expiresAt:Date\.now\(\)\+55\*60\*1000\}\)/);
assert.match(html,/forceRefresh:!!cached/);
assert.match(html,/data-character-illustration-path=.*c\.imagePath/);
assert.match(html,/priorSnapshot\.imagePath \? '' : \(character\?\.image \|\| priorSnapshot\.image \|\| ''\)/);
assert.match(html,/hydrateCloudSessionCharacterImage\(session\)/);
assert.match(html,/hydrateCloudSessionCharacterImage\(s\)/);
assert.match(html,/portraitPath&&uid&&s\.id/);
console.log('Chat snapshot image-path contract passed.');

const groupCreationMigration = fs.readFileSync(
  'supabase/migrations/20261116170000_preserve_group_character_avatar_snapshots.sql',
  'utf8',
);
assert.match(groupCreationMigration,/imagePath', COALESCE\(v_primary_illustration_path, ''\)/,
  'new group member snapshots must keep the primary illustration Storage path');
assert.match(groupCreationMigration,/image', CASE WHEN v_primary_illustration_path IS NOT NULL THEN '' ELSE COALESCE\(v_character\.avatar_url, ''\) END/,
  'new group member snapshots must keep the avatar URL when no primary illustration exists');
assert.match(groupCreationMigration,/c\.deleted_at IS NULL/,
  'the group creation eligibility check must continue rejecting soft-deleted characters');
assert.match(html,/async function signCharacterSnapshotPortraits\(members\)/,
  'group chats must be able to sign stable portrait paths from member snapshots');
assert.match(html,/characterIllustrationSignedUrlManager\.getMany\(unique\.map\(entry=>entry\.path\)\)/,
  'group snapshot portrait paths should be signed in a single batch');
assert.match(html,/snapshot\.imagePath\|\|snapshot\.primaryIllustrationPath/,
  'group list and group-open hydration must read the snapshotted image path');

const retainedPortraitPolicy = fs.readFileSync(
  'supabase/migrations/20261116171000_allow_existing_chat_portrait_access.sql',
  'utf8',
);
assert.match(retainedPortraitPolicy,/cs\.user_id = \(SELECT auth\.uid\(\)\)/,
  'single-chat portrait access must be scoped to the authenticated chat owner');
assert.match(retainedPortraitPolicy,/cs\.deleted_at IS NULL/,
  'deleted single-chat sessions must not retain Storage access');
assert.match(retainedPortraitPolicy,/cs\.character_snapshot->>'imagePath' = objects\.name/,
  'single-chat access must be limited to the exact path in its trusted snapshot');
assert.match(retainedPortraitPolicy,/g\.owner_id = \(SELECT auth\.uid\(\)\)/,
  'group portrait access must be scoped to the authenticated group owner');
assert.match(retainedPortraitPolicy,/g\.deleted_at IS NULL/,
  'deleted groups must not retain Storage access');
assert.match(retainedPortraitPolicy,/gm\.character_snapshot->>'imagePath' = objects\.name/,
  'group access must be limited to the exact path in its member snapshot');
assert.match(retainedPortraitPolicy,/public\.account_is_active\(\)/,
  'existing-chat portrait reads must require an active authenticated account');
