// PersonaX demo chat-turn billing orchestrator.
// This function is source-only until the reviewed wallet SQL draft is applied
// and the Edge Function is deliberately deployed. It does not call a real AI provider.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const isUuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = request.headers.get("Authorization");

  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: "server_not_configured" }, 503);
  }
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const { turnId, sessionId, userMessageId, assistantMessageId } = body;
  if (![turnId, sessionId, userMessageId, assistantMessageId].every(isUuid)) {
    return json({ error: "invalid_turn_identifiers" }, 400);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);

  const { data: active, error: activeError } = await userClient.rpc("account_is_active");
  if (activeError || active !== true) return json({ error: "account_not_active" }, 403);

  const { error: walletInitError } = await userClient.rpc("ensure_wallet_account");
  if (walletInitError) return json({ error: "wallet_not_ready" }, 409);

  const { data: session, error: sessionError } = await admin
    .from("chat_sessions")
    .select("id,user_id,deleted_at")
    .eq("id", sessionId)
    .eq("user_id", user.id)
    .is("deleted_at", null)
    .maybeSingle();
  if (sessionError) return json({ error: "session_lookup_failed" }, 503);
  if (!session) return json({ error: "chat_session_not_owned_or_active" }, 403);

  const { data: userMessage, error: messageError } = await admin
    .from("chat_messages")
    .select("id,session_id,role,content,deleted_at")
    .eq("id", userMessageId)
    .eq("session_id", sessionId)
    .eq("role", "user")
    .is("deleted_at", null)
    .maybeSingle();
  if (messageError) return json({ error: "user_message_lookup_failed" }, 503);
  if (!userMessage || !String(userMessage.content || "").trim()) {
    return json({ error: "user_message_not_found" }, 400);
  }

  const { data: reservation, error: reserveError } = await admin.rpc("reserve_chat_turn", {
    p_user_id: user.id,
    p_turn_id: turnId,
    p_session_id: sessionId,
    p_user_message_id: userMessageId,
  });
  if (reserveError) return json({ error: "reservation_failed", code: reserveError.message }, 503);
  const charge = Array.isArray(reservation) ? reservation[0] : reservation;
  if (!charge) return json({ error: "reservation_state_missing" }, 503);

  if (charge.status === "insufficient_funds") {
    return json({
      status: "insufficient_funds",
      balance: { silver_coins: charge.balance_silver, diamonds: charge.balance_diamonds },
      rewardVideoSuggested: true,
    }, 402);
  }
  if (charge.status === "settled") {
    const { data: savedReply, error: savedReplyError } = await admin
      .from("chat_messages").select("id,content")
      .eq("id", assistantMessageId).eq("session_id", sessionId)
      .eq("role", "assistant").is("deleted_at", null).maybeSingle();
    if (savedReplyError || !savedReply) return json({ error: "settled_reply_lookup_failed" }, 503);
    return json({ status: "settled", assistantMessage: savedReply, idempotent: true });
  }
  if (charge.status === "refunded") return json({ error: "turn_already_refunded" }, 409);
  if (charge.status === "needs_reconciliation") {
    // This deterministic demo has no external generation job. Reconcile by
    // checking whether the stable assistant message was durably stored.
    // A real AI provider integration must also query the provider/job status
    // before refunding an absent reply.
    const { data: recoveredReply, error: recoveredReplyError } = await admin
      .from("chat_messages").select("id,content")
      .eq("id", assistantMessageId).eq("session_id", sessionId)
      .eq("role", "assistant").is("deleted_at", null).maybeSingle();

    if (recoveredReplyError) {
      return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
    }
    if (recoveredReply && String(recoveredReply.content || "").trim()) {
      const { data: settledAgain, error: settleAgainError } = await admin.rpc("settle_chat_turn", {
        p_user_id: user.id, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
      });
      if (settleAgainError) return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
      return json({ status: settledAgain, assistantMessage: recoveredReply, recovered: true });
    }

    const { error: refundAgainError } = await admin.rpc("refund_chat_turn", {
      p_user_id: user.id, p_turn_id: turnId, p_failure_code: "demo_reply_not_persisted",
    });
    if (refundAgainError) return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
    return json({ status: "refunded", error: "demo_reply_not_persisted", recovered: true }, 503);
  }
  if (charge.status !== "reserved") return json({ error: "turn_not_processable" }, 409);

  // Stable demo output: a repeated request uses the same assistantMessageId,
  // so it cannot create a second billable reply for this turn.
  const demoReply = "**他將目光移向你，耐心等待你繼續說下去。**\n「我在聽，你可以慢慢說。」";
  const assistantRow = {
    id: assistantMessageId,
    session_id: sessionId,
    role: "assistant",
    content: demoReply,
    created_at: new Date().toISOString(),
  };

  const { error: saveReplyError } = await admin
    .from("chat_messages")
    .upsert(assistantRow, { onConflict: "id" });

  if (saveReplyError) {
    // Do not refund until a follow-up read confirms the reply is absent.
    const { data: possibleReply, error: verifyError } = await admin
      .from("chat_messages").select("id,content")
      .eq("id", assistantMessageId).eq("session_id", sessionId)
      .eq("role", "assistant").is("deleted_at", null).maybeSingle();

    if (verifyError) {
      await admin.from("chat_turn_charges").update({
        status: "needs_reconciliation",
        failure_code: "reply_write_outcome_unknown",
        updated_at: new Date().toISOString(),
      }).eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved");
      await admin.from("chat_turn_events").insert({
        turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
        stage: "persistence", error_code: "reply_write_outcome_unknown",
      });
      return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
    }

    if (possibleReply && String(possibleReply.content || "").trim()) {
      const { data: settled, error: settleError } = await admin.rpc("settle_chat_turn", {
        p_user_id: user.id, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
      });
      if (settleError) return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
      return json({ status: settled, assistantMessage: possibleReply, recovered: true });
    }

    const { error: refundError } = await admin.rpc("refund_chat_turn", {
      p_user_id: user.id, p_turn_id: turnId, p_failure_code: "assistant_persistence_failed",
    });
    if (refundError) return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
    return json({ status: "refunded", error: "assistant_persistence_failed" }, 503);
  }

  const { data: settled, error: settleError } = await admin.rpc("settle_chat_turn", {
    p_user_id: user.id,
    p_turn_id: turnId,
    p_assistant_message_id: assistantMessageId,
  });
  if (settleError) {
    // The reply is already durable. Never refund here; reconcile the settlement.
    await admin.from("chat_turn_charges").update({
      status: "needs_reconciliation",
      failure_code: "settlement_acknowledgement_lost",
      updated_at: new Date().toISOString(),
    }).eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved");
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
      stage: "settlement", error_code: "settlement_acknowledgement_lost",
    });
    return json({ status: "needs_reconciliation", replySaved: true, retryAllowed: false }, 503);
  }

  return json({
    status: settled,
    assistantMessage: { id: assistantMessageId, content: demoReply, role: "assistant" },
    billing: { cost: 2, silver_reserved: charge.silver_reserved, diamonds_reserved: charge.diamonds_reserved },
  });
});
