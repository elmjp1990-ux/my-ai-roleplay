import type { AiProviderResult } from "./ai-provider-result.ts";

export type ProviderFailureAction = "retry_same_turn" | "refund" | "reconcile";

/**
 * Decide what is safe after a provider did not return usable text.
 * Only an explicit HTTP 429 is treated as a confirmed non-generation response.
 * Timeouts, retryable errors, and empty HTTP-200 output remain ambiguous:
 * do not refund or issue another billable generation request automatically.
 */
export function classifyProviderFailure(
  result: Extract<AiProviderResult, { kind: "provider_error" | "empty_output" }>,
  httpStatus: number,
): ProviderFailureAction {
  if (result.kind === "provider_error" && httpStatus === 429) {
    return "retry_same_turn";
  }

  if (result.kind === "empty_output") {
    return "reconcile";
  }

  if (result.retryable) {
    return "reconcile";
  }

  if (httpStatus >= 400 && httpStatus < 500) {
    return "refund";
  }

  return "reconcile";
}
