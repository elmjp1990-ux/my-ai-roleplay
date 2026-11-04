/** OpenRouter routing policy for POYOZZ's approved no-training providers. */
export const APPROVED_OPENROUTER_PROVIDERS = ["deepinfra", "inference-net"] as const;

/**
 * Restrict each request to providers currently labeled by OpenRouter as
 * non-training. No provider outside this allowlist may receive player content.
 * Fallbacks are disabled so an outage fails closed and follows the existing
 * refund/reconciliation state machine instead of widening the privacy boundary.
 *
 * Provider policy labels are operational metadata, not a substitute for
 * reviewing the providers' current contractual terms.
 */
export function buildOpenRouterProviderOptions() {
  return {
    only: [...APPROVED_OPENROUTER_PROVIDERS],
    allow_fallbacks: false,
  } as const;
}
