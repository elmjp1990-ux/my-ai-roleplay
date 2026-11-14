export type GroupSpeaker = { id: string; name: string; sceneId?: string | null; sceneName?: string };
export type ParsedGroupSpeech = { speakerId: string; speakerName: string; content: string; sceneId: string | null; sceneName: string };

const normalizeName = (value: string): string =>
  value.normalize("NFKC").replace(/[\s　]+/g, "").trim();

const escapeRegExp = (value: string): string => value.replace(/[.*+?^()|[\]\\$]/g, "\\$&");

/**
 * Parses explicit "角色名稱：" lines into persisted per-character messages.
 * Unknown labels are never silently attributed to another character.
 */
export function parseGroupSpeakerOutput(output: unknown, speakers: GroupSpeaker[]): ParsedGroupSpeech[] {
  const text = typeof output === "string" ? output.trim() : "";
  if (!text || !Array.isArray(speakers) || speakers.length === 0) return [];

  const byNormalizedName = new Map<string, GroupSpeaker>();
  for (const speaker of speakers) {
    const name = typeof speaker.name === "string" ? speaker.name.trim() : "";
    if (!speaker.id || !name) continue;
    const key = normalizeName(name);
    if (key && !byNormalizedName.has(key)) byNormalizedName.set(key, speaker);
  }
  if (!byNormalizedName.size) return [];

  const names = [...byNormalizedName.values()]
    .sort((a, b) => b.name.length - a.name.length)
    .map(s => escapeRegExp(s.name));
  const labelPattern = new RegExp(
    "^\\s*(?:\\*\\*)?(" + names.join("|") + ")(?:\\*\\*)?\\s*[：:]\\s*(.*)$",
    "u",
  );

  const result: ParsedGroupSpeech[] = [];
  let current: ParsedGroupSpeech | null = null;
  const flush = () => {
    if (current?.content.trim()) result.push({ ...current, content: current.content.trim() });
    current = null;
  };

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) {
      if (current) current.content += "\n";
      continue;
    }
    const match = line.match(labelPattern);
    if (match) {
      flush();
      const speaker = byNormalizedName.get(normalizeName(match[1]));
      if (!speaker) continue;
      current = {
        speakerId: speaker.id,
        speakerName: speaker.name,
        content: match[2] || "",
        sceneId: speaker.sceneId ?? null,
        sceneName: speaker.sceneName ?? "",
      };
      continue;
    }
    if (/^\s*[^：:]{1,40}[：:]/u.test(line)) {\n      flush();\n      continue;\n    }\n    if (current) current.content += (current.content ? "\n" : "") + line;
  }
  flush();
  return result;
}
