import {
  validateCharacterAiProfile,
  type CharacterProfileSourcePayload,
} from "./character-profile-organization.ts";

const sourcePayload: CharacterProfileSourcePayload = {
  "characters.intro": "在台北工作的咖啡師，重視承諾。",
  "characters.race": "",
  "characters.style": "外冷內熱，說話直接。",
  "character_private_info.private_info": "不願提起過去的失敗。",
  "character_private_info.personality_profile.coreTraits": "慢熟、謹慎",
  "character_private_info.personality_profile.values": "重視承諾",
  "character_private_info.personality_profile.speechStyle": "簡短直接，沒有固定口頭禪",
  "character_private_info.personality_profile.behaviorRules": "不輕易信任陌生人",
  "character_private_info.personality_profile.likes": "手沖咖啡",
  "character_private_info.personality_profile.dislikes": "失約",
  "character_private_info.personality_profile.boundaries": "不接受欺騙",
  "character_private_info.personality_profile.relationshipPacing": "需要時間建立信任",
};

const emptySection = () => ({ status: "not_provided", items: [] });
const makeProfile = (): Record<string, unknown> => ({
  schema_version: "1.0",
  identity_background: emptySection(),
  core_personality: emptySection(),
  inner_motivations: emptySection(),
  emotional_response_patterns: emptySection(),
  relationship_dynamics: emptySection(),
  behavior_and_agency: emptySection(),
  knowledge_boundaries: emptySection(),
  appearance_markers: emptySection(),
  speech_style: {
    status: "not_provided",
    tendencies: [],
    creator_defined_quirks: [],
    example_lines: [],
  },
  author_private_context: {
    visibility: "server_only",
    status: "not_provided",
    items: [],
  },
  ooc_rules: {
    status: "insufficient_source",
    rules: [],
    insufficient_source_reason: "作者提供的來源不足以支持三條具體規則。",
  },
  unknowns: ["角色外觀未提供"],
  source_conflicts: [],
});

Deno.test("accepts a complete profile with evidence-backed three-rule OOC", () => {
  const profile = makeProfile();
  const item = (content: string, ref: string) => ({
    content, source_type: "author_explicit", source_refs: [ref], confidence: "high",
  });
  profile.identity_background = {
    status: "populated",
    items: [item("在台北工作的咖啡師。", "characters.intro")],
  };
  profile.core_personality = {
    status: "populated",
    items: [item("慢熟且謹慎。", "character_private_info.personality_profile.coreTraits")],
  };
  profile.speech_style = {
    status: "populated",
    tendencies: [item("表達簡短直接。", "character_private_info.personality_profile.speechStyle")],
    creator_defined_quirks: [],
    example_lines: [],
  };
  profile.author_private_context = {
    visibility: "server_only",
    status: "populated",
    items: [item("不願提起過去的失敗。", "character_private_info.private_info")],
  };
  profile.ooc_rules = {
    status: "ready",
    insufficient_source_reason: null,
    rules: [
      {
        rule: "對陌生人維持謹慎。",
        why_it_matters: "角色慢熟。",
        prohibited_deviation: "不可初次見面便完全信任。",
        allowed_growth: "可隨共同經歷逐漸建立信任。",
        source_refs: ["character_private_info.personality_profile.coreTraits"],
      },
      {
        rule: "重視承諾。",
        why_it_matters: "承諾是角色價值觀。",
        prohibited_deviation: "不可無故輕忽約定。",
        allowed_growth: "可在特殊情境下解釋並修正承諾。",
        source_refs: ["character_private_info.personality_profile.values"],
      },
      {
        rule: "不接受欺騙。",
        why_it_matters: "作者明確設定界線。",
        prohibited_deviation: "不可把欺騙描寫成毫無影響。",
        allowed_growth: "可透過坦承與補救逐步修復信任。",
        source_refs: ["character_private_info.personality_profile.boundaries"],
      },
    ],
  };
  const result = validateCharacterAiProfile(profile, sourcePayload);
  if (!result.ok) throw new Error(result.errors.join(","));
});

Deno.test("rejects source references invented by the model", () => {
  const profile = makeProfile();
  profile.core_personality = {
    status: "populated",
    items: [{
      content: "模型自行想像的創傷。",
      source_type: "ai_inference",
      source_refs: ["characters.secret_trauma"],
      confidence: "high",
    }],
  };
  const result = validateCharacterAiProfile(profile, sourcePayload);
  if (result.ok || !result.errors.includes("core_personality_invalid_evidence")) {
    throw new Error("invented source reference was not rejected");
  }
});

Deno.test("rejects generated example dialogue and fabricated catchphrases", () => {
  const profile = makeProfile();
  profile.speech_style = {
    status: "populated",
    tendencies: [],
    creator_defined_quirks: [{
      content: "作者沒有提供的口頭禪",
      source_type: "ai_inference",
      source_refs: ["character_private_info.personality_profile.speechStyle"],
      confidence: "high",
    }],
    example_lines: ["你好，很高興見到你。"],
  };
  const result = validateCharacterAiProfile(profile, sourcePayload);
  if (result.ok || !result.errors.includes("speech_style_invalid")) {
    throw new Error("generated sample dialogue was not rejected");
  }
});

Deno.test("rejects fewer than three OOC rules marked ready", () => {
  const profile = makeProfile();
  profile.ooc_rules = {
    status: "ready",
    insufficient_source_reason: null,
    rules: [],
  };
  const result = validateCharacterAiProfile(profile, sourcePayload);
  if (result.ok || !result.errors.includes("ooc_ready_requires_three_rules")) {
    throw new Error("incomplete ready OOC was not rejected");
  }
});

Deno.test("rejects private context sourced from public fields", () => {
  const profile = makeProfile();
  profile.author_private_context = {
    visibility: "server_only",
    status: "populated",
    items: [{
      content: "公用介紹被錯標為私密。",
      source_type: "author_explicit",
      source_refs: ["characters.intro"],
      confidence: "high",
    }],
  };
  const result = validateCharacterAiProfile(profile, sourcePayload);
  if (result.ok || !result.errors.includes("author_private_context_source_not_private")) {
    throw new Error("public source in private section was not rejected");
  }
});

Deno.test("rejects unexpected root and nested schema properties", () => {
  const profile = makeProfile();
  profile.unapproved_internal_field = "must not be persisted";
  const rootResult = validateCharacterAiProfile(profile, sourcePayload);
  if (rootResult.ok || !rootResult.errors.includes("root_keys_mismatch")) {
    throw new Error("unexpected root property was not rejected");
  }

  const nested = makeProfile();
  nested.core_personality = { status: "not_provided", items: [], unrecognized: true };
  const nestedResult = validateCharacterAiProfile(nested, sourcePayload);
  if (nestedResult.ok || !nestedResult.errors.includes("core_personality_invalid")) {
    throw new Error("unexpected nested property was not rejected");
  }
});
