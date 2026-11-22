import { handleEncounterScheduleOrganizer } from "./encounter-schedule-organizer-handler.ts";

const userId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const characterId = "11111111-1111-4111-8111-111111111111";
const batchId = "22222222-2222-4222-8222-222222222222";
const leaseToken = "test-lease-token";
const source = {
  character_id: characterId, author_id: userId, visibility: "public", review_status: "approved",
  rights_confirmed: true, deleted_at: null, name: "測試角色", intro: "現代城市生活",
  world_era: "modern", modern_setting_compatible: true, time_travel_explicit: false,
  schedule_description: "白天在公司工作，晚上和朋友見面",
  private_info: "", personality_profile: { tone: "溫柔" },
};
const option = (weight: number, activity: string) => ({
  weight, location: "公司", activity, is_outdoor: false,
  rain_fallback_location: null, rain_fallback_activity: null,
});
const day = () => Array.from({ length: 24 }, (_, hour) => ({
  start_time: String(hour).padStart(2, "0") + ":00",
  end_time: String((hour + 1) % 24).padStart(2, "0") + ":00",
  options: [
    option(60, "在辦公室整理今天的工作資料"),
    option(40, "在辦公室檢查待辦並回覆客戶訊息"),
  ],
}));
const validOutput = JSON.stringify({
  characters: [{
    character_id: characterId, placement: "modern_map",
    variants: { weekday: day(), holiday: day() },
  }],
  scenes: [],
});

function createMock(mode: "success" | "publish_error" | "invalid_ai_output" = "success") {
  const calls = { provider: 0, claim: 0, publish: 0, usage: 0, output: 0 };
  const admin = {
    from(table: string) {
      let action = "select";
      let payload: any;
      const filters: Array<[string, unknown]> = [];
      const query: any = {
        select(_columns?: string, options?: any) { action = options?.head ? "count" : action; return query; },
        insert(value: any) { action = "insert"; payload = value; return query; },
        update(value: any) { action = "update"; payload = value; return query; },
        eq(column: string, value: unknown) { filters.push([column, value]); return query; }, is(column: string, value: unknown) { filters.push([column, value]); return query; }, gt() { return query; },
        in() { return query; }, order() { return query; }, limit() { return query; },
        not() { return query; },
        async maybeSingle() {
          if (table === "encounter_schedule_generation_jobs") return { data: { source_hash: "test-source-hash" }, error: null };
          return { data: null, error: null };
        },
        async single() {
          if (table === "encounter_schedule_generation_outputs") { calls.output++; return { data: { id: "33333333-3333-4333-8333-333333333333" }, error: null }; }
          return { data: { id: "test-id" }, error: null };
        },
        then(resolve: any, reject: any) {
          let result: any = { data: null, error: null, count: 0 };
          if (table === "encounter_schedule_generation_jobs" && action === "count") {
            const status = filters.find(([column]) => column === "status")?.[1];
            const pendingQuery = status === "pending";
            result.count = pendingQuery ? 1 : 0;
          }
          if (table === "encounter_schedule_generation_usage" && action === "insert") calls.usage++;
          return Promise.resolve(result).then(resolve, reject);
        },
      };
      return query;
    },
    async rpc(name: string) {
      if (name === "claim_encounter_schedule_batch") {
        calls.claim++;
        return { data: { status: "claimed", batch_id: batchId, lease_token: leaseToken, characters: [source] }, error: null };
      }
      if (name === "get_character_ai_profile_for_chat") return { data: {}, error: null };
      if (name === "get_encounter_scene_catalog") return { data: [], error: null };
      if (name === "publish_encounter_schedule_batch") {
        calls.publish++;
        return mode === "publish_error"
          ? { data: null, error: { message: "mock_publish_failure" } }
          : { data: { status: "completed", published_character_count: 1, unplaced_character_count: 0 }, error: null };
      }
      if (name === "fail_encounter_schedule_batch") return { data: true, error: null };
      throw new Error("Unexpected RPC: " + name);
    },
  };
  const factory = (_url: string, key: string) => key === "anon-key"
    ? { auth: { getUser: async () => ({ data: { user: { id: userId } }, error: null }) } }
    : admin;
  const envValues: Record<string, string> = {
    SUPABASE_URL: "https://mock.supabase.co", SUPABASE_ANON_KEY: "anon-key",
    SUPABASE_SERVICE_ROLE_KEY: "service-key", OPENROUTER_API_KEY: "mock-openrouter-key",
    ENCOUNTER_SCHEDULE_TEST_MODE: "true",
  };
  const env = { get: (key: string) => envValues[key] };
  const dependencies = {
    requestOpenRouterChatCompletion: async () => {
      calls.provider++;
      return {
        result: { kind: "generated" as const, text: mode === "invalid_ai_output" ? "{invalid-json" : validOutput },
        provider: "mock", model: "mock-model", usage: {}, httpStatus: 200,
        responseContentType: "application/json", responseBodyLength: validOutput.length,
        responseParsed: true, rawOutputText: validOutput, rawResponseBody: "",
        requestId: "mock-request", finishReason: "stop", durationMs: 1,
      } as any;
    },
    recordAiGenerationDiagnostic: async () => "mock-diagnostic-id",
    updateAiGenerationDiagnostic: async () => {},
  };
  return { calls, factory, env, dependencies };
}

async function invoke(mock: ReturnType<typeof createMock>, authorization = "Bearer user-token") {
  return await handleEncounterScheduleOrganizer(
    new Request("https://preview.example/api/encounter-schedule-organizer", {
      method: "POST",
      headers: { Authorization: authorization, "Content-Type": "application/json" },
      body: JSON.stringify({ mode: "manual" }),
    }),
    mock.env, mock.factory as any, 270_000, mock.dependencies as any,
  );
}

Deno.test("manual POST mock executes authenticated AI-to-publish happy path without network", async () => {
  const mock = createMock();
  const response = await invoke(mock);
  const body = await response.json();
  if (response.status !== 200 || body.status !== "completed" || body.published_character_count !== 1) {
    throw new Error("Expected completed publish response, got " + JSON.stringify({ status: response.status, body }));
  }
  if (mock.calls.provider !== 1 || mock.calls.claim !== 1 || mock.calls.publish !== 1) {
    throw new Error("Expected one mocked provider, claim, and publish call: " + JSON.stringify(mock.calls));
  }
  if (mock.calls.output !== 1 || mock.calls.usage !== 1) {
    throw new Error("Expected raw output and usage audit persistence: " + JSON.stringify(mock.calls));
  }
});

Deno.test("manual POST rejects unauthenticated users before claiming or calling AI", async () => {
  const mock = createMock();
  const badFactory = (_url: string, key: string) => key === "anon-key"
    ? { auth: { getUser: async () => ({ data: { user: null }, error: { message: "invalid_token" } }) } }
    : mock.factory(_url, key);
  const response = await handleEncounterScheduleOrganizer(
    new Request("https://preview.example/api/encounter-schedule-organizer", {
      method: "POST", headers: { Authorization: "Bearer invalid", "Content-Type": "application/json" },
      body: JSON.stringify({ mode: "manual" }),
    }),
    mock.env, badFactory as any, 270_000, mock.dependencies as any,
  );
  if (response.status !== 401 || mock.calls.provider !== 0 || mock.calls.claim !== 0) {
    throw new Error("Unauthenticated request crossed the auth boundary");
  }
});

Deno.test("manual POST does not report success when schedule publication fails", async () => {
  const mock = createMock("publish_error");
  const response = await invoke(mock);
  const body = await response.json();
  if (body.status === "completed" || body.published_character_count !== 0 || mock.calls.publish !== 1) {
    throw new Error("Publish failure was incorrectly reported as success: " + JSON.stringify(body));
  }
});


Deno.test("manual POST rejects malformed mocked AI JSON before publishing", async () => {
  const mock = createMock("invalid_ai_output");
  const response = await invoke(mock);
  const body = await response.json();
  if (body.status === "completed" || mock.calls.publish !== 0 || mock.calls.provider !== 1) {
    throw new Error("Malformed AI output reached schedule publication: " + JSON.stringify({ body, calls: mock.calls }));
  }
});
