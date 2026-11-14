import { assertEquals } from "jsr:@std/assert";
import { parseGroupSpeakerOutput } from "./group-speaker-output.ts";

const roster = [
  { id: "a", name: "夜辰", sceneId: "scene-1", sceneName: "共同場景" },
  { id: "b", name: "黎音", sceneId: "scene-1", sceneName: "共同場景" },
];

Deno.test("maps explicit Traditional Chinese speaker labels to the correct character IDs", () => {
  assertEquals(parseGroupSpeakerOutput(
    "夜辰：*抬眼看向你*\n妳終於回來了。\n\n黎音：我也一直在等你。",
    roster,
  ), [
    { speakerId: "a", speakerName: "夜辰", content: "*抬眼看向你*\n妳終於回來了。", sceneId: "scene-1", sceneName: "共同場景" },
    { speakerId: "b", speakerName: "黎音", content: "我也一直在等你。", sceneId: "scene-1", sceneName: "共同場景" },
  ]);
});

Deno.test("accepts ASCII colon and does not attribute unknown speaker labels", () => {
  assertEquals(parseGroupSpeakerOutput("夜辰:你好。\n陌生人：不應該被保存。\n黎音：我在。", roster).map(x => [x.speakerId, x.content]), [
    ["a", "你好。"],
    ["b", "我在。"],
  ]);
});

Deno.test("does not assign unlabeled output to a guessed character", () => {
  assertEquals(parseGroupSpeakerOutput("旁白：未知\n沒有標記的文字", roster), []);
});
