import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseStoryTurnEnvelope } from "./story-turn-envelope.ts";

const validSuggestions = [
  "*我稍微靠近桌邊，指尖輕敲杯沿*那你呢？你平常也會這麼晚才休息嗎？",
  "*我把手中的飲料推到你面前，語氣放輕*先喝一點吧，等你舒服些，我再陪你慢慢聊今天發生的事。",
  "*我停下腳步，回頭看向你，忍不住笑了*其實我還有件事想告訴你，只是一直在想該怎麼開口。",
];

Deno.test("parses a valid reply and bounded side effects", () => {
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({
    reply: "*他微微一笑*你好。",
    affinity_delta: 2,
    affinity_reason: "角色感受到玩家的信任。",
    phone_events: [{ event_type: "message", title: "晚安", body: "今天聊得很開心。" }],
    suggested_replies: validSuggestions,
  })), {
    reply: "*他微微一笑*你好。",
    affinity_delta: 2,
    affinity_reason: "角色感受到玩家的信任。",
    phone_events: [{ event_type: "message", title: "晚安", body: "今天聊得很開心。" }],
    suggested_replies: validSuggestions,
  });
});

Deno.test("legacy plain text remains a reply without inferred effects", () => {
  assertEquals(parseStoryTurnEnvelope("自然的角色回覆"), {
    reply: "自然的角色回覆",
    affinity_delta: 0,
    affinity_reason: "",
    phone_events: [],
    suggested_replies: [],
  });
});

Deno.test("out-of-range affinity is neutralized and invalid phone events are dropped", () => {
  const parsed = parseStoryTurnEnvelope(JSON.stringify({
    reply: "回覆",
    affinity_delta: 99,
    affinity_reason: "理由",
    phone_events: [
      { event_type: "message", title: "有效", body: "內容" },
      { event_type: "external_webhook", title: "不允許", body: "不允許" },
      { event_type: "social_post", title: "", body: "缺少標題" },
    ],
  }));
  assertEquals(parsed.affinity_delta, 0);
  assertEquals(parsed.phone_events, [{ event_type: "message", title: "有效", body: "內容" }]);
});

Deno.test("phone events support eight configured fields and text is bounded", () => {
  const parsed = parseStoryTurnEnvelope(JSON.stringify({
    reply: "回覆",
    affinity_delta: -3,
    affinity_reason: "x".repeat(400),
    phone_events: Array.from({ length: 8 }, (_, index) => ({
      event_type: "notification",
      title: "事件" + index,
      body: "內文",
    })),
  }));
  assertEquals(parsed.affinity_delta, -3);
  assertEquals(parsed.affinity_reason.length, 280);
  assertEquals(parsed.phone_events.length, 8);
});

Deno.test("suggested replies require exactly three 30–80 character action-plus-dialogue options", () => {
  const parsed = parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: validSuggestions }));
  assertEquals(parsed.suggested_replies, validSuggestions);

  assertEquals(
    parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: validSuggestions.slice(0, 2) })).suggested_replies,
    [],
  );
  assertEquals(
    parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: ["太短", validSuggestions[1], validSuggestions[2]] })).suggested_replies,
    [],
  );
  assertEquals(
    parseStoryTurnEnvelope(JSON.stringify({
      reply: "回覆",
      suggested_replies: [validSuggestions[0], validSuggestions[1], validSuggestions[2] + "補充超過字數上限的內容".repeat(8)],
    })).suggested_replies,
    [],
  );
  assertEquals(
    parseStoryTurnEnvelope(JSON.stringify({
      reply: "回覆",
      suggested_replies: [validSuggestions[0], "這是一段沒有旁白動作、只有對白而且字數足夠的玩家建議回覆內容。", validSuggestions[2]],
    })).suggested_replies,
    [],
  );
  assertEquals(
    parseStoryTurnEnvelope(JSON.stringify({
      reply: "回覆",
      suggested_replies: [validSuggestions[0], "*我看著你，稍微停頓了一下* ", validSuggestions[2]],
    })).suggested_replies,
    [],
  );
  assertEquals(
    parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggestedReplies: validSuggestions })).suggested_replies,
    validSuggestions,
  );
  assertEquals(
    parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggestions: [...validSuggestions, "第四個不顯示"] })).suggested_replies,
    validSuggestions,
  );
});


Deno.test("configured phone fields are returned in exact order with safe empty-state fallbacks", () => {
  const prompts = [
    "{CHAR}最近收到{USER}的訊息|只記錄真正收到的手機訊息",
    "角色衣著／姿勢|延續已知狀態",
    "玩家衣著／姿勢|只根據明確描述",
    "待辦事項|只列出尚未完成事項",
    "手機通知|依生活情境生成",
  ];
  const parsed = parseStoryTurnEnvelope(JSON.stringify({
    reply: "回覆",
    phone_events: [
      { event_type: "message", title: "Una的簡訊", body: "江大哥，今天工地順不順利？" },
      { event_type: "notification", title: "角色衣著", body: "休閒襯衫挽至前臂。" },
    ],
  }), { configuredPrompts: prompts, currentUserMessage: "今天工地順利嗎？", playerName: "Una", characterName: "江辰遠" });

  assertEquals(parsed.phone_events, [
    { event_type: "notification", title: "江辰遠最近收到Una的訊息", body: "目前沒有新的手機訊息" },
    { event_type: "notification", title: "角色衣著／姿勢", body: "休閒襯衫挽至前臂。" },
    { event_type: "notification", title: "玩家衣著／姿勢", body: "目前沒有足夠資訊" },
    { event_type: "notification", title: "待辦事項", body: "目前沒有待辦事項" },
    { event_type: "notification", title: "手機通知", body: "目前沒有足夠資訊" },
  ]);
});

Deno.test("unconfigured phone mode also blocks invented player-origin messages", () => {
  const parsed = parseStoryTurnEnvelope(JSON.stringify({
    reply: "回覆",
    phone_events: [
      { event_type: "message", title: "Una的簡訊", body: "江大哥，今天工地順不順利？" },
      { event_type: "message", title: "客戶訊息", body: "林小姐：想確認明天丈量的時間。" },
    ],
  }), { currentUserMessage: "今天工地順利嗎？", playerName: "Una" });
  assertEquals(parsed.phone_events, [
    { event_type: "message", title: "客戶訊息", body: "林小姐：想確認明天丈量的時間。" },
  ]);
});

Deno.test("NPC work messages are allowed, but player SMS requires an explicit phone-send action", () => {
  const prompts = ["最近收到的訊息|最近的手機訊息"];
  const npcMessage = JSON.stringify({
    reply: "回覆",
    phone_events: [{ event_type: "message", title: "客戶訊息", body: "林小姐：想確認明天現場丈量的時間。" }],
  });
  assertEquals(
    parseStoryTurnEnvelope(npcMessage, {
      configuredPrompts: prompts,
      currentUserMessage: "今天工地順利嗎？",
      playerName: "Una",
    }).phone_events,
    [{ event_type: "notification", title: "最近收到的訊息", body: "林小姐：想確認明天現場丈量的時間。" }],
  );

  const playerMessage = JSON.stringify({
    reply: "回覆",
    phone_events: [{ event_type: "message", title: "Una的簡訊", body: "江大哥，今天工地順不順利？" }],
  });
  assertEquals(
    parseStoryTurnEnvelope(playerMessage, {
      configuredPrompts: prompts,
      currentUserMessage: "我拿起手機傳 LINE 給江辰遠，問他今天工地順不順利。",
      playerName: "Una",
    }).phone_events,
    [{ event_type: "notification", title: "最近收到的訊息", body: "江大哥，今天工地順不順利？" }],
  );
});
