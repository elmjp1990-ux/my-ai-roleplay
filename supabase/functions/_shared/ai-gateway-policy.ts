/** Vercel AI Gateway's documented Chat Completions request extension. */
export function buildGatewayProviderOptions() {
  return {
    gateway: {
      // Filter out providers without a Vercel no-prompt-training agreement.
      // Request-level ZDR is intentionally not enabled because it requires
      // an eligible Vercel plan and is a separate retention guarantee.
      disallowPromptTraining: true,
    },
  } as const;
}
