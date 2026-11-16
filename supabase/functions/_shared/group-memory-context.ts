export type GroupMemorySummaryRow = {
  batch_number?: number | string | null;
  summary?: unknown;
  important?: unknown;
  user_edited?: unknown;
};

const summaryText = (row: GroupMemorySummaryRow | null | undefined): string =>
  typeof row?.summary === "string" ? row.summary.trim() : "";

const batchNumber = (row: GroupMemorySummaryRow): number =>
  Number(row.batch_number);

export function buildGroupMemoryContext(
  sceneMode: string,
  latestSummary: GroupMemorySummaryRow | null,
  curatedSummaries: readonly GroupMemorySummaryRow[],
): string {
  // A group-wide summary has no per-scene visibility metadata. Never expose it
  // to separate-scene characters, whose prompt must remain scene-isolated.
  if (sceneMode !== "shared") return "";

  const latestText = summaryText(latestSummary);
  const latestBatch = latestSummary ? batchNumber(latestSummary) : Number.NaN;
  const curated = curatedSummaries
    .filter((item) => item.important === true || item.user_edited === true)
    .filter((item) => Number.isInteger(batchNumber(item)) && batchNumber(item) > 0 && batchNumber(item) !== latestBatch)
    .filter((item) => summaryText(item))
    .slice(0, 8);

  const sections: string[] = [];
  if (latestText) {
    sections.push("【長期群組記憶摘要】\n" + latestText);
  }
  if (curated.length) {
    sections.push(
      "【玩家珍藏／手動編輯的群組記憶】\n" +
      curated.map((item) => "第 " + batchNumber(item) + " 批：" + summaryText(item)).join("\n"),
    );
  }
  return sections.join("\n\n");
}

export function getGroupHistoryLimit(
  sceneMode: string,
  hasLatestSummary: boolean,
  lookupFailed: boolean,
): number {
  // Five group turns can contain up to twenty messages (one player message
  // plus up to three character speeches per turn). Keep a small safety margin.
  return sceneMode === "shared" && hasLatestSummary && !lookupFailed ? 24 : 40;
}
