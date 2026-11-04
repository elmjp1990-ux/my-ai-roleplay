(function (root, factory) {
  const api = factory();
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  root.POYOZZMemoryCapture = api;
})(globalThis, function () {
  const takeCodePoints = (value, limit) => Array.from(String(value ?? "")).slice(0, limit).join("");

  /**
   * Build one deterministic five-player-turn memory excerpt.
   * Player-authored text is the primary record; assistant text is only context.
   * Called only after a newly persisted assistant reply has been added.
   */
  function buildPlayerMemoryExcerpt(messages, characterName = "角色") {
    const rows = Array.isArray(messages) ? messages : [];
    const users = rows.filter((message) => message && message.role === "user");
    if (!users.length || users.length % 5 !== 0) return "";

    const playerBatch = users.slice(-5);
    const firstIndex = rows.findIndex((message) => message?.id === playerBatch[0]?.id);
    const lastIndex = rows.findIndex((message) => message?.id === playerBatch[playerBatch.length - 1]?.id);
    const nextAssistantIndex = lastIndex >= 0
      ? rows.findIndex((message, index) => index > lastIndex && message?.role === "assistant")
      : -1;
    const dialogueEnd = nextAssistantIndex >= 0 ? nextAssistantIndex : lastIndex;
    const dialogue = firstIndex >= 0 && lastIndex >= firstIndex
      ? rows.slice(firstIndex, dialogueEnd + 1)
      : playerBatch;

    const playerText = playerBatch.map((message, index) =>
      "玩家原話 " + (index + 1) + "：" + takeCodePoints(String(message.text || "").trim(), 480)
    ).join("\n");
    const name = String(characterName || "角色").trim() || "角色";
    const assistantText = dialogue.filter((message) => message?.role === "assistant").slice(-5)
      .map((message) => name + "回應：" + String(message.text || "").trim()).join("\n");
    const playerBlock = takeCodePoints(playerText, 2500);
    const assistantBlock = takeCodePoints(assistantText, 420);
    const memoryText = "【玩家原話優先保存】\n" + playerBlock +
      (assistantBlock ? "\n\n【角色回應脈絡】\n" + assistantBlock : "");
    return takeCodePoints(memoryText, 3000).trim();
  }

  function appendMemoryWithLimit(existing, item, maxLength = 10000) {
    const current = Array.isArray(existing) ? existing : [];
    const next = [...current, item];
    const size = (items) => items.reduce((total, memory) =>
      total + Array.from(String(memory?.text ?? "")).length, 0);
    const limit = Math.max(0, Number(maxLength) || 0);
    while (size(next) > limit) {
      const index = next.findIndex((memory) => !memory?.important);
      if (index < 0 || next[index]?.id === item?.id) {
        return { added: false, memories: current };
      }
      next.splice(index, 1);
    }
    return { added: true, memories: next };
  }

  function createSerialQueue() {
    const tails = new Map();
    return async function enqueue(key, operation) {
      const queueKey = String(key ?? "");
      const previous = tails.get(queueKey) || Promise.resolve();
      let release;
      const gate = new Promise((resolve) => { release = resolve; });
      tails.set(queueKey, gate);
      await previous;
      try {
        return await operation();
      } finally {
        release();
        if (tails.get(queueKey) === gate) tails.delete(queueKey);
      }
    };
  }

  function createMutationVersionTracker() {
    const versions = new WeakMap();
    return {
      next(target) {
        if (!target || (typeof target !== "object" && typeof target !== "function")) return 0;
        const version = (versions.get(target) || 0) + 1;
        versions.set(target, version);
        return version;
      },
      isCurrent(target, version) {
        return !!target && versions.get(target) === version;
      },
    };
  }

  return { buildPlayerMemoryExcerpt, appendMemoryWithLimit, createSerialQueue, createMutationVersionTracker };
});
