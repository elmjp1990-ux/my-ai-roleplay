export type FetchLike = typeof fetch;

/**
 * Bound Auth Admin HTTP requests so an invocation cannot wait indefinitely
 * while holding a database lease. Non-Auth requests retain the caller's
 * original fetch behavior.
 */
export function createAuthAdminTimeoutFetch(
  fetchImpl: FetchLike = fetch,
  timeoutMs = 60_000,
): FetchLike {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) {
    throw new RangeError("auth_admin_timeout_must_be_positive_integer");
  }

  return (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const requestUrl = input instanceof Request
      ? input.url
      : input instanceof URL
      ? input.href
      : input;
    const pathname = new URL(requestUrl).pathname;

    if (!pathname.startsWith("/auth/v1/admin/users/")) {
      return await fetchImpl(input, init);
    }

    const requestSignal = init?.signal ??
      (input instanceof Request ? input.signal : null);
    const timeoutSignal = AbortSignal.timeout(timeoutMs);
    const signal = requestSignal
      ? AbortSignal.any([requestSignal, timeoutSignal])
      : timeoutSignal;

    return await fetchImpl(input, { ...init, signal });
  }) as FetchLike;
}
