export const CHARACTER_PROFILE_MODEL = "deepseek/deepseek-v4-flash-20260423";

export type CharacterProfileSourcePayload = Record<string, unknown>;

const PROFILE_SECTIONS = [
  "identity_background",
  "core_personality",
  "inner_motivations",
  "emotional_response_patterns",
  "relationship_dynamics",
  "behavior_and_agency",
  "knowledge_boundaries",
  "appearance_markers",
] as const;

const ROOT_KEYS = [
  "schema_version",
  ...PROFILE_SECTIONS,
  "speech_style",
  "author_private_context",
  "ooc_rules",
  "unknowns",
  "source_conflicts",
] as const;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const nonEmpty = (value: unknown): value is string =>
  typeof value === "string" && value.trim().length > 0;

function validateEvidenceItems(
  items: unknown,
  sourceKeys: Set<string>,
  errors: string[],
  label: string,
): void {
  if (!Array.isArray(items)) {
    errors.push(label + "_not_array");
    return;
  }
  for (const item of items) {
    if (!isRecord(item) || !nonEmpty(item.content) ||
      !["author_explicit", "ai_inference"].includes(String(item.source_type)) ||
      !["high", "medium", "low"].includes(String(item.confidence)) ||
      !Array.isArray(item.source_refs) || item.source_refs.length < 1 ||
      !item.source_refs.every((ref) => nonEmpty(ref) && sourceKeys.has(ref))) {
      errors.push(label + "_invalid_evidence");
    }
  }
}

export function validateCharacterAiProfile(
  value: unknown,
  sourcePayload: CharacterProfileSourcePayload,
): { ok: boolean; errors: string[] } {
  const errors: string[] = [];
  if (!isRecord(value)) return { ok: false, errors: ["root_not_object"] };

  const actualKeys = Object.keys(value).sort();
  const expectedKeys = [...ROOT_KEYS].sort();
  if (actualKeys.length !== expectedKeys.length ||
    actualKeys.some((key, index) => key !== expectedKeys[index])) {
    errors.push("root_keys_mismatch");
  }
  if (value.schema_version !== "1.0") errors.push("schema_version_invalid");

  const sourceKeys = new Set(
    Object.entries(sourcePayload)
      .filter(([, content]) => content !== null && content !== "" &&
        !(Array.isArray(content) && content.length === 0))
      .map(([key]) => key),
  );

  for (const sectionName of PROFILE_SECTIONS) {
    const section = value[sectionName];
    if (!isRecord(section) ||
      !["populated", "not_provided", "conflict"].includes(String(section.status))) {
      errors.push(sectionName + "_invalid");
      continue;
    }
    const sectionItems = Array.isArray(section.items) ? section.items : [];
    validateEvidenceItems(sectionItems, sourceKeys, errors, sectionName);
    if (section.status === "not_provided" && sectionItems.length !== 0) {
      errors.push(sectionName + "_not_provided_has_items");
    }
    if (section.status === "populated" && sectionItems.length === 0) {
      errors.push(sectionName + "_populated_empty");
    }
  }

  const speech = value.speech_style;
  if (!isRecord(speech) ||
    !["populated", "not_provided", "conflict"].includes(String(speech.status)) ||
    !Array.isArray(speech.tendencies) ||
    !Array.isArray(speech.creator_defined_quirks) ||
    !Array.isArray(speech.example_lines) || speech.example_lines.length !== 0) {
    errors.push("speech_style_invalid");
  } else {
    validateEvidenceItems(speech.tendencies, sourceKeys, errors, "speech_tendencies");
    validateEvidenceItems(speech.creator_defined_quirks, sourceKeys, errors, "speech_quirks");
    for (const item of speech.creator_defined_quirks) {
      if (!isRecord(item) || item.source_type !== "author_explicit" ||
        !Array.isArray(item.source_refs) ||
        !item.source_refs.some((ref) => ref === "character_private_info.personality_profile.speechStyle")) {
        errors.push("speech_quirk_not_author_explicit");
      }
    }
  }

  const privateContext = value.author_private_context;
  if (!isRecord(privateContext) || privateContext.visibility !== "server_only" ||
    !["populated", "not_provided", "conflict"].includes(String(privateContext.status)) ||
    !Array.isArray(privateContext.items)) {
    errors.push("author_private_context_invalid");
  } else {
    const privateItems = privateContext.items;
    validateEvidenceItems(privateItems, sourceKeys, errors, "author_private_context");
    for (const item of privateItems) {
      if (!isRecord(item) || !Array.isArray(item.source_refs) ||
        !item.source_refs.every((ref) => typeof ref === "string" && ref.startsWith("character_private_info."))) {
        errors.push("author_private_context_source_not_private");
      }
    }
  }

  const ooc = value.ooc_rules;
  if (!isRecord(ooc) || !["ready", "insufficient_source"].includes(String(ooc.status)) ||
    !Array.isArray(ooc.rules) ||
    !(ooc.insufficient_source_reason === null || nonEmpty(ooc.insufficient_source_reason))) {
    errors.push("ooc_rules_invalid");
  } else {
    if (ooc.status === "ready" && (ooc.rules.length < 3 || ooc.insufficient_source_reason !== null)) {
      errors.push("ooc_ready_requires_three_rules");
    }
    if (ooc.status === "insufficient_source" &&
      (ooc.rules.length > 2 || !nonEmpty(ooc.insufficient_source_reason))) {
      errors.push("ooc_insufficient_source_invalid");
    }
    for (const rule of ooc.rules) {
      if (!isRecord(rule) || !nonEmpty(rule.rule) || !nonEmpty(rule.why_it_matters) ||
        !nonEmpty(rule.prohibited_deviation) || !nonEmpty(rule.allowed_growth) ||
        !Array.isArray(rule.source_refs) || rule.source_refs.length < 1 ||
        !rule.source_refs.every((ref) => nonEmpty(ref) && sourceKeys.has(ref))) {
        errors.push("ooc_rule_invalid_or_unsupported");
      }
    }
  }

  if (!Array.isArray(value.unknowns) || !value.unknowns.every(nonEmpty)) {
    errors.push("unknowns_invalid");
  }
  if (!Array.isArray(value.source_conflicts)) {
    errors.push("source_conflicts_invalid");
  } else {
    for (const conflict of value.source_conflicts) {
      if (!isRecord(conflict) || !nonEmpty(conflict.topic) ||
        !nonEmpty(conflict.description) ||
        conflict.resolution_status !== "needs_author_clarification" ||
        !Array.isArray(conflict.conflicting_source_refs) ||
        conflict.conflicting_source_refs.length < 2 ||
        !conflict.conflicting_source_refs.every((ref) => nonEmpty(ref) && sourceKeys.has(ref))) {
        errors.push("source_conflict_invalid");
      }
    }
  }

  return { ok: errors.length === 0, errors: [...new Set(errors)] };
}

export function buildCharacterProfileMessages(sourcePayload: CharacterProfileSourcePayload) {
  const system = [
    "你是 POYOZZ 的角色資料整理器。只輸出符合指定 JSON 結構的資料，不要 Markdown、程式碼區塊或額外文字。",
    "作者提供的原始資料是唯一權威來源。不可新增未提供的背景、創傷、秘密、能力、關係史、口頭禪或範例台詞。",
    "每個 evidence item 必須提供 source_refs，且只能引用輸入 JSON 中實際存在且有內容的欄位路徑。source_type 必須區分 author_explicit 與 ai_inference；推論不可偽裝成作者原文。",
    "缺少資料時標記 not_provided 並留空 items；來源矛盾時標記 conflict 並在 source_conflicts 列出所有衝突欄位，要求作者釐清，不可自行選邊。",
    "OOC 規則需至少三條且每條都要有來源依據；只有來源不足以支持三條實質規則時，才使用 insufficient_source，最多兩條，並說明原因。不可湊數。",
    "speech_style.creator_defined_quirks 只收錄作者明確寫出的固定慣用詞或口頭禪，必須引用 speechStyle 來源；作者未提供則空陣列。speech_style.example_lines 永遠是空陣列。",
    "author_private_context.visibility 必須是 server_only；只整理私密來源中明確存在的內容。此欄位永遠只供伺服器內部 prompt 使用。",
    "不整理手機設定、行程表、即時位置或即時狀態；它們每回合由對話程式另外載入。",
    "所有 section 都必須符合 schema：{status,items}。speech_style 必須有 {status,tendencies,creator_defined_quirks,example_lines}。",
    "輸出 root keys 必須完整且僅包含：schema_version, identity_background, core_personality, inner_motivations, emotional_response_patterns, relationship_dynamics, behavior_and_agency, knowledge_boundaries, speech_style, appearance_markers, author_private_context, ooc_rules, unknowns, source_conflicts。schema_version 固定 1.0。",
  ].join("\n");
  return [
    { role: "system", content: system },
    { role: "user", content: JSON.stringify({ source_payload: sourcePayload }) },
  ];
}
