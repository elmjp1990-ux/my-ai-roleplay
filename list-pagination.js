(() => {
  const PAGE_SIZES = Object.freeze({
    explore: 20,
    authorCharacters: 10,
    chatSessions: 10,
    groupSessions: 10,
    followedAuthors: 10,
    encounterMemories: 10,
    messages: 5,
    citySceneCharacters: 10,
    chatSearch: 10,
    groupCharacterPicker: 10,
    ownedCharacters: 10,
    favorites: 10,
    notifications: 10,
    characterComments: 10,
    memoryPhotos: 10
  });
  const activeStates = new Set();
  const activeObservers = new Set();
  let activeScope = '';

  function createState(kind, initial = {}) {
    let requestId = 0;
    const state = {
      kind,
      pageSize: PAGE_SIZES[kind] || 10,
      offset: 0,
      hasMore: true,
      loading: false,
      observer: null,
      ...initial,
      beginRequest() {
        activeStates.add(state);
        state.loading = true;
        return ++requestId;
      },
      isRequestCurrent(id) {
        return requestId === id;
      },
      invalidate() {
        requestId += 1;
        state.loading = false;
        state.observer?.disconnect();
        state.observer = null;
      },
      dispose() {
        state.invalidate();
        activeStates.delete(state);
      }
    };
    activeStates.add(state);
    return state;
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
    const disconnect = observer.disconnect.bind(observer);
    observer.disconnect = () => {
      disconnect();
      activeObservers.delete(observer);
    };
    activeObservers.add(observer);
    observer.observe(sentinel);
    return observer;
  }

  function beginScope(scope) {
    const nextScope = String(scope || '');
    if (nextScope === activeScope) return false;
    activeScope = nextScope;
    for (const observer of activeObservers) observer.disconnect();
    activeObservers.clear();
    for (const state of activeStates) state.invalidate();
    activeStates.clear();
    return true;
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
    beginScope,
    mergeUnique
  });
})();
