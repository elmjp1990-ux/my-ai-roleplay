(function installPoyozzSignedUrlManager(global) {
  'use strict';

  function create(options = {}) {
    const createSignedUrl = options.createSignedUrl;
    if (typeof createSignedUrl !== 'function') {
      throw new TypeError('createSignedUrl must be a function');
    }
    const cache = new Map();
    const inflight = new Map();
    const forcedInflight = new Map();
    const cacheTtlMs = Math.max(0, Number(options.cacheTtlMs) || 0);
    const refreshSkewMs = Math.max(0, Number(options.refreshSkewMs) || 0);
    const maxEntries = Math.max(0, Number(options.maxEntries) || 0);
    const isCurrent = typeof options.isCurrent === 'function' ? options.isCurrent : () => true;

    function remember(key, url) {
      if (!cacheTtlMs || !url) return;
      cache.delete(key);
      cache.set(key, { url, expiresAt: Date.now() + cacheTtlMs });
      if (maxEntries > 0) {
        while (cache.size > maxEntries) cache.delete(cache.keys().next().value);
      }
    }

    async function get(key, requestOptions = {}) {
      if (key == null || key === '') return null;
      const forceRefresh = requestOptions.forceRefresh === true;
      const context = requestOptions.context;
      if (forceRefresh) {
        const forced = forcedInflight.get(key);
        if (forced) return forced;
        cache.delete(key);
        // A forced request supersedes a possibly expired normal request.
        // Identity checks below prevent that older request from repopulating cache.
        inflight.delete(key);
      } else {
        const cached = cache.get(key);
        if (cached && cached.expiresAt > Date.now() + refreshSkewMs) return cached.url;
        if (inflight.has(key)) return inflight.get(key);
      }

      const request = (async () => {
        const url = await createSignedUrl(key, context);
        if (!isCurrent(context)) return null;
        if (inflight.get(key) === request) remember(key, url);
        return url || null;
      })();
      inflight.set(key, request);
      if (forceRefresh) forcedInflight.set(key, request);
      try {
        return await request;
      } finally {
        if (inflight.get(key) === request) inflight.delete(key);
        if (forcedInflight.get(key) === request) forcedInflight.delete(key);
      }
    }

    function invalidate(key) {
      if (key != null && key !== '') cache.delete(key);
    }

    function clear() {
      cache.clear();
    }

    return Object.freeze({ get, invalidate, clear });
  }

  global.PoyozzSignedUrlManager = Object.freeze({ create });
})(window);
