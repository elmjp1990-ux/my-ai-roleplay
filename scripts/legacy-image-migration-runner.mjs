import { createHash } from "node:crypto";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256 = /^[0-9a-f]{64}$/;
const EXPECTED_COUNTS = Object.freeze({
  primaryImages: 8,
  currentSnapshots: 74,
  historicalSnapshots: 13,
  totalSnapshotUpdates: 87,
});

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

function assertPlainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Invalid migration manifest: ${label} must be an object`);
  }
}

function containsEmbeddedImageData(value) {
  if (typeof value === "string") return /^data:image\//i.test(value);
  if (Array.isArray(value)) return value.some(containsEmbeddedImageData);
  if (value && typeof value === "object") return Object.values(value).some(containsEmbeddedImageData);
  return false;
}

/**
 * Validate persisted resume state before it can drive any local database or
 * Storage operation. The manifest is user-editable JSON, so never trust it.
 */
export function validateMigrationManifest(manifest) {
  assertPlainObject(manifest, "root");
  if (manifest.version !== 1 || !["pending", "running", "complete"].includes(manifest.status)) {
    throw new Error("Invalid migration manifest: unsupported version or status");
  }
  if (containsEmbeddedImageData(manifest)) {
    throw new Error("Invalid migration manifest: embedded image data is not allowed");
  }
  assertPlainObject(manifest.counts, "counts");
  for (const [key, expected] of Object.entries(EXPECTED_COUNTS)) {
    if (manifest.counts[key] !== expected) {
      throw new Error(`Invalid migration manifest: ${key} must be ${expected}`);
    }
  }
  if (!Number.isSafeInteger(manifest.counts.historicalAssets) || manifest.counts.historicalAssets < 1 ||
      !Array.isArray(manifest.historicalAssets) || manifest.historicalAssets.length !== manifest.counts.historicalAssets ||
      !Array.isArray(manifest.assets) || manifest.assets.length !== EXPECTED_COUNTS.primaryImages ||
      !Array.isArray(manifest.currentSnapshots) || manifest.currentSnapshots.length !== EXPECTED_COUNTS.currentSnapshots ||
      !Array.isArray(manifest.historicalSnapshots) || manifest.historicalSnapshots.length !== EXPECTED_COUNTS.historicalSnapshots) {
    throw new Error("Invalid migration manifest: item counts do not match the approved 8/74/13 inventory and historical asset inventory");
  }

  const assetsByCharacter = new Map();
  const storagePaths = new Set();
  for (const asset of manifest.assets) {
    assertPlainObject(asset, "asset");
    if (!UUID.test(asset.characterId || "") || !UUID.test(asset.authorId || "") ||
        !SHA256.test(asset.sourceSha256 || "") || !SHA256.test(asset.sourceDataUriSha256 || "") ||
        !Number.isSafeInteger(asset.bytes) || asset.bytes <= 0 ||
        !["image/jpeg", "image/png", "image/webp"].includes(asset.mimeType) ||
        !["jpg", "png", "webp"].includes(asset.extension) ||
        (asset.mimeType === "image/jpeg" ? "jpg" : asset.mimeType.split("/")[1]) !== asset.extension ||
        asset.assetType !== "primary" || asset.sortOrder !== 0 ||
        typeof asset.objectVerified !== "boolean" || typeof asset.metadataVerified !== "boolean" ||
        typeof asset.avatarCleared !== "boolean") {
      throw new Error("Invalid migration manifest: malformed primary asset entry");
    }
    const pathParts = typeof asset.storagePath === "string" ? asset.storagePath.split("/") : [];
    const filename = pathParts[2] || "";
    const fileId = filename.endsWith("." + asset.extension)
      ? filename.slice(0, -(asset.extension.length + 1))
      : "";
    if (pathParts.length !== 3 || pathParts[0] !== asset.authorId || pathParts[1] !== asset.characterId ||
        !UUID.test(fileId) || storagePaths.has(asset.storagePath)) {
      throw new Error("Invalid migration manifest: unsafe or duplicate Storage path");
    }
    if (assetsByCharacter.has(asset.characterId)) {
      throw new Error("Invalid migration manifest: duplicate character asset");
    }
    assetsByCharacter.set(asset.characterId, asset);
    storagePaths.add(asset.storagePath);
  }

  const historicalAssetsByPath = new Map();
  for (const asset of manifest.historicalAssets) {
    assertPlainObject(asset, "historical asset");
    if (!UUID.test(asset.characterId || "") || !UUID.test(asset.authorId || "") ||
        !SHA256.test(asset.sourceSha256 || "") || !Number.isSafeInteger(asset.bytes) || asset.bytes <= 0 ||
        !["image/jpeg", "image/png", "image/webp"].includes(asset.mimeType) ||
        !["jpg", "png", "webp"].includes(asset.extension) ||
        (asset.mimeType === "image/jpeg" ? "jpg" : asset.mimeType.split("/")[1]) !== asset.extension ||
        asset.assetType !== "historical" || typeof asset.objectVerified !== "boolean") {
      throw new Error("Invalid migration manifest: malformed historical asset entry");
    }
    const pathParts = typeof asset.storagePath === "string" ? asset.storagePath.split("/") : [];
    const filename = pathParts[2] || "";
    const fileId = filename.endsWith("." + asset.extension)
      ? filename.slice(0, -(asset.extension.length + 1))
      : "";
    if (pathParts.length !== 3 || pathParts[0] !== asset.authorId || pathParts[1] !== asset.characterId ||
        !UUID.test(fileId) || storagePaths.has(asset.storagePath)) {
      throw new Error("Invalid migration manifest: unsafe or duplicate historical Storage path");
    }
    storagePaths.add(asset.storagePath);
    historicalAssetsByPath.set(asset.storagePath, asset);
  }

  const sessionIds = new Set();
  const validateSnapshot = (item, kind) => {
    assertPlainObject(item, `${kind} snapshot`);
    assertPlainObject(item.targetSnapshot, `${kind} targetSnapshot`);
    if (!UUID.test(item.sessionId || "") || !UUID.test(item.characterId || "") ||
        !SHA256.test(item.expectedSnapshotHash || "") || !SHA256.test(item.targetSnapshotHash || "") ||
        !SHA256.test(item.expectedImageSha256 || "") || item.targetSnapshot.image !== "" ||
        item.targetSnapshotHash !== hashJson(item.targetSnapshot) ||
        typeof item.completed !== "boolean" || sessionIds.has(item.sessionId)) {
      throw new Error(`Invalid migration manifest: malformed or duplicate ${kind} snapshot entry`);
    }
    if (kind === "current") {
      const asset = assetsByCharacter.get(item.characterId);
      if (!asset || item.expectedImageSha256 !== asset.sourceSha256 ||
          item.targetSnapshot.imagePath !== asset.storagePath) {
        throw new Error("Invalid migration manifest: current snapshot does not match its primary asset");
      }
    } else {
      const asset = historicalAssetsByPath.get(item.targetSnapshot.imagePath);
      if (!asset || asset.characterId !== item.characterId || asset.sourceSha256 !== item.expectedImageSha256) {
        throw new Error("Invalid migration manifest: historical snapshot does not point to its exact preserved image asset");
      }
    }
    sessionIds.add(item.sessionId);
  };
  for (const item of manifest.currentSnapshots) validateSnapshot(item, "current");
  for (const item of manifest.historicalSnapshots) validateSnapshot(item, "historical");

  const allAssetsVerified = manifest.assets.every(asset => asset.objectVerified && asset.metadataVerified) &&
    manifest.historicalAssets.every(asset => asset.objectVerified);
  const allSnapshotsCompleted = [...manifest.currentSnapshots, ...manifest.historicalSnapshots]
    .every(item => item.completed);
  if (manifest.assets.some(asset => asset.avatarCleared && (!asset.objectVerified || !asset.metadataVerified))) {
    throw new Error("Invalid migration manifest: avatar was cleared before its object and metadata were verified");
  }
  if (manifest.assets.some(asset => asset.avatarCleared) && !allSnapshotsCompleted) {
    throw new Error("Invalid migration manifest: avatar was cleared before all snapshots completed");
  }
  if (manifest.status === "complete" &&
      (!allAssetsVerified || !allSnapshotsCompleted || !manifest.assets.every(asset => asset.avatarCleared))) {
    throw new Error("Invalid migration manifest: complete status requires every migration step to be verified");
  }
  return manifest;
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
  validateMigrationManifest(manifest);
  if (manifest.status === "complete") return manifest;
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

  for (const asset of manifest.historicalAssets) {
    const sourceItem = manifest.historicalSnapshots.find(item => item.targetSnapshot.imagePath === asset.storagePath);
    if (!sourceItem) throw new Error(`No historical snapshot references Storage asset: ${asset.storagePath}`);
    const sourceSession = await adapter.getSession(sourceItem.sessionId);
    if (!sourceSession || sourceSession.character_id !== asset.characterId) {
      throw new Error(`Historical image source session changed: ${sourceItem.sessionId}`);
    }
    let bytes = null;
    const image = sourceSession.character_snapshot?.image;
    if (typeof image === "string" && image.startsWith("data:image/")) {
      const parsed = adapter.parseDataUri(image);
      if (!parsed || parsed.sha256 !== asset.sourceSha256 ||
          parsed.mimeType !== asset.mimeType || parsed.extension !== asset.extension) {
        throw new Error(`Historical source image changed: ${sourceItem.sessionId}`);
      }
      bytes = parsed.bytes;
    } else if (sourceSession.character_snapshot?.imagePath !== asset.storagePath) {
      throw new Error(`Historical image bytes are unavailable before upload: ${sourceItem.sessionId}`);
    }
    await adapter.ensureObject({ ...asset, bytes });
    asset.objectVerified = true;
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

export function createResumableManifest(plan, characters) {
  if (!Array.isArray(characters)) throw new TypeError("Source character rows are required");
  const characterById = new Map(characters.map(row => [row.id, row]));
  const assets = plan.primaryAssets.map(asset => {
    const source = characterById.get(asset.characterId);
    if (!source || typeof source.avatar_url !== "string" || !source.avatar_url.startsWith("data:image/")) {
      throw new Error("Missing original Data URI for manifest: " + asset.characterId);
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
    targetSnapshot: structuredClone(item.nextSnapshot),
    targetSnapshotHash: hashJson(item.nextSnapshot),
    expectedImageSha256: item.sourceSha256,
    completed: false,
  });
  const manifest = {
    version: 1,
    status: "pending",
    createdAt: new Date().toISOString(),
    counts: { ...plan.counts },
    assets,
    historicalAssets: plan.historicalAssets.map(asset => ({
      ...asset,
      objectVerified: false,
    })),
    currentSnapshots: plan.currentSnapshots.map(toItem),
    historicalSnapshots: plan.historicalSnapshots.map(toItem),
  };
  return validateMigrationManifest(manifest);
}
