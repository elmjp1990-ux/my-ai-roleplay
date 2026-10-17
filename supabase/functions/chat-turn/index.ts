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

  // Prefer durable generation identity over reply text. Real AI output is not
  // deterministic; matching content to demoReply is only a legacy demo fallback.
  type ReplyIdentityResult = "match" | "mismatch" | "unknown";
  const replyIdentityMatchesCurrentTurn = async (content: unknown): Promise<ReplyIdentityResult> => {
    if (!String(content || "").trim()) return "mismatch";
    const { data: generationRecord, error: generationRecordError } = await admin
      .from("ai_generation_records")
      .select("user_id,session_id,user_message_id,assistant_message_id,original_content")
      .eq("assistant_message_id", assistantMessageId)
      .maybeSingle();

    if (generationRecordError) return "unknown";
    if (generationRecord) {
      const matches = generationRecord.user_id === user.id &&
        generationRecord.session_id === sessionId &&
        generationRecord.user_message_id === userMessageId &&
        generationRecord.assistant_message_id === assistantMessageId &&
        String(generationRecord.original_content || "").trim().length > 0;
      return matches ? "match" : "mismatch";
    }

    // The demo fallback is valid only for the known deterministic test reply.
    // Once real AI is connected, every billable reply must have a durable
    // generation record; arbitrary content without that record is not trusted.
    return String(content) === demoReply ? "match" : "mismatch";
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

  // Persist durable generation identity before the assistant message. Matching
  // only the deterministic demo text is not sufficient: a reused assistant ID
  // could otherwise make a different turn settle against an old identical reply.
  const generationRecordPayload = {
    user_id: user.id,
    session_id: sessionId,
    user_message_id: userMessageId,
    assistant_message_id: assistantMessageId,
    request_id: turnId,
    original_content: demoReply,
    status: "success",
  };
  const generationRecordMatches = (record: Record<string, unknown> | null | undefined) =>
    !!record &&
    record.user_id === user.id &&
    record.session_id === sessionId &&
    record.user_message_id === userMessageId &&
    record.assistant_message_id === assistantMessageId &&
    record.request_id === turnId &&
    String(record.original_content || "").trim() === demoReply;

  const { data: existingGenerationRecord, error: generationRecordLookupError } = await admin
    .from("ai_generation_records")
    .select("user_id,session_id,user_message_id,assistant_message_id,request_id,original_content")
    .eq("assistant_message_id", assistantMessageId)
    .maybeSingle();
  if (generationRecordLookupError) {
    return json({ status: "needs_reconciliation", error: "generation_record_lookup_failed", retryAllowed: false }, 503);
  }
  if (existingGenerationRecord && !generationRecordMatches(existingGenerationRecord)) {
    await admin.from("chat_turn_charges").update({
      status: "needs_reconciliation",
      failure_code: "assistant_message_id_collision",
      updated_at: new Date().toISOString(),
    }).eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved");
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
      stage: "generation_record", error_code: "assistant_message_id_collision",
    });
    return json({ status: "needs_reconciliation", error: "assistant_message_id_collision", retryAllowed: false }, 409);
  }
  if (!existingGenerationRecord) {
    // Never claim an already-existing assistant row for a new turn. This
    // closes the collision case where identical demo text could otherwise
    // be paired with a newly inserted generation record after the fact.
    const { data: preexistingAssistantRow, error: preexistingAssistantLookupError } = await admin
      .from("chat_messages")
      .select("id")
      .eq("id", assistantMessageId)
      .maybeSingle();
    if (preexistingAssistantLookupError) {
      return json({ status: "needs_reconciliation", error: "assistant_message_lookup_failed", retryAllowed: false }, 503);
    }
    if (preexistingAssistantRow) {
      await admin.from("chat_turn_charges").update({
        status: "needs_reconciliation",
        failure_code: "assistant_message_id_collision",
        updated_at: new Date().toISOString(),
      }).eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved");
      await admin.from("chat_turn_events").insert({
        turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
        stage: "generation_record", error_code: "assistant_message_id_collision",
      });
      return json({ status: "needs_reconciliation", error: "assistant_message_id_collision", retryAllowed: false }, 409);
    }

    const { error: generationRecordInsertError } = await admin
      .from("ai_generation_records")
      .insert(generationRecordPayload);
    if (generationRecordInsertError) {
      // An insert response can be lost after the database committed. Re-read
      // the stable assistant ID and accept only the exact same turn identity.
      const { data: confirmedGenerationRecord, error: confirmGenerationRecordError } = await admin
        .from("ai_generation_records")
        .select("user_id,session_id,user_message_id,assistant_message_id,request_id,original_content")
        .eq("assistant_message_id", assistantMessageId)
        .maybeSingle();
      if (confirmGenerationRecordError) {
        return json({ status: "needs_reconciliation", error: "generation_record_write_outcome_unknown", retryAllowed: false }, 503);
      }
      if (!generationRecordMatches(confirmedGenerationRecord)) {
        await admin.from("chat_turn_charges").update({
          status: "needs_reconciliation",
          failure_code: "generation_record_write_failed",
          updated_at: new Date().toISOString(),
        }).eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved");
        await admin.from("chat_turn_events").insert({
          turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
          stage: "generation_record", error_code: "generation_record_write_failed",
        });
        return json({ status: "needs_reconciliation", error: "generation_record_write_failed", retryAllowed: false }, 503);
      }
    }
  }

  // Stable demo output: a repeated request uses the same assistantMessageId,
  // so it cannot create a second billable reply for this turn.
  const assistantRow = {
    id: assistantMessageId,
    session_id: sessionId,
    role: "assistant",
    content: demoReply,
    created_at: new Date().toISOString(),
  };

  const { error: saveReplyError } = await admin
    .from("chat_messages")
    .insert(assistantRow);

  if (saveReplyError) {
    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "persistence_failed",
      stage: "assistant_message", error_code: "assistant_persistence_failed",
    });
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
      const identityResult = await replyIdentityMatchesCurrentTurn(possibleReply.content);
      if (identityResult === "unknown") {
        await admin.from("chat_turn_charges").update({
          status: "needs_reconciliation",
          failure_code: "generation_record_lookup_failed",
          updated_at: new Date().toISOString(),
        }).eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved");
        await admin.from("chat_turn_events").insert({
          turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
          stage: "reply_identity", error_code: "generation_record_lookup_failed",
        });
        return json({ status: "needs_reconciliation", error: "generation_record_lookup_failed", retryAllowed: false }, 503);
      }
      if (identityResult === "mismatch") {
        await admin.from("chat_turn_charges").update({
          status: "needs_reconciliation",
          failure_code: "assistant_message_id_collision",
          updated_at: new Date().toISOString(),
        }).eq("turn_id", turnId).eq("user_id", user.id).eq("status", "reserved");
        await admin.from("chat_turn_events").insert({
          turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
          stage: "persistence", error_code: "assistant_message_id_collision",
        });
        return json({ status: "needs_reconciliation", error: "assistant_message_id_collision", retryAllowed: false }, 409);
      }

      await admin.from("chat_turn_events").insert({
        turn_id: turnId, user_id: user.id, event_type: "assistant_reply_saved",
        stage: "persistence",
      });
      const { data: settled, error: settleError } = await admin.rpc("settle_chat_turn", {
        p_user_id: user.id, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
      });
      if (settleError) return json({ status: "needs_reconciliation", retryAllowed: false }, 503);
      return json({ status: settled, assistantMessage: possibleReply, recovered: true });
    }

    // The refund RPC locks the charge row and rechecks durable reply presence.
    // The SQL draft's BEFORE INSERT trigger takes the same row lock, preventing
    // a late assistant insert from racing past a successful refund.
    const { data: refunded, error: refundError } = await admin.rpc("refund_chat_turn", {
      p_user_id: user.id,
      p_turn_id: turnId,
      p_assistant_message_id: assistantMessageId,
      p_failure_code: "assistant_persistence_failed",
    });

    if (!refundError) {
      const refundResult = Array.isArray(refunded) ? refunded[0] : refunded;
      if (refundResult?.status === "refunded") {
        await admin.from("chat_turn_events").insert({
          turn_id: turnId, user_id: user.id, event_type: "refunded",
          stage: "persistence", error_code: "assistant_persistence_failed",
        });
        return json({
          status: "refunded",
          balance: {
            silver_coins: refundResult.balance_silver,
            diamonds: refundResult.balance_diamonds,
          },
        }, 200);
      }
    }

    // A concurrent insert may have won the charge-row lock. Re-read and settle
    // only if the exact deterministic reply is now durable; otherwise keep the
    // turn unresolved rather than refunding or claiming success.
    const { data: finalReply, error: finalReplyError } = await admin
      .from("chat_messages").select("id,content")
      .eq("id", assistantMessageId).eq("session_id", sessionId)
      .eq("role", "assistant").is("deleted_at", null).maybeSingle();

    if (!finalReplyError && finalReply) {
      const finalIdentityResult = await replyIdentityMatchesCurrentTurn(finalReply.content);
      if (finalIdentityResult === "match") {
        const { data: finalSettlement, error: finalSettlementError } = await admin.rpc("settle_chat_turn", {
          p_user_id: user.id, p_turn_id: turnId, p_assistant_message_id: assistantMessageId,
        });
        if (!finalSettlementError) {
          return json({ status: finalSettlement, assistantMessage: finalReply, recovered: true });
        }
      } else {
        const identityError = finalIdentityResult === "unknown"
          ? "generation_record_lookup_failed"
          : "assistant_message_id_collision";
        await admin.from("chat_turn_events").insert({
          turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
          stage: "reply_identity", error_code: identityError,
        });
        return json({
          status: "needs_reconciliation",
          error: identityError,
          retryAllowed: false,
        }, finalIdentityResult === "unknown" ? 503 : 409);
      }
    }

    await admin.from("chat_turn_events").insert({
      turn_id: turnId, user_id: user.id, event_type: "needs_reconciliation",
      stage: "persistence", error_code: refundError ? "refund_or_reply_outcome_unknown" : "assistant_persistence_failed",
    });
    return json({ status: "needs_reconciliation", retryAllowed: true }, 503);
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
