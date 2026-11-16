(function installPoyozzSignedUrlManager(global) {
  'use strict';

  function create(options = {}) {
    const createSignedUrl = options.createSignedUrl;
    const createSignedUrls = options.createSignedUrls;
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

    async function getMany(keys, requestOptions = {}) {
      const requested = Array.isArray(keys) ? keys.filter(key => key != null && key !== '') : [];
      if (!createSignedUrls) return Promise.all(requested.map(key => get(key, requestOptions)));
      const unique = [...new Set(requested)];
      const requests = new Map();
      const missing = [];
      const forceRefresh = requestOptions.forceRefresh === true;
      const context = requestOptions.context;
      for (const key of unique) {
        if (forceRefresh) {
          const forced = forcedInflight.get(key);
          if (forced) { requests.set(key, forced); continue; }
          cache.delete(key);
          inflight.delete(key);
        } else {
          const cached = cache.get(key);
          if (cached && cached.expiresAt > Date.now() + refreshSkewMs) {
            requests.set(key, Promise.resolve(cached.url));
            continue;
          }
          if (inflight.has(key)) { requests.set(key, inflight.get(key)); continue; }
        }
        missing.push(key);
      }
      if (missing.length) {
        const batch = Promise.resolve().then(() => createSignedUrls(missing, context));
        for (const key of missing) {
          let request;
          request = batch.then(result => {
            const url = result instanceof Map ? result.get(key) : result?.[key];
            if (!isCurrent(context)) return null;
            if (inflight.get(key) === request) remember(key, url);
            return url || null;
          }).finally(() => {
            if (inflight.get(key) === request) inflight.delete(key);
            if (forcedInflight.get(key) === request) forcedInflight.delete(key);
          });
          inflight.set(key, request);
          if (forceRefresh) forcedInflight.set(key, request);
          requests.set(key, request);
        }
      }
      return Promise.all(requested.map(key => requests.get(key) || null));
    }

    function invalidate(key) {
      if (key != null && key !== '') cache.delete(key);
    }

    function clear() {
      cache.clear();
    }

    return Object.freeze({ get, getMany, invalidate, clear });
  }

  global.PoyozzSignedUrlManager = Object.freeze({ create });
})(window);
