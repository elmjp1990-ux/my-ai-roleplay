// PersonaX demo chat-turn billing orchestrator.
// This deployed demo function uses a fixed reply; it does not call a real AI provider.
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

  const turnId = body.turnId;
  const sessionId = body.sessionId;
  const userMessageId = body.userMessageId;
  const assistantMessageId = body.assistantMessageId;
  if (
    !isUuid(turnId) ||
    !isUuid(sessionId) ||
    !isUuid(userMessageId) ||
    !isUuid(assistantMessageId)
  ) {
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
    .select("id,user_id,deleted_at,character_id,character_snapshot")
    .eq("id", sessionId)
    .eq("user_id", user.id)
    .is("deleted_at", null)
    .maybeSingle();
  if (sessionError) return json({ error: "session_lookup_failed" }, 503);
  if (!session) return json({ error: "chat_session_not_owned_or_active" }, 403);

  // Validate the session's role identity before reserving or settling any charge.
  // Existing chats with retired characters remain usable; this only rejects
  // missing/mismatched identity metadata that could attach a turn to the wrong role.
  if (!isUuid(session.character_id)) {
    return json({ error: "chat_session_character_id_invalid", retryAllowed: false }, 409);
  }
  const characterSnapshot = session.character_snapshot;
  if (
    characterSnapshot &&
    typeof characterSnapshot === "object" &&
    !Array.isArray(characterSnapshot) &&
    characterSnapshot.id &&
    characterSnapshot.id !== session.character_id
  ) {
    return json({ error: "chat_session_character_snapshot_mismatch", retryAllowed: false }, 409);
  }

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
    p_assistant_message_id: assistantMessageId,
  });
  if (reserveError) return json({ error: "reservation_failed" }, 503);
  const charge = Array.isArray(reservation) ? reservation[0] : reservation;
  if (!charge) return json({ error: "reservation_state_missing" }, 503);

  const demoReply = "**他將目光移向你，耐心等待你繼續說下去。**\n「我在聽，你可以慢慢說。」";

  // Durable generation identity is the only acceptable proof that a recovered
  // assistant reply belongs to this turn; reply text is never an identity key.
  type ReplyIdentityResult = "match" | "mismatch" | "unknown";
  const replyIdentityMatchesCurrentTurn = async (content: unknown): Promise<ReplyIdentityResult> => {
    if (!String(content || "").trim()) return "mismatch";
    const { data: generationRecord, error: generationRecordError } = await admin
      .from("ai_generation_records")
      .select("user_id,session_id,user_message_id,assistant_message_id,request_id,original_content")
      .eq("assistant_message_id", assistantMessageId)
      .maybeSingle();

    if (generationRecordError) return "unknown";
    if (generationRecord) {
      const matches = generationRecord.user_id === user.id &&
        generationRecord.session_id === sessionId &&
        generationRecord.user_message_id === userMessageId &&
        generationRecord.assistant_message_id === assistantMessageId &&
        generationRecord.request_id === turnId &&
        String(generationRecord.original_content || "").trim().length > 0;
      return matches ? "match" : "mismatch";
    }

    // Never infer turn ownership from reply text, even in the deterministic
    // demo. A recovered reply without its durable generation identity could
    // be an old message with identical content, so it must not be settled.
    return "mismatch";
  };

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
    if (savedReplyError || !savedReply) {
      return json({ status: "needs_reconciliation", error: "settled_reply_lookup_failed", retryAllowed: false }, 503);
    }
    // A settled charge is not enough to report success if the durable reply is
    // empty. Keep the state unresolved for diagnosis instead of returning a
    // successful turn that the client cannot display.
    if (!String(savedReply.content || "").trim()) {
      await admin.from("chat_turn_events").insert({
        turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
        stage: "settled_reply_lookup", error_code: "settled_reply_empty",
      });
      return json({ status: "needs_reconciliation", error: "settled_reply_empty", retryAllowed: false }, 503);
    }
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
      const identityResult = await replyIdentityMatchesCurrentTurn(recoveredReply.content);
      if (identityResult === "unknown") {
        await admin.from("chat_turn_events").insert({
          turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
          stage: "reply_identity", error_code: "generation_record_lookup_failed",
        });
        return json({ status: "needs_reconciliation", error: "generation_record_lookup_failed", retryAllowed: false }, 503);
      }
      if (identityResult === "mismatch") {
        return json({ status: "needs_reconciliation", error: "assistant_message_id_collision", retryAllowed: false }, 409);
      }
      const { data: settledAgain, error: settleAgainError } = await admin.rpc("settle_chat_turn", {
        p_user_id: user.id, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
      });
      if (settleAgainError) return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
      return json({ status: settledAgain, assistantMessage: recoveredReply, recovered: true });
    }

    // A missing reply alone does not prove that another concurrent attempt
    // is no longer writing it. Keep the reservation and retry the same stable
    // demo message ID; never refund based only on a point-in-time absence.
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "reconciliation_retry_started",
      stage: "demo_generation",
    });
  }
  if (charge.status !== "reserved" && charge.status !== "needs_reconciliation") return json({ error: "turn_not_processable" }, 409);

  await admin.from("chat_turn_events").insert({
    turn_id: turnId, user_id: user.id, event_type: "generation_started",
    stage: "demo_generation",
  });

  // Persist the assistant reply and its durable generation identity atomically.
  // The database RPC locks the charge row, inserts chat_messages first to satisfy
  // the FK, then inserts ai_generation_records in the same transaction. Any
  // constraint failure rolls back both writes; a retry cannot adopt a lone row.
  const { data: persistenceResult, error: persistenceError } = await admin.rpc(
    "persist_chat_turn_reply",
    {
      p_user_id: user.id,
      p_turn_id: turnId,
      p_session_id: sessionId,
      p_user_message_id: userMessageId,
      p_assistant_message_id: assistantMessageId,
      p_content: demoReply,
    },
  );

  let persistedAssistantMessage: { id: string; content: string; role: string } | null = null;
  if (persistenceError) {
    // The RPC response can be lost after a successful commit. Accept recovery
    // only when both the reply row and exact durable turn identity can be read.
    const { data: possibleReply, error: replyLookupError } = await admin
      .from("chat_messages")
      .select("id,session_id,role,content,deleted_at")
      .eq("id", assistantMessageId)
      .maybeSingle();
    const identityResult = !replyLookupError && possibleReply &&
      possibleReply.session_id === sessionId &&
      possibleReply.role === "assistant" &&
      possibleReply.deleted_at === null
      ? await replyIdentityMatchesCurrentTurn(possibleReply.content)
      : replyLookupError ? "unknown" : "mismatch";

    if (identityResult === "match" && possibleReply) {
      persistedAssistantMessage = {
        id: possibleReply.id,
        content: possibleReply.content,
        role: possibleReply.role,
      };
    } else {
      await admin.from("chat_turn_charges").update({
        status: "needs_reconciliation",
        failure_code: identityResult === "unknown"
          ? "reply_persistence_outcome_unknown"
          : "reply_persistence_identity_unverified",
        updated_at: new Date().toISOString(),
      }).eq("turn_id", turnId).eq("user_id", user.id)
        .in("status", ["reserved", "needs_reconciliation"]);
      await admin.from("chat_turn_events").insert({
        turn_id: turnId,
        user_id: user.id,
        event_type: "needs_reconciliation",
        stage: "atomic_reply_persistence",
        error_code: identityResult === "unknown"
          ? "reply_persistence_outcome_unknown"
          : "reply_persistence_identity_unverified",
      });
      return json({
        status: "needs_reconciliation",
        error: identityResult === "unknown"
          ? "reply_persistence_outcome_unknown"
          : "reply_persistence_identity_unverified",
        retryAllowed: false,
      }, 503);
    }
  } else {
    const result = Array.isArray(persistenceResult)
      ? persistenceResult[0]
      : persistenceResult;
    if (
      !result ||
      result.assistant_message_id !== assistantMessageId ||
      typeof result.assistant_content !== "string" ||
      !result.assistant_content.trim()
    ) {
      await admin.from("chat_turn_charges").update({
        status: "needs_reconciliation",
        failure_code: "reply_persistence_result_invalid",
        updated_at: new Date().toISOString(),
      }).eq("turn_id", turnId).eq("user_id", user.id)
        .in("status", ["reserved", "needs_reconciliation"]);
      return json({
        status: "needs_reconciliation",
        error: "reply_persistence_result_invalid",
        retryAllowed: false,
      }, 503);
    }
    persistedAssistantMessage = {
      id: result.assistant_message_id,
      content: result.assistant_content,
      role: "assistant",
    };
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
    assistantMessage: persistedAssistantMessage,
    billing: { cost: 2, silver_reserved: charge.silver_reserved, diamonds_reserved: charge.diamonds_reserved },
  });
});
