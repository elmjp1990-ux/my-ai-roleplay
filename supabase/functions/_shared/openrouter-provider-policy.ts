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
export type ApprovedOpenRouterProvider = typeof APPROVED_OPENROUTER_PROVIDERS[number];

/**
 * Pin each individual attempt to one approved provider. The application owns
 * the retry order, so OpenRouter must not silently route to another provider.
 */
export function buildOpenRouterProviderOptions(provider: ApprovedOpenRouterProvider = "deepinfra") {
  return {
    only: [provider],
    allow_fallbacks: false,
    data_collection: "deny",
  } as const;
}
