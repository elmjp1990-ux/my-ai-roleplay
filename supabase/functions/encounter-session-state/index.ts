import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });
const isUuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = request.headers.get("Authorization");
  if (!url || !anonKey || !serviceRoleKey) return json({ error: "server_not_configured" }, 503);
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const sessionId = body.sessionId;
  const action = body.action;
  if (!isUuid(sessionId) || !["pause", "resume"].includes(String(action))) {
    return json({ error: "invalid_encounter_state_request" }, 400);
  }

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);

  const { data: active, error: activeError } = await userClient.rpc("account_is_active");
  if (activeError || active !== true) return json({ error: "account_not_active" }, 403);

  const { data, error } = await admin.rpc("set_encounter_session_lifecycle_state", {
    p_session_id: sessionId,
    p_user_id: user.id,
    p_action: action,
  });
  if (error) {
    const message = String(error.message || "");
    if (error.code === "P0002") return json({ error: "encounter_session_not_found" }, 404);
    if (error.code === "23514") return json({
      error: message.includes("expired") || message.includes("closed")
        ? "encounter_scene_expired_or_closed"
        : "encounter_state_transition_rejected",
    }, 409);
    if (error.code === "22023") return json({ error: "invalid_encounter_state_request" }, 400);
    console.error("Encounter state transition failed:", message);
    return json({ error: "encounter_state_update_failed" }, 503);
  }

  return json({ encounter: data });
});
