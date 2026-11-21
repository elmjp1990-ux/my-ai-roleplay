/** OpenRouter routing policy for POYOZZ's approved no-training providers. */
export const APPROVED_OPENROUTER_PROVIDERS = ["deepinfra", "inference-net"] as const;

/**
 * Restrict each request to the two approved providers whose policies prohibit
 * model training. Their permitted, time-limited operational retention is
 * accepted; no provider outside this allowlist may receive player content.
 * Fallbacks are disabled so only the application-controlled retry can switch
 * between these two providers.
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
    data_collection: "allow",
  } as const;
}
