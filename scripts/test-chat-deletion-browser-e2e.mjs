import assert from "node:assert/strict";
import fs from "node:fs";
import { chromium } from "playwright";

const apiUrl = process.env.API_URL;
const anonKey = process.env.ANON_KEY;
const serviceRoleKey = process.env.SERVICE_ROLE_KEY;
assert.ok(apiUrl && anonKey && serviceRoleKey, "Local Supabase API_URL, ANON_KEY, SERVICE_ROLE_KEY are required");

const indexHtml = fs.readFileSync("index.html", "utf8");
const extractFunction = (source, signature) => {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, `Missing actual app function: ${signature}`);
  const brace = source.indexOf("{", start);
  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let i = brace; i < source.length; i++) {
    const ch = source[i];
    const next = source[i + 1];
    if (lineComment) {
      if (ch === "\n") lineComment = false;
      continue;
    }
    if (blockComment) {
      if (ch === "*" && next === "/") {
        blockComment = false;
        i++;
      }
      continue;
    }
    if (quote) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === quote) quote = null;
      continue;
    }
    if (ch === "/" && next === "/") {
      lineComment = true;
      i++;
      continue;
    }
    if (ch === "/" && next === "*") {
      blockComment = true;
      i++;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === "`") {
      quote = ch;
      continue;
    }
    if (ch === "{") depth++;
    if (ch === "}") {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`Unclosed function: ${signature}`);
};

const extractUuidFunction = () => {
  const start = indexHtml.indexOf("function isUuid(value)");
  assert.notEqual(start, -1, "Missing actual isUuid helper");
  const end = indexHtml.indexOf("\n}", start);
  assert.notEqual(end, -1, "Could not locate isUuid helper end");
  return indexHtml.slice(start, end + 2);
};
const extractStorageListener = () => {
  const marker = "window.addEventListener('storage', event => {";
  const start = indexHtml.indexOf(marker);
  assert.notEqual(start, -1, "Missing actual cross-tab storage listener");
  const brace = indexHtml.indexOf("{", start);
  const blockStart = indexHtml.slice(brace);
  const block = extractFunction(`function __storageHarness() ${blockStart}`, "function __storageHarness()");
  const listenerBody = block.slice(block.indexOf("{") + 1, block.lastIndexOf("}"));
  return `${marker}${listenerBody}});`;
};

const tombstonePrefix = indexHtml.match(/const USER_DELETED_CHAT_TOMBSTONES_KEY_PREFIX = '([^']+)';/)?.[1];
const sessionsPrefix = indexHtml.match(/const USER_SESSIONS_KEY_PREFIX = '([^']+)';/)?.[1];
assert.ok(tombstonePrefix && sessionsPrefix, "Could not extract actual app localStorage key prefixes");

const appHarness = [
  `const USER_DELETED_CHAT_TOMBSTONES_KEY_PREFIX = ${JSON.stringify(tombstonePrefix)};`,
  `const USER_SESSIONS_KEY_PREFIX = ${JSON.stringify(sessionsPrefix)};`,
  "let state = window.__testState;",
  "let groupPrototype = window.__testGroupPrototype;",
  "let route = window.__testRoute;",
  "const currentUser = () => ({ uid: window.__testUid });",
  "const persist = () => { window.__persistCount = (window.__persistCount || 0) + 1; };",
  "const clearGroupDiaryLocalData = () => {};",
  "const go = (next) => { route = next; window.__testRoute = next; };",
  "const render = () => {};",
  "const refreshChatEntryList = () => { window.__refreshCount = (window.__refreshCount || 0) + 1; };",
  extractUuidFunction(),
  extractFunction(indexHtml, "function readDeletedChatTombstones(uid)"),
  extractFunction(indexHtml, "function markDeletedChatTombstone(uid, kind, resourceId)"),
  extractFunction(indexHtml, "function filterDeletedChatSessions(uid, sessions)"),
  extractFunction(indexHtml, "function compactCloudSessionForLocalStorage(session)"),
  extractFunction(indexHtml, "function compactSessionsForLocalStorage(sessions)"),
  extractFunction(indexHtml, "function cacheSessionsForUser(uid)"),
  extractFunction(indexHtml, "function restoreSessionsForUser(uid)"),
  "let lastDeletedChatReconcileAt = 0;",
  extractFunction(indexHtml, "async function reconcileDeletedCloudChatParents()"),
  extractStorageListener(),
  "window.__markDeletedChatTombstone = markDeletedChatTombstone;",
  "window.__restoreSessionsForUser = restoreSessionsForUser;",
  "window.__reconcileDeletedCloudChatParents = reconcileDeletedCloudChatParents;",
  "window.__getTestState = () => state;",
  "window.__getGroupPrototype = () => groupPrototype;",
  "window.__getRoute = () => route;",
].join("\n");

async function request(path, { method = "GET", key = anonKey, token = serviceRoleKey, body, prefer } = {}) {
  const headers = {
    apikey: key,
    Authorization: `Bearer ${token}`,
  };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (prefer) headers.Prefer = prefer;
  const response = await fetch(`${apiUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { response, data };
}

const email = `poyozz-delete-browser-${crypto.randomUUID()}@example.test`;
const password = `Poyozz-Test-${crypto.randomUUID()}!`;
let userId = null;
let browser = null;
let contexts = [];
try {
  const created = await request("/auth/v1/admin/users", {
    method: "POST",
    body: { email, password, email_confirm: true },
  });
  assert.ok(created.response.ok, `Could not create local test user: ${JSON.stringify(created.data)}`);
  userId = created.data.id;

  const signedIn = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    key: anonKey,
    token: anonKey,
    body: { email, password },
  });
  assert.ok(signedIn.response.ok, `Could not sign in local test user: ${JSON.stringify(signedIn.data)}`);
  const accessToken = signedIn.data.access_token;

  const sessionId = crypto.randomUUID();
  const groupId = crypto.randomUUID();
  const sessionInsert = await request("/rest/v1/chat_sessions?select=id", {
    method: "POST",
    body: [{
      id: sessionId,
      user_id: userId,
      character_name: "刪除驗收角色",
      status: "active",
      character_snapshot: {},
      session_data: {},
      chat_mode: "story",
    }],
    prefer: "return=representation",
  });
  assert.ok(sessionInsert.response.ok, `Could not seed local chat session: ${JSON.stringify(sessionInsert.data)}`);

  const groupInsert = await request("/rest/v1/chat_groups?select=id", {
    method: "POST",
    body: [{
      id: groupId,
      owner_id: userId,
      name: "跨分頁刪除驗收",
      world_background: "",
      scene_mode: "shared",
    }],
    prefer: "return=representation",
  });
  assert.ok(groupInsert.response.ok, `Could not seed local chat group: ${JSON.stringify(groupInsert.data)}`);

  const userHeaders = { key: anonKey, token: accessToken };
  const activeSessionBefore = await request(
    `/rest/v1/chat_sessions?select=id&id=eq.${sessionId}&deleted_at=is.null`,
    userHeaders,
  );
  const activeGroupBefore = await request(
    `/rest/v1/chat_groups?select=id&id=eq.${groupId}`,
    userHeaders,
  );
  assert.ok(activeSessionBefore.response.ok && activeSessionBefore.data.length === 1, "Authenticated device should initially see its active solo chat");
  assert.ok(activeGroupBefore.response.ok && activeGroupBefore.data.length === 1, "Authenticated device should initially see its active group chat");

  const directSoloDelete = await request(
    `/rest/v1/chat_sessions?id=eq.${sessionId}`,
    { ...userHeaders, method: "DELETE", prefer: "return=representation" },
  );
  const directGroupDelete = await request(
    `/rest/v1/chat_groups?id=eq.${groupId}`,
    { ...userHeaders, method: "DELETE", prefer: "return=representation" },
  );
  assert.ok(!directSoloDelete.response.ok, "Direct authenticated DELETE on chat_sessions must be denied");
  assert.ok(!directGroupDelete.response.ok, "Direct authenticated DELETE on chat_groups must be denied");

  const soloDelete = await request("/rest/v1/rpc/delete_chat_session_content", {
    ...userHeaders,
    method: "POST",
    body: { p_session_id: sessionId },
  });
  assert.ok(soloDelete.response.ok && Array.isArray(soloDelete.data), `Solo lifecycle RPC should succeed: ${JSON.stringify(soloDelete.data)}`);

  const groupDelete = await request("/rest/v1/rpc/delete_chat_group_with_related_data", {
    ...userHeaders,
    method: "POST",
    body: { p_group_id: groupId },
  });
  assert.ok(groupDelete.response.ok && Array.isArray(groupDelete.data), `Group lifecycle RPC should succeed: ${JSON.stringify(groupDelete.data)}`);

  const activeSessionAfter = await request(
    `/rest/v1/chat_sessions?select=id&id=eq.${sessionId}&deleted_at=is.null`,
    userHeaders,
  );
  const activeGroupAfter = await request(
    `/rest/v1/chat_groups?select=id&id=eq.${groupId}`,
    userHeaders,
  );
  assert.ok(activeSessionAfter.response.ok && activeSessionAfter.data.length === 0, "Backend RLS must hide the soft-deleted solo chat");
  assert.ok(activeGroupAfter.response.ok && activeGroupAfter.data.length === 0, "Backend RLS must hide the soft-deleted group chat");

  browser = await chromium.launch({ headless: true });
  const sharedContext = await browser.newContext();
  contexts.push(sharedContext);
  const page1 = await sharedContext.newPage();
  const page2 = await sharedContext.newPage();
  await Promise.all([page1.goto(apiUrl), page2.goto(apiUrl)]);

  const seedPage = async (page) => page.evaluate(({ uid, sessionId, groupId, sessionsPrefix }) => {
    window.__testUid = uid;
    window.__testState = {
      account: { uid },
      sessions: {
        [sessionId]: { id: sessionId, cloudOwned: true, cloudOwnerUid: uid },
      },
    };
    window.__testGroupPrototype = {
      ownerUid: uid,
      groups: [{ id: groupId }],
      groupPreviews: { [groupId]: {} },
      groupMembers: { [groupId]: [] },
      active: { id: groupId },
      messages: [],
      pendingRequest: null,
      loading: false,
    };
    window.__testRoute = { page: "conversation", id: sessionId };
    localStorage.setItem(
      sessionsPrefix + uid,
      JSON.stringify(window.__testState.sessions),
    );
  }, { uid: userId, sessionId, groupId, sessionsPrefix });

  await seedPage(page1);
  await seedPage(page2);
  await page1.addScriptTag({ content: appHarness });
  await page2.addScriptTag({ content: appHarness });

  const beforeRestore = await page2.evaluate((uid) => Object.keys(window.__restoreSessionsForUser(uid)), userId);
  assert.deepEqual(beforeRestore, [sessionId], "Second tab should start with the cached chat before deletion");
  const markResult = await page1.evaluate(({ uid, sessionId, groupId }) => {
    const solo = window.__markDeletedChatTombstone(uid, "sessions", sessionId);
    const group = window.__markDeletedChatTombstone(uid, "groups", groupId);
    return { solo, group };
  }, { uid: userId, sessionId, groupId });
  assert.deepEqual(markResult, { solo: true, group: true }, "Actual app tombstone helpers should accept both parent IDs");

  await page2.waitForFunction(({ sessionId, groupId }) => {
    const state = window.__getTestState();
    const groups = window.__getGroupPrototype().groups;
    return !state.sessions[sessionId] && !groups.some((group) => group.id === groupId);
  }, { sessionId, groupId });
  const sameDevice = await page2.evaluate(({ uid, sessionId, groupId }) => ({
    restored: Object.keys(window.__restoreSessionsForUser(uid)),
    sessionVisible: !!window.__getTestState().sessions[sessionId],
    groupVisible: window.__getGroupPrototype().groups.some((group) => group.id === groupId),
    route: window.__getRoute().page,
  }), { uid: userId, sessionId, groupId });
  assert.deepEqual(sameDevice.restored, [], "Second tab must not restore a tombstoned solo chat");
  assert.equal(sameDevice.sessionVisible, false, "Storage event must clear the other tab's solo chat cache");
  assert.equal(sameDevice.groupVisible, false, "Storage event must clear the other tab's group cache");
  assert.equal(sameDevice.route, "chat", "Deleted conversation route must return to chat list");

  // A separate browser context models another device: it has stale local cache
  // but no localStorage tombstone. Backend RLS reconciliation must remove it.
  const deviceContext = await browser.newContext();
  contexts.push(deviceContext);
  const devicePage = await deviceContext.newPage();
  await devicePage.goto(apiUrl);
  await seedPage(devicePage);
  await devicePage.addScriptTag({ content: appHarness });
  await devicePage.evaluate(({ apiUrl, anonKey, accessToken }) => {
    window.mySupabase = {
      from(table) {
        const filters = [];
        let columns = "id";
        const builder = {
          select(value) { columns = value; return builder; },
          eq(column, value) { filters.push([column, `eq.${value}`]); return builder; },
          in(column, values) { filters.push([column, `in.(${values.join(",")})`]); return builder; },
          is(column, value) { filters.push([column, `is.${value === null ? "null" : value}`]); return builder; },
          then(resolve, reject) {
            const params = new URLSearchParams({ select: columns });
            for (const [column, value] of filters) params.append(column, value);
            fetch(`${apiUrl}/rest/v1/${table}?${params.toString()}`, {
              headers: {
                apikey: anonKey,
                Authorization: `Bearer ${accessToken}`,
              },
            }).then(async (response) => {
              const data = response.ok ? await response.json() : null;
              return {
                data,
                error: response.ok ? null : { message: await response.text() },
              };
            }).then(resolve, reject);
          },
        };
        return builder;
      },
    };
  }, { apiUrl, anonKey, accessToken });

  const deviceBefore = await devicePage.evaluate(({ uid, tombstonePrefix }) => ({
    restored: Object.keys(window.__restoreSessionsForUser(uid)),
    tombstones: localStorage.getItem(tombstonePrefix + uid),
  }), { uid: userId, tombstonePrefix });
  assert.deepEqual(deviceBefore.restored, [sessionId], "Separate device should demonstrate stale local cache before backend reconciliation");
  assert.equal(deviceBefore.tombstones, null, "Separate device must not share another device's localStorage tombstone");

  await devicePage.evaluate(() => window.__reconcileDeletedCloudChatParents());
  const deviceAfter = await devicePage.evaluate(({ uid, sessionId, groupId }) => ({
    restored: Object.keys(window.__restoreSessionsForUser(uid)),
    sessionVisible: !!window.__getTestState().sessions[sessionId],
    groupVisible: window.__getGroupPrototype().groups.some((group) => group.id === groupId),
    route: window.__getRoute().page,
  }), { uid: userId, sessionId, groupId });
  assert.deepEqual(deviceAfter.restored, [], "Backend reconciliation must clear stale cached chats on another device");
  assert.equal(deviceAfter.sessionVisible, false, "Backend RLS reconciliation must clear solo chat cache");
  assert.equal(deviceAfter.groupVisible, false, "Backend RLS reconciliation must clear group chat cache");
  assert.equal(deviceAfter.route, "chat", "Other device must leave the deleted conversation route");

  console.log("Browser multi-tab storage-event and cross-device backend-RLS reconciliation passed.");
} finally {
  for (const context of contexts) await context.close().catch(() => {});
  if (browser) await browser.close().catch(() => {});
  if (userId) {
    await request(`/auth/v1/admin/users/${userId}`, { method: "DELETE" }).catch(() => {});
  }
}
