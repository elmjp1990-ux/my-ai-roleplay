// Shared character AI-profile formatting used by single and group chat.
type DbRow = Record<string, unknown>;
const asDbRow = (value: unknown): DbRow =>
  value && typeof value === "object" && !Array.isArray(value) ? value as DbRow : {};
const asString = (value: unknown): string =>
  typeof value === "string" ? value.trim() : "";

const collectDerivedPrivateProfileValues = (value: unknown): string[] => {
  const profile = asDbRow(value);
  const protectedValues = new Set<string>();
  const collectItems = (items: unknown) => {
    if (!Array.isArray(items)) return;
    for (const item of items) {
      const entry = asDbRow(item);
      const refs = Array.isArray(entry.source_refs) ? entry.source_refs : [];
      const content = asString(entry.content);
      if (content && refs.some((ref) => typeof ref === "string" && ref.startsWith("character_private_info."))) {
        protectedValues.add(content);
      }
    }
  };
  for (const key of [
    "identity_background", "core_personality", "inner_motivations",
    "emotional_response_patterns", "relationship_dynamics",
    "behavior_and_agency", "knowledge_boundaries", "appearance_markers",
  ]) collectItems(asDbRow(profile[key]).items);
  const speech = asDbRow(profile.speech_style);
  collectItems(speech.tendencies);
  collectItems(speech.creator_defined_quirks);
  collectItems(asDbRow(profile.author_private_context).items);
  const ooc = asDbRow(profile.ooc_rules);
  if (Array.isArray(ooc.rules)) {
    for (const item of ooc.rules) {
      const rule = asDbRow(item);
      const refs = Array.isArray(rule.source_refs) ? rule.source_refs : [];
      if (refs.some((ref) => typeof ref === "string" && ref.startsWith("character_private_info."))) {
        for (const key of ["rule", "why_it_matters", "prohibited_deviation", "allowed_growth"]) {
          const content = asString(rule[key]);
          if (content) protectedValues.add(content);
        }
      }
    }
  }
  if (Array.isArray(profile.source_conflicts)) {
    for (const item of profile.source_conflicts) {
      const conflict = asDbRow(item);
      const refs = Array.isArray(conflict.conflicting_source_refs) ? conflict.conflicting_source_refs : [];
      if (refs.some((ref) => typeof ref === "string" && ref.startsWith("character_private_info."))) {
        for (const key of ["topic", "description"]) {
          const content = asString(conflict[key]);
          if (content) protectedValues.add(content);
        }
      }
    }
  }
  return [...protectedValues].slice(0, 120);
};

const formatCharacterAiProfilePrompt = (value: unknown): string => {
  const profile = asDbRow(value);
  const sectionLabels: Record<string, string> = {
    identity_background: "身份與背景",
    core_personality: "核心人格與價值觀",
    inner_motivations: "內在動機與目標",
    emotional_response_patterns: "情緒反應模式",
    relationship_dynamics: "關係發展邏輯",
    behavior_and_agency: "行為模式與自主性",
    knowledge_boundaries: "知識範圍與記憶邊界",
    appearance_markers: "外觀辨識特徵",
  };
  const lines: string[] = [];
  for (const [key, label] of Object.entries(sectionLabels)) {
    const section = asDbRow(profile[key]);
    const items = Array.isArray(section.items) ? section.items : [];
    for (const item of items) {
      const entry = asDbRow(item);
      const content = asString(entry.content);
      if (content) lines.push(`[${label}/${entry.source_type === "ai_inference" ? "AI歸納" : "作者設定"}] ${content}`);
    }
  }
  const speech = asDbRow(profile.speech_style);
  for (const item of Array.isArray(speech.tendencies) ? speech.tendencies : []) {
    const content = asString(asDbRow(item).content);
    if (content) lines.push("[說話風格] " + content);
  }
  for (const item of Array.isArray(speech.creator_defined_quirks) ? speech.creator_defined_quirks : []) {
    const content = asString(asDbRow(item).content);
    if (content) lines.push("[作者明確提供的固定慣用詞] " + content);
  }
  const ooc = asDbRow(profile.ooc_rules);
  for (const item of Array.isArray(ooc.rules) ? ooc.rules : []) {
    const rule = asDbRow(item);
    if (asString(rule.rule)) {
      lines.push("[OOC防崩規則] " + asString(rule.rule) +
        "；避免：" + asString(rule.prohibited_deviation) +
        "；允許自然成長：" + asString(rule.allowed_growth));
    }
  }
  // This section is server-only and is inserted only into the server-built system prompt.
  const privateContext = asDbRow(profile.author_private_context);
  for (const item of Array.isArray(privateContext.items) ? privateContext.items : []) {
    const content = asString(asDbRow(item).content);
    if (content) lines.push("[作者私密補充/僅供角色理解] " + content);
  }
  for (const unknown of Array.isArray(profile.unknowns) ? profile.unknowns : []) {
    if (asString(unknown)) lines.push("[作者未提供/未知] " + asString(unknown));
  }
  for (const conflict of Array.isArray(profile.source_conflicts) ? profile.source_conflicts : []) {
    const entry = asDbRow(conflict);
    if (asString(entry.description)) lines.push("[作者設定衝突/不可自行裁決] " + asString(entry.description));
  }
  if (ooc.status === "insufficient_source" && asString(ooc.insufficient_source_reason)) {
    lines.push("[OOC資料不足] " + asString(ooc.insufficient_source_reason));
  }
  return lines.join("\n").slice(0, 6000);
};
