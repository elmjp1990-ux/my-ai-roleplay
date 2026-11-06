import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseStoryTurnEnvelope } from "./story-turn-envelope.ts";

Deno.test("parses a valid reply and bounded side effects", () => {
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({
    reply: "*他微微一笑*你好。",
    affinity_delta: 2,
    affinity_reason: "角色感受到玩家的信任。",
    phone_events: [{ event_type: "message", title: "晚安", body: "今天聊得很開心。" }],
    suggested_replies: ["我看著你，想了想才慢慢開口，決定把心裡真正的疑問說出來，也想知道你會怎麼回答。",
      "我沒有立刻接話，而是先觀察你的表情，接著提出另一個想法，試著讓我們的談話繼續下去。",
      "我輕輕笑了笑，順著你的話題分享自己的經歷，再自然地問起你對這件事的看法。"],
  })), {
    reply: "*他微微一笑*你好。",
    affinity_delta: 2,
    affinity_reason: "角色感受到玩家的信任。",
    phone_events: [{ event_type: "message", title: "晚安", body: "今天聊得很開心。" }],
    suggested_replies: ["我看著你，想了想才慢慢開口，決定把心裡真正的疑問說出來，也想知道你會怎麼回答。",
      "我沒有立刻接話，而是先觀察你的表情，接著提出另一個想法，試著讓我們的談話繼續下去。",
      "我輕輕笑了笑，順著你的話題分享自己的經歷，再自然地問起你對這件事的看法。"],
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

Deno.test("phone events are limited to three and text is bounded", () => {
  const parsed = parseStoryTurnEnvelope(JSON.stringify({
    reply: "回覆",
    affinity_delta: -3,
    affinity_reason: "x".repeat(400),
    phone_events: Array.from({ length: 5 }, (_, index) => ({
      event_type: "notification",
      title: "事件" + index,
      body: "內文",
    })),
  }));
  assertEquals(parsed.affinity_delta, -3);
  assertEquals(parsed.affinity_reason.length, 280);
  assertEquals(parsed.phone_events.length, 3);
});


Deno.test("suggested replies preserve valid options and accept supported aliases", () => {
  const valid = ["我看著你，想了想才慢慢開口，決定把心裡真正的疑問說出來，也想知道你會怎麼回答。",
      "我沒有立刻接話，而是先觀察你的表情，接著提出另一個想法，試著讓我們的談話繼續下去。",
      "我輕輕笑了笑，順著你的話題分享自己的經歷，再自然地問起你對這件事的看法。"];
  const parsed = parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: valid }));
  assertEquals(parsed.suggested_replies, valid);
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: valid.slice(0, 2) })).suggested_replies, []);
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: ["太短", valid[1], valid[2]] })).suggested_replies, []);
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: [valid[0], valid[1], valid[2] + "補充超過字數上限的內容".repeat(8)] })).suggested_replies, valid.slice(0, 2));
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggested_replies: [valid[0], "太短", valid[2]] })).suggested_replies, [valid[0], valid[2]]);
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggestedReplies: valid })).suggested_replies, valid);
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({ reply: "回覆", suggestions: [...valid, "第四個不顯示，避免超過三個選項"] })).suggested_replies, valid);
});
