// ayeT-Studios rewarded-video callback — NON-FUNCTIONAL SAFE SCAFFOLD
// Intentionally fails closed. Do not deploy or configure as a production callback
// until the exact ayeT-Studios signature canonicalization and payload contract
// have been confirmed from the provider's current official documentation.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

serve((_req) => {
  return new Response(
    JSON.stringify({
      error: "callback_not_configured",
      message: "Reward callback is not implemented; no reward was issued.",
    }),
    {
      status: 501,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
      },
    },
  );
});
