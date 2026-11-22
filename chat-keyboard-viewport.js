(() => {
  const root = document.documentElement;
  const viewport = window.visualViewport || null;
  let framePending = false;
  let observedEncounterComposer = null;
  let composerResizeObserver = null;
  let baselineViewportHeight = Math.max(
    Number(window.innerHeight) || 0,
    Number(root.clientHeight) || 0,
    Number(viewport?.height) || 0
  );

  const isChatComposer = element =>
    !!element?.matches?.('#messageInput, #groupMessageInput');

  const syncKeyboardState = () => {
    const layoutHeight = Math.max(
      Number(window.innerHeight) || 0,
      Number(root.clientHeight) || 0,
      baselineViewportHeight
    );
    const visibleHeight = Number(viewport?.height) || layoutHeight;
    const threshold = Math.max(120, baselineViewportHeight * 0.18);
    const keyboardOpen = isChatComposer(document.activeElement) &&
      (viewport ? baselineViewportHeight - visibleHeight > threshold : true);

    if (keyboardOpen) document.body.classList.add('chat-keyboard-open');
    else document.body.classList.remove('chat-keyboard-open');

    if (!keyboardOpen && visibleHeight >= baselineViewportHeight - threshold) {
      baselineViewportHeight = Math.max(
        Number(window.innerHeight) || 0,
        Number(root.clientHeight) || 0,
        visibleHeight
      );
    }
    return keyboardOpen;
  };

  const updateEncounterComposerHeight = () => {
    const composer = document.querySelector('.chat-main.encounter-scene .composer');
    if (composer !== observedEncounterComposer) {
      composerResizeObserver?.disconnect();
      observedEncounterComposer = composer;
      if (composer && typeof ResizeObserver === 'function') {
        composerResizeObserver = new ResizeObserver(() => {
          const height = Math.round(composer.getBoundingClientRect().height);
          if (height > 0) root.style.setProperty('--poyozz-encounter-composer-height', height + 'px');
        });
        composerResizeObserver.observe(composer);
      }
    }
    if (composer) {
      const height = Math.round(composer.getBoundingClientRect().height);
      if (height > 0) root.style.setProperty('--poyozz-encounter-composer-height', height + 'px');
    } else {
      root.style.removeProperty('--poyozz-encounter-composer-height');
    }
  };

  const updateViewportHeight = () => {
    const height = Math.round(Number(viewport?.height) || window.innerHeight || root.clientHeight);
    const top = Math.round(Number(viewport?.offsetTop) || 0);
    if (height > 0) root.style.setProperty('--poyozz-chat-viewport-height', height + 'px');
    root.style.setProperty('--poyozz-visual-viewport-top', top + 'px');
    updateEncounterComposerHeight();
    const keyboardOpen=syncKeyboardState();
    root.style.removeProperty('--encounter-keyboard-offset');
  };
  const scheduleViewportUpdate = () => {
    if (framePending) return;
    framePending = true;
    requestAnimationFrame(() => {
      framePending = false;
      updateViewportHeight();
    });
  };

  updateViewportHeight();
  window.addEventListener('resize', scheduleViewportUpdate, { passive: true });
  window.addEventListener('orientationchange', () => {
    baselineViewportHeight = Math.max(
      Number(window.innerHeight) || 0,
      Number(root.clientHeight) || 0,
      Number(viewport?.height) || 0
    );
    scheduleViewportUpdate();
  }, { passive: true });
  viewport?.addEventListener('resize', scheduleViewportUpdate, { passive: true });
  viewport?.addEventListener('scroll', scheduleViewportUpdate, { passive: true });

  document.addEventListener('focusin', event => {
    if (!isChatComposer(event.target)) return;
    updateViewportHeight();
    scheduleViewportUpdate();
    // Encounter scene art is anchored to the scene; never scroll the page or sprite
    // together with the composer when the software keyboard opens.
  });
  document.addEventListener('focusout', () => {
    requestAnimationFrame(() => {
      if (!isChatComposer(document.activeElement)) {
        document.body.classList.remove('chat-keyboard-open');
      }
      scheduleViewportUpdate();
    });
  });
})();
