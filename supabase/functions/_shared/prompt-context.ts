import { capMemory, taipeiCurrentDate, type PromptVariableKey, type PromptVariableValues } from "./prompt-variables.ts";

type Row = Record<string, unknown>;
type MessageRow = Row & { id?: string; role?: string; content?: string; created_at?: string; turn_id?: string | null; speaker_type?: string; speaker_snapshot?: Row | null };

export type PromptContextInput = {
  profile?: Row | null;
  character?: Row | null;
  characterSnapshot?: Row | null;
  sessionData?: Row | null;
  messages?: MessageRow[];
  currentUserMessageId?: string;
  group?: (Row & { members?: Row[] }) | null;
  now?: Date;
};

const str = (value: unknown): string => typeof value === "string" ? value.trim() : value == null ? "" : (typeof value === "number" || typeof value === "boolean") ? String(value) : "";
const obj = (value: unknown): Row => value && typeof value === "object" && !Array.isArray(value) ? value as Row : {};
const snapshotOf = (member: Row): Row => obj(member.character_snapshot ?? member.characterSnapshot ?? member);
const playerMessage = (m: MessageRow): boolean => m.role === "user" || m.speaker_type === "player";

export function buildPromptVariableValues(input: PromptContextInput): PromptVariableValues {
  const profile = obj(input.profile);
  const character = Object.keys(obj(input.character)).length ? obj(input.character) : obj(input.characterSnapshot);
  const session = obj(input.sessionData);
  const group = obj(input.group);
  const messages = Array.isArray(input.messages) ? input.messages : [];
  const current = (input.currentUserMessageId && messages.find(m => m.id === input.currentUserMessageId)) || [...messages].reverse().find(playerMessage);
  const history = messages.filter(m => m.id !== current?.id).slice(-10).map(m => {
    const speaker = str(obj(m.speaker_snapshot).name) || (playerMessage(m) ? str(profile.nickname) || "玩家" : str(character.name) || "角色");
    const body = str(m.content);
    return body ? `${speaker}：${body}` : "";
  }).filter(Boolean).join("\n");
  const playerTurns = new Set<string>();
  let unkeyedTurns = 0;
  for (const m of messages) {
    if (!playerMessage(m)) continue;
    if (str(m.turn_id)) playerTurns.add(str(m.turn_id)); else unkeyedTurns++;
  }
  const members = Array.isArray(group.members) ? group.members.map(obj) : [];
  const memberNames = members.map(m => str(snapshotOf(m).name)).filter(Boolean);
  const activeId = str(character.id);
  const otherNames = members.filter(m => str(m.character_id ?? snapshotOf(m).id) !== activeId).map(m => str(snapshotOf(m).name)).filter(Boolean);
  const world = str(group.world_background ?? session.world_background ?? session.world ?? character.worldBackground);
  const memorySource = session.memories ?? session.memory;
  const memory = Array.isArray(memorySource) ? capMemory(memorySource.map(v => typeof v === "string" ? v : str(obj(v).summary ?? obj(v).content ?? obj(v).text)).filter(Boolean).join("\n")) : capMemory(memorySource);
  const values: PromptVariableValues = {
    USER: str(profile.nickname ?? profile.handle), CHAR: str(character.name),
    USER_DESC: str(profile.persona_description ?? profile.persona ?? profile.bio), CHAR_DESC: str(character.intro ?? character.description),
    USER_GENDER: str(profile.gender), USER_PRONOUN: str(profile.pronoun),
    WORLD: world, SETTING: str(session.setting ?? character.setting ?? world),
    SCENE: str(session.scene ?? group.scene ?? group.initial_scene),
    RELATIONSHIP: str(session.relationship ?? character.relationship), TIME: str(session.time), LOCATION: str(session.location),
    USER_MESSAGE: str(current?.content), CHAT_HISTORY: history, MEMORY: memory, SUMMARY: str(session.summary),
    TURN_COUNT: String(playerTurns.size + unkeyedTurns), CURRENT_DATE: taipeiCurrentDate(input.now),
    CHAR_LIST: memberNames.join("、"), ACTIVE_CHAR: str(character.name), OTHER_CHARS: otherNames.join("、"),
    GROUP_NAME: str(group.name), GROUP_WORLD: world, GROUP_SCENE: str(session.scene ?? group.scene ?? group.initial_scene),
  };
  return values;
}

export function applyPromptVariables(template: unknown, values: PromptVariableValues): string {
  const known = new Set<PromptVariableKey>(Object.keys(values) as PromptVariableKey[]);
  return String(template ?? "").replace(/\{([A-Z][A-Z0-9_]*)\}/g, (literal, key: string) => {
    if (!known.has(key as PromptVariableKey)) return literal;
    return values[key as PromptVariableKey] ?? "";
  });
}