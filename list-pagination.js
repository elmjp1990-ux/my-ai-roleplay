(() => {
  const PAGE_SIZES = Object.freeze({
    explore: 20,
    chatSessions: 10,
    groupSessions: 10,
    encounterMemories: 20,
    messages: 5
  });

  function createState(kind) {
    return {
      kind,
      pageSize: PAGE_SIZES[kind] || 10,
      offset: 0,
      hasMore: true,
      loading: false,
      legacyOffset: 0,
      legacyHasMore: true,
      buffer: [],
      observer: null
    };
  }

  function observeEnd(sentinel, onIntersect, options = {}) {
    if (!sentinel || typeof IntersectionObserver === 'undefined') return null;
    const observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) onIntersect();
    }, {
      root: options.root || null,
      rootMargin: options.rootMargin || '220px 0px',
      threshold: 0
    });
    observer.observe(sentinel);
    return observer;
  }

  function mergeUnique(existing, incoming, keyOf = item => item?.id) {
    const seen = new Set((existing || []).map(keyOf));
    return [...(existing || []), ...(incoming || []).filter(item => {
      const key = keyOf(item);
      if (key == null || seen.has(key)) return false;
      seen.add(key);
      return true;
    })];
  }

  window.PoyozzListPagination = Object.freeze({
    pageSize: kind => PAGE_SIZES[kind] || 10,
    createState,
    observeEnd,
    mergeUnique
  });
})();
