import test from "node:test";
import assert from "node:assert/strict";
import { buildMigrationPlan, buildMigrationReadQueries, parseImageDataUri } from "./migrate-legacy-chat-images.mjs";
import { applyLegacyImageMigration, createResumableManifest, hashJson } from "./legacy-image-migration-runner.mjs";
import { assertLocalSupabaseUrl, createLocalSupabaseAdapter } from "./apply-legacy-chat-image-migration-local.mjs";
import { readFileSync } from "node:fs";

const uuid = n => `00000000-0000-4000-8000-${String(n).padStart(12,"0")}`;
const data = (text, mime="image/png") => `data:${mime};base64,${Buffer.from(text).toString("base64")}`;

function fixture() {
  const characters = Array.from({length:8},(_,i)=>({
    id:uuid(i+1),author_id:uuid(100+i),avatar_url:data("current-"+i),
  }));
  const sessions=[];
  let id=1;
  for(let i=0;i<8;i++) {
    const count=i<6?9:10;
    for(let j=0;j<count;j++) sessions.push({
      id:uuid(1000+id++),character_id:characters[i].id,
      character_snapshot:{id:characters[i].id,name:"Role "+i,image:characters[i].avatar_url,opening:"Keep me"},
    });
  }
  // 74 exact current snapshots above; 13 distinct historical image versions.
  for(let i=0;i<13;i++) sessions.push({
    id:uuid(2000+i),character_id:characters[i%8].id,
    character_snapshot:{id:characters[i%8].id,name:"Role",image:data("historical-"+i),opening:"Preserve text"},
  });
  return {characters,sessions};
}

test("source reads are scoped to legacy-avatar characters and only their chat sessions", () => {
  const queries = buildMigrationReadQueries([uuid(8), uuid(1), uuid(8)]);
  assert.deepEqual(queries.characters, {
    select: "id,author_id,avatar_url",
    filters: { avatar_url: "ilike.data:image/*" },
  });
  assert.deepEqual(queries.sessions, {
    select: "id,character_id,character_snapshot",
    filters: { character_id: `in.(${uuid(1)},${uuid(8)})`, deleted_at: "is.null" },
  });
  assert.equal(buildMigrationReadQueries([]).sessions, null);
  assert.throws(() => buildMigrationReadQueries(["not-a-uuid"]), /Invalid character UUID/);
});

test("single-row verification reads select only the required columns", async () => {
  const requested = [];
  const adapter = createLocalSupabaseAdapter({
    url: "http://127.0.0.1:54321",
    serviceRoleKey: "local-test-key",
    fetchImpl: async input => {
      requested.push(new URL(input).searchParams);
      return new Response(JSON.stringify([{ id: uuid(1) }]), {
        status: 200, headers: { "Content-Type": "application/json" },
      });
    },
  });
  await adapter.getCharacter(uuid(1));
  await adapter.getSession(uuid(2));
  assert.equal(requested[0].get("select"), "id,author_id,avatar_url");
  assert.equal(requested[1].get("select"), "id,character_id,character_snapshot");
  assert.equal(requested.every(query => query.get("limit") === "2"), true);
});

test("parses supported image data URIs and rejects malformed payloads",()=>{
  assert.equal(parseImageDataUri(data("x","image/jpeg")).extension,"jpg");
  assert.equal(parseImageDataUri(data("x","image/webp")).mimeType,"image/webp");
  assert.equal(parseImageDataUri("data:image/gif;base64,AAAA"),null);
  assert.equal(parseImageDataUri("data:image/png;base64,%%%"),null);
});

test("plans 8 primary images, 74 current snapshots, and preserves 13 historical images",()=>{
  const plan=buildMigrationPlan(fixture());
  assert.deepEqual(plan.counts,{
    primaryImages:8,currentSnapshots:74,historicalSnapshots:13,historicalAssets:13,totalSnapshotUpdates:87,
    estimatedImageBytes:plan.counts.estimatedImageBytes,
  });
  assert.equal(plan.primaryAssets.every(x=>x.assetType==="primary"&&x.sortOrder===0),true);
  assert.equal(plan.currentSnapshots.every(x=>x.nextSnapshot.image===""&&x.nextSnapshot.imagePath===x.storagePath),true);
  assert.equal(plan.historicalSnapshots.every(x=>x.nextSnapshot.image===""&&typeof x.nextSnapshot.imagePath==="string"),true);
  assert.equal(plan.historicalAssets.length,13);
  assert.equal(plan.currentSnapshots.every(x=>x.nextSnapshot.opening==="Keep me"),true);
  assert.equal(plan.historicalSnapshots.every(x=>x.nextSnapshot.opening==="Preserve text"),true);
  assert.equal(plan.safety.databaseWrites,false);
  assert.equal(plan.safety.storageWrites,false);
  assert.equal(plan.safety.historicalImagesPreserved,true);
});

test("classifies identical image bytes by the owning session character", () => {
  const shared = data("same-image-bytes");
  const characters = [
    { id: uuid(1), author_id: uuid(101), avatar_url: shared },
    { id: uuid(2), author_id: uuid(102), avatar_url: shared },
  ];
  const sessions = characters.map((character, index) => ({
    id: uuid(3000 + index),
    character_id: character.id,
    character_snapshot: { id: character.id, image: shared },
  }));
  const plan = buildMigrationPlan({ characters, sessions, strictCounts: false });
  assert.deepEqual(plan.currentSnapshots.map(row => row.characterId).sort(), [uuid(1), uuid(2)]);
  assert.equal(plan.historicalSnapshots.length, 0);
});

test("is deterministic and safe to rerun",()=>{
  const input=fixture();
  const first=buildMigrationPlan(input);
  const second=buildMigrationPlan(input);
  assert.deepEqual(first.primaryAssets.map(x=>x.storagePath),second.primaryAssets.map(x=>x.storagePath));
});

test("fails closed on count drift and mismatched current snapshot ownership",()=>{
  const input=fixture();
  assert.throws(()=>buildMigrationPlan({...input,sessions:input.sessions.slice(0,-1)}),/Inventory drift/);
  const bad=fixture();
  bad.sessions[0].character_id=uuid(999);
  assert.throws(()=>buildMigrationPlan(bad),/but session.character_id/);
});

test("fails closed on unsupported historical image formats",()=>{
  const input=fixture();
  input.sessions.at(-1).character_snapshot.image="data:image/gif;base64,AAAA";
  assert.throws(()=>buildMigrationPlan(input),/Unsupported or malformed/);
});


test("resumable runner recovers after interruption without duplicate objects or metadata", async () => {
  const input = fixture();
  const plan = buildMigrationPlan(input);
  const manifest = createResumableManifest(plan, input.characters);
  assert.equal(JSON.stringify(manifest).includes("data:image/"), false);

  const characters = new Map(input.characters.map(row => [row.id, structuredClone(row)]));
  const sessions = new Map(input.sessions.map(row => [row.id, structuredClone(row)]));
  const objects = new Map();
  const metadata = new Map();
  let uploadCount = 0;
  let metadataInsertCount = 0;
  let snapshotWrites = 0;
  let interrupt = true;
  const adapter = {
    parseDataUri: parseImageDataUri,
    async getCharacter(id) { return structuredClone(characters.get(id)); },
    async getSession(id) { return structuredClone(sessions.get(id)); },
    async ensureObject(asset) {
      const existing = objects.get(asset.storagePath);
      if (existing) {
        assert.equal(existing.sha256, asset.sourceSha256);
        return;
      }
      assert.ok(asset.bytes, "source bytes must be available before the avatar is cleared");
      assert.equal(parseImageDataUri(data("unused")).extension, "png");
      const sha256 = (await import("node:crypto")).createHash("sha256").update(asset.bytes).digest("hex");
      assert.equal(sha256, asset.sourceSha256);
      objects.set(asset.storagePath, { sha256, bytes: Buffer.from(asset.bytes) });
      uploadCount++;
    },
    async ensureMetadata(asset) {
      const existing = metadata.get(asset.storagePath);
      if (existing) {
        assert.equal(existing.character_id, asset.characterId);
        assert.equal(existing.author_id, asset.authorId);
        assert.equal(existing.asset_type, "primary");
        return;
      }
      metadata.set(asset.storagePath, {
        character_id: asset.characterId, author_id: asset.authorId,
        storage_path: asset.storagePath, asset_type: "primary", sort_order: 0,
      });
      metadataInsertCount++;
    },
    async updateSnapshotIfUnchanged({ sessionId, characterId, expectedSnapshot, nextSnapshot }) {
      const row = sessions.get(sessionId);
      if (!row || row.character_id !== characterId || hashJson(row.character_snapshot) !== hashJson(expectedSnapshot)) return false;
      row.character_snapshot = structuredClone(nextSnapshot);
      snapshotWrites++;
      if (interrupt && snapshotWrites === 4) {
        interrupt = false;
        throw new Error("simulated process interruption");
      }
      return true;
    },
    async clearCharacterAvatarIfUnchanged({ characterId, authorId, expectedImageSha256 }) {
      const row = characters.get(characterId);
      if (!row || row.author_id !== authorId || (await import("node:crypto")).createHash("sha256").update(row.avatar_url).digest("hex") !== expectedImageSha256) return false;
      row.avatar_url = null;
      return true;
    },
  };

  const checkpoints = [];
  await assert.rejects(
    applyLegacyImageMigration({ manifest, adapter, persist: state => checkpoints.push(state) }),
    /simulated process interruption/,
  );
  assert.equal(manifest.status, "running");
  assert.equal(manifest.currentSnapshots.filter(x => x.completed).length, 3);
  await applyLegacyImageMigration({ manifest, adapter, persist: state => checkpoints.push(state) });

  assert.equal(manifest.status, "complete");
  assert.equal(uploadCount, 21);
  assert.equal(metadataInsertCount, 8);
  assert.equal(snapshotWrites, 87);
  assert.equal([...characters.values()].every(x => x.avatar_url == null), true);
  assert.equal([...sessions.values()].filter(x => x.character_snapshot.imagePath).length, 87);
  assert.equal([...sessions.values()].filter(x => x.character_snapshot.image === "").length, 87);
  assert.equal(metadata.size, 8);
  assert.equal(manifest.historicalAssets.filter(x => x.objectVerified).length, 13);
  assert.ok(checkpoints.length > 90);

  const before = { uploadCount, metadataInsertCount, snapshotWrites };
  await applyLegacyImageMigration({ manifest, adapter });
  assert.deepEqual({ uploadCount, metadataInsertCount, snapshotWrites }, before);
});


test("rejects corrupted or edited resume manifests before any adapter operation", async () => {
  const input = fixture();
  const plan = buildMigrationPlan(input);
  const makeManifest = () => createResumableManifest(plan, input.characters);

  const badCounts = makeManifest();
  badCounts.counts.currentSnapshots = 73;
  await assert.rejects(applyLegacyImageMigration({ manifest: badCounts }), /currentSnapshots must be 74/);

  const falseComplete = makeManifest();
  falseComplete.status = "complete";
  await assert.rejects(applyLegacyImageMigration({ manifest: falseComplete }), /complete status requires every migration step/);

  const badPath = makeManifest();
  badPath.currentSnapshots[0].targetSnapshot.imagePath = "other-user/other-character/unsafe.png";
  badPath.currentSnapshots[0].targetSnapshotHash = hashJson(badPath.currentSnapshots[0].targetSnapshot);
  await assert.rejects(applyLegacyImageMigration({ manifest: badPath }), /does not match its primary asset/);

  const badHash = makeManifest();
  badHash.historicalSnapshots[0].targetSnapshot.opening = "changed";
  await assert.rejects(applyLegacyImageMigration({ manifest: badHash }), /malformed or duplicate historical snapshot/);

  const embeddedData = makeManifest();
  embeddedData.historicalSnapshots[0].targetSnapshot.privateImage = data("should-not-be-in-manifest");
  await assert.rejects(applyLegacyImageMigration({ manifest: embeddedData }), /embedded image data/);
});


test("apply target is restricted to loopback Supabase on port 54321", () => {
  assert.doesNotThrow(() => assertLocalSupabaseUrl("http://127.0.0.1:54321"));
  assert.doesNotThrow(() => assertLocalSupabaseUrl("http://localhost:54321"));
  assert.throws(() => assertLocalSupabaseUrl("https://ouyewoagbmtqehbofrje.supabase.co"), /restricted to/);
  assert.throws(() => assertLocalSupabaseUrl("http://127.0.0.1:54322"), /restricted to/);
  assert.throws(() => assertLocalSupabaseUrl("http://localhost.evil.example:54321"), /restricted to/);
});

test("historical image Storage reads are restricted to the exact owned chat snapshot path", () => {
  const migration = readFileSync(new URL("../supabase/migrations/20261113060000_allow_chat_snapshot_image_storage_reads.sql", import.meta.url), "utf8");
  assert.match(migration, /s\.user_id = auth\.uid\(\)/);
  assert.match(migration, /s\.deleted_at IS NULL/);
  assert.match(migration, /s\.character_snapshot->>'imagePath' = p_object_name/);
  assert.match(migration, /split_part\(p_object_name, '\/', 1\) = c\.author_id::text/);
  assert.match(migration, /split_part\(p_object_name, '\/', 2\) = s\.character_id::text/);
  assert.ok(migration.includes("[.](jpg|jpeg|png|webp)$"));
  assert.equal((migration.match(/\$function\$/g) || []).length, 2);
  assert.equal((migration.match(/COMMENT ON FUNCTION/g) || []).length, 1);
  assert.doesNotMatch(migration, /TO anon|TO public|FOR INSERT|FOR UPDATE|FOR DELETE/i);
});
