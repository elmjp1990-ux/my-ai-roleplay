import { createClient } from "npm:@supabase/supabase-js@2";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const apiUrl = Deno.env.get("API_URL");
const anonKey = Deno.env.get("ANON_KEY");
const serviceRoleKey = Deno.env.get("SERVICE_ROLE_KEY");
assert(apiUrl && anonKey && serviceRoleKey, "Local Supabase API_URL, ANON_KEY and SERVICE_ROLE_KEY are required");

const admin = createClient(apiUrl, serviceRoleKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const email = `stale-jwt-${crypto.randomUUID()}@poyozz.invalid`;
const password = `Poyozz-${crypto.randomUUID()}-Aa9!`;
let userId: string | null = null;

try {
  const created = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (created.error) throw created.error;
  userId = created.data.user.id;

  const browser = createClient(apiUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const signedIn = await browser.auth.signInWithPassword({ email, password });
  if (signedIn.error) throw signedIn.error;
  const oldAccessToken = signedIn.data.session?.access_token;
  assert(oldAccessToken, "Local Auth did not issue an access token");

  // Confirm the token is active before Auth Admin deletion.
  const before = createClient(apiUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${oldAccessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const beforeCheck = await before.rpc("account_is_active");
  if (beforeCheck.error) throw beforeCheck.error;
  assert(beforeCheck.data === true, "Fresh JWT must pass account_is_active before deletion");

  const deleted = await admin.auth.admin.deleteUser(userId);
  if (deleted.error) throw deleted.error;

  // Keep using the exact access token issued before deletion. PostgREST verifies
  // its signature, while account_is_active must independently consult auth.users.
  const after = createClient(apiUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${oldAccessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const afterCheck = await after.rpc("account_is_active");
  if (afterCheck.error) throw afterCheck.error;
  assert(afterCheck.data === false, "A still-valid pre-deletion JWT must fail account_is_active after Auth Admin deletion");

  console.log("Local Auth Admin deletion -> pre-existing JWT rejected by account_is_active passed.");
} finally {
  // If the test failed before deletion, clean up only the synthetic local Auth user.
  if (userId) {
    const lookup = await admin.auth.admin.getUserById(userId);
    if (lookup.data.user) await admin.auth.admin.deleteUser(userId);
  }
}
