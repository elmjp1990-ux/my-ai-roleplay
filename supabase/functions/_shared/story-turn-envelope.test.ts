import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseStoryTurnEnvelope } from "./story-turn-envelope.ts";

Deno.test("parses a valid reply and bounded side effects", () => {
  assertEquals(parseStoryTurnEnvelope(JSON.stringify({
    reply: "*他微微一笑*你好。",
    affinity_delta: 2,
    affinity_reason: "角色感受到玩家的信任。",
    phone_events: [{ event_type: "message", title: "晚安", body: "今天聊得很開心。" }],
  })), {
    reply: "*他微微一笑*你好。",
    affinity_delta: 2,
    affinity_reason: "角色感受到玩家的信任。",
    phone_events: [{ event_type: "message", title: "晚安", body: "今天聊得很開心。" }],
  });
});

Deno.test("legacy plain text remains a reply without inferred effects", () => {
  assertEquals(parseStoryTurnEnvelope("自然的角色回覆"), {
    reply: "自然的角色回覆",
    affinity_delta: 0,
    affinity_reason: "",
    phone_events: [],
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
