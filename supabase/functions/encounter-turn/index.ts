// POYOZZ Encounter-only turn handler.
// Demo response only; no real AI provider is connected yet.
// Billing is server-side through the existing idempotent fixed-cost reservation RPC.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});
const isUuid = (v: unknown): v is string =>
  typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = request.headers.get("Authorization");
  if (!url || !anon || !service) return json({ error: "server_not_configured" }, 503);
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try { body = await request.json(); } catch { return json({ error: "invalid_json" }, 400); }
  const { turnId, sessionId, userMessageId, assistantMessageId } = body;
  if (![turnId, sessionId, userMessageId, assistantMessageId].every(isUuid)) {
    return json({ error: "invalid_turn_identifiers" }, 400);
  }

  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);

  const { data: active, error: activeError } = await userClient.rpc("account_is_active");
  if (activeError || active !== true) return json({ error: "account_not_active" }, 403);
  const { error: walletError } = await userClient.rpc("ensure_wallet_account");
  if (walletError) return json({ error: "wallet_not_ready" }, 409);

  const { data: session, error: sessionError } = await admin.from("chat_sessions")
    .select("id,user_id,deleted_at,character_id,character_snapshot,chat_mode")
    .eq("id", sessionId).eq("user_id", user.id).is("deleted_at", null).maybeSingle();
  if (sessionError) return json({ error: "session_lookup_failed" }, 503);
  if (!session) return json({ error: "chat_session_not_owned_or_active" }, 403);
  if (session.chat_mode !== "encounter") return json({ error: "encounter_session_required", retryAllowed: false }, 409);
  if (!isUuid(session.character_id)) return json({ error: "chat_session_character_id_invalid", retryAllowed: false }, 409);

  const { data: canOpen, error: eligibilityError } = await userClient.rpc("can_open_encounter_session", {
    p_character_id: session.character_id,
  });
  if (eligibilityError || canOpen !== true) return json({ error: "encounter_character_unavailable", retryAllowed: false }, 403);

  const snapshot = session.character_snapshot;
  if (snapshot && typeof snapshot === "object" && !Array.isArray(snapshot) &&
      snapshot.id && snapshot.id !== session.character_id) {
    return json({ error: "chat_session_character_snapshot_mismatch", retryAllowed: false }, 409);
  }

  const { data: userMessage, error: messageError } = await admin.from("chat_messages")
    .select("id,session_id,role,content,deleted_at")
    .eq("id", userMessageId).eq("session_id", sessionId).eq("role", "user")
    .is("deleted_at", null).maybeSingle();
  if (messageError) return json({ error: "user_message_lookup_failed" }, 503);
  if (!userMessage || !String(userMessage.content || "").trim()) return json({ error: "user_message_not_found" }, 400);

  const { data: reservation, error: reserveError } = await admin.rpc("reserve_chat_turn", {
    p_user_id: user.id, p_turn_id: turnId, p_session_id: sessionId,
    p_user_message_id: userMessageId, p_assistant_message_id: assistantMessageId,
  });
  if (reserveError?.code === "23505" || String(reserveError?.message || "").includes("chat_turn_charges_user_message_id_uidx")) return json({ error: "user_message_already_charged", retryAllowed: false }, 409);\n  if (reserveError) return json({ error: "reservation_failed" }, 503);
  const charge = Array.isArray(reservation) ? reservation[0] : reservation;
  if (!charge) return json({ error: "reservation_state_missing" }, 503);
  if (charge.status === "insufficient_funds") return json({
    status: "insufficient_funds",
    balance: { silver_coins: charge.balance_silver, diamonds: charge.balance_diamonds },
    rewardVideoSuggested: true,
  }, 402);
  if (charge.status === "refunded") return json({ error: "turn_already_refunded" }, 409);

  const demoReply = "**你抬起頭，認真地看向眼前的人。**\n「我在這裡，你想先聊些什麼？」";
  const persistInteraction = async (assistantContent: string) => {
    const userText = String(userMessage.content || "").trim().slice(0, 900);
    const assistantText = String(assistantContent || "").trim().slice(0, 900);
    const summary = ("你：" + userText + "\n角色：" + assistantText).slice(0, 1900);
    return await admin.rpc("record_encounter_turn_interaction", {
      p_turn_id: turnId,
      p_user_id: user.id,
      p_character_id: session.character_id,
      p_affinity_delta: 1,
      p_event_type: "conversation_turn",
      p_summary: summary || "完成一次相遇對話",
      p_metadata: {
        session_id: sessionId,
        user_message_id: userMessageId,
        assistant_message_id: assistantMessageId,
      },
    });
  };
  if (charge.status === "settled") {
    const { data: saved, error: savedError } = await admin.from("chat_messages")
      .select("id,content,role").eq("id", assistantMessageId).eq("session_id", sessionId)
      .eq("role", "assistant").is("deleted_at", null).maybeSingle();
    if (savedError || !saved || !String(saved.content || "").trim()) {
      return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
    }
    const { data: interaction, error: interactionError } = await persistInteraction(saved.content);
    if (interactionError) {
      return json({ status: "needs_reconciliation", error: "encounter_interaction_persistence_failed", retryAllowed: true }, 503);
    }
    const interactionRow = Array.isArray(interaction) ? interaction[0] : interaction;
    if (!interactionRow || !interactionRow.diary_id) {
      return json({ status: "needs_reconciliation", error: "encounter_interaction_receipt_missing", retryAllowed: true }, 503);
    }
    return json({
      status: "settled", assistantMessage: saved, idempotent: true,
      encounter: { affinity: interactionRow.affinity, relationshipStage: interactionRow.relationship_stage, diaryId: interactionRow.diary_id, interactionIdempotent: interactionRow.idempotent },
    });
  }
  if (charge.status !== "reserved" && charge.status !== "needs_reconciliation") {
    return json({ error: "turn_not_processable" }, 409);
  }

  // Retry recovery: reuse only the exact expected deterministic reply.
  const { data: existing, error: existingError } = await admin.from("chat_messages")
    .select("id,content,role").eq("id", assistantMessageId).eq("session_id", sessionId)
    .eq("role", "assistant").is("deleted_at", null).maybeSingle();
  if (existingError) return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
  if (existing && String(existing.content || "").trim() !== demoReply) {
    return json({ status: "needs_reconciliation", error: "assistant_message_id_collision", retryAllowed: false }, 409);
  }

  let reply = existing;
  if (!reply) {
    const { data: inserted, error: insertError } = await admin.from("chat_messages").insert({
      id: assistantMessageId, session_id: sessionId, role: "assistant",
      content: demoReply, created_at: new Date().toISOString(),
    }).select("id,content,role").single();
    if (insertError || !inserted) {
      // Keep the reservation unresolved; do not risk a refund racing a late write.
      return json({ status: "needs_reconciliation", retryAllowed: true }, 503);
    }
    reply = inserted;
  }

  const { data: settled, error: settleError } = await admin.rpc("settle_chat_turn", {
    p_user_id: user.id, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
  });
  if (settleError) return json({ status: "needs_reconciliation", replySaved: true, retryAllowed: true }, 503);
  const { data: interaction, error: interactionError } = await persistInteraction(reply.content);
  if (interactionError) {
    return json({ status: "needs_reconciliation", error: "encounter_interaction_persistence_failed", retryAllowed: true }, 503);
  }
  const interactionRow = Array.isArray(interaction) ? interaction[0] : interaction;
  if (!interactionRow || !interactionRow.diary_id) {
    return json({ status: "needs_reconciliation", error: "encounter_interaction_receipt_missing", retryAllowed: true }, 503);
  }
  return json({
    status: settled, assistantMessage: reply,
    billing: { cost: 2, silver_reserved: charge.silver_reserved, diamonds_reserved: charge.diamonds_reserved },
    encounter: { affinity: interactionRow.affinity, relationshipStage: interactionRow.relationship_stage, diaryId: interactionRow.diary_id, interactionIdempotent: interactionRow.idempotent },
  });
});
