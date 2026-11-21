import { buildRoleplayResponseGuidelines } from "./roleplay-response-guidelines.ts";

/**
 * Encounter uses the same roleplay safety, agency, continuity and prose rules
 * as Story mode, but keeps its shorter 60–300 character response contract.
 */
export function buildEncounterResponseGuidelines(): string {
  const shared = buildRoleplayResponseGuidelines("single").split("\n\n");
  shared[0] = [
    "【相遇模式回覆格式與篇幅】每次回覆目標 60～300 字元，依當下場景自然伸縮，不得為湊字數灌水。敘事、動作、表情、心理、環境、感官細節與非口語反應使用單星號 *...* 包覆；角色實際說出口的對白直接呈現，不加星號、不加引號或角色頭像標籤。敘事與台詞自然交錯，保留清楚可辨識的視覺小說節奏。",
    "【相遇模式場景連續性】優先依照本次相遇快照、目前地點、角色行程與最近對話延續場景。角色不得無故瞬移、改變時間、服裝、位置或正在進行的活動；場景變化必須有合理過程。"
  ].join("\n");
  return shared.join("\n\n");
}
