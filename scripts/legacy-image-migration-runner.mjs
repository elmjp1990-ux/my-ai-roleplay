import { createHash } from "node:crypto";

export function stableJson(value) {
  if (Array.isArray(value)) return value.map(stableJson);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, stableJson(value[key])]));
  }
  return value;
}

export function hashJson(value) {
  return createHash("sha256").update(JSON.stringify(stableJson(value))).digest("hex");
}

function checkpoint(manifest, persist) {
  manifest.updatedAt = new Date().toISOString();
  persist(structuredClone(manifest));
}

/**
 * Resumable migration coordinator. Adapter methods must be implemented with
 * atomic compare-and-set database RPCs; this module itself never guesses that
 * a partially completed write succeeded.
 */
export async function applyLegacyImageMigration({ manifest, adapter, persist = () => {} }) {
  if (!manifest || manifest.version !== 1 || manifest.status === "complete") {
    if (manifest?.status === "complete") return manifest;
    throw new Error("Unsupported or missing migration manifest");
  }
  if (!adapter || typeof adapter.ensureObject !== "function" ||
      typeof adapter.ensureMetadata !== "function" ||
      typeof adapter.getSession !== "function" ||
      typeof adapter.updateSnapshotIfUnchanged !== "function" ||
      typeof adapter.getCharacter !== "function" ||
      typeof adapter.clearCharacterAvatarIfUnchanged !== "function") {
    throw new TypeError("Migration adapter is incomplete");
  }

  manifest.status = "running";
  checkpoint(manifest, persist);

  for (const asset of manifest.assets) {
    const character = await adapter.getCharacter(asset.characterId);
    if (!character || character.author_id !== asset.authorId) {
      throw new Error(`Character ownership changed: ${asset.characterId}`);
    }
    let bytes = null;
    if (typeof character.avatar_url === "string" && character.avatar_url.startsWith("data:image/")) {
      const parsed = adapter.parseDataUri(character.avatar_url);
      if (!parsed || parsed.sha256 !== asset.sourceSha256 ||
          parsed.mimeType !== asset.mimeType || parsed.extension !== asset.extension) {
        throw new Error(`Character source image changed: ${asset.characterId}`);
      }
      bytes = parsed.bytes;
    }
    await adapter.ensureObject({ ...asset, bytes });
    await adapter.ensureMetadata(asset);
    asset.objectVerified = true;
    asset.metadataVerified = true;
    checkpoint(manifest, persist);
  }

  for (const item of [...manifest.currentSnapshots, ...manifest.historicalSnapshots]) {
    if (item.completed) continue;
    const current = await adapter.getSession(item.sessionId);
    if (!current || current.character_id !== item.characterId) {
      throw new Error(`Session ownership changed: ${item.sessionId}`);
    }
    const currentHash = hashJson(current.character_snapshot);
    if (currentHash === item.targetSnapshotHash) {
      item.completed = true;
      checkpoint(manifest, persist);
      continue;
    }
    if (currentHash !== item.expectedSnapshotHash) {
      throw new Error(`Snapshot changed since planning: ${item.sessionId}`);
    }
    const updated = await adapter.updateSnapshotIfUnchanged({
      sessionId: item.sessionId,
      characterId: item.characterId,
      expectedSnapshot: current.character_snapshot,
      nextSnapshot: item.targetSnapshot,
      expectedImageSha256: item.expectedImageSha256,
    });
    if (updated !== true) throw new Error(`Snapshot compare-and-set failed: ${item.sessionId}`);
    const verified = await adapter.getSession(item.sessionId);
    if (!verified || hashJson(verified.character_snapshot) !== item.targetSnapshotHash) {
      throw new Error(`Snapshot post-write verification failed: ${item.sessionId}`);
    }
    item.completed = true;
    checkpoint(manifest, persist);
  }

  for (const asset of manifest.assets) {
    if (asset.avatarCleared) continue;
    const character = await adapter.getCharacter(asset.characterId);
    if (!character || character.author_id !== asset.authorId) {
      throw new Error(`Character ownership changed before avatar clear: ${asset.characterId}`);
    }
    if (character.avatar_url == null || character.avatar_url === "") {
      asset.avatarCleared = true;
      checkpoint(manifest, persist);
      continue;
    }
    const parsed = adapter.parseDataUri(character.avatar_url);
    if (!parsed || parsed.sha256 !== asset.sourceSha256) {
      throw new Error(`Character avatar no longer matches migrated asset: ${asset.characterId}`);
    }
    const cleared = await adapter.clearCharacterAvatarIfUnchanged({
      characterId: asset.characterId,
      authorId: asset.authorId,
      expectedImageSha256: asset.sourceDataUriSha256,
    });
    if (cleared !== true) throw new Error(`Character avatar compare-and-set failed: ${asset.characterId}`);
    const verified = await adapter.getCharacter(asset.characterId);
    if (!verified || verified.avatar_url != null && verified.avatar_url !== "") {
      throw new Error(`Character avatar clear verification failed: ${asset.characterId}`);
    }
    asset.avatarCleared = true;
    checkpoint(manifest, persist);
  }

  manifest.status = "complete";
  checkpoint(manifest, persist);
  return manifest;
}

export function createResumableManifest(plan, parseDataUri) {
  const assets = plan.primaryAssets.map(asset => {
    const source = plan._sourceCharacters?.find(row => row.id === asset.characterId);
    if (!source || typeof source.avatar_url !== "string") {
      throw new Error("Manifest creation requires source character rows in memory");
    }
    return {
      ...asset,
      sourceDataUriSha256: createHash("sha256").update(source.avatar_url).digest("hex"),
      objectVerified: false,
      metadataVerified: false,
      avatarCleared: false,
    };
  });
  const toItem = item => ({
    sessionId: item.sessionId,
    characterId: item.characterId,
    expectedSnapshotHash: hashJson(item.expectedSnapshot),
    targetSnapshot: item.nextSnapshot,
    targetSnapshotHash: hashJson(item.nextSnapshot),
    expectedImageSha256: item.sourceSha256,
    completed: false,
  });
  // Validate the parser dependency at manifest creation time; image bytes are
  // deliberately not copied into the manifest.
  if (typeof parseDataUri !== "function") throw new TypeError("parseDataUri is required");
  return {
    version: 1,
    status: "pending",
    createdAt: new Date().toISOString(),
    counts: { ...plan.counts },
    assets,
    currentSnapshots: plan.currentSnapshots.map(toItem),
    historicalSnapshots: plan.historicalSnapshots.map(toItem),
  };
}
