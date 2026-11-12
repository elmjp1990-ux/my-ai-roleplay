(function installPoyozzChatRenderLifecycle(global) {
  'use strict';

  if (global.PoyozzChatRenderLifecycle) return;

  const hooks = new Map();
  let nextOrder = 0;

  function getEntries(phase) {
    return [...(hooks.get(phase)?.values() || [])].sort((a, b) =>
      b.priority - a.priority || a.order - b.order
    );
  }

  function register(phase, key, handler, options = {}) {
    if (typeof phase !== 'string' || !phase.trim()) {
      throw new TypeError('A render lifecycle phase is required.');
    }
    if (typeof key !== 'string' || !key.trim()) {
      throw new TypeError('A stable render lifecycle key is required.');
    }
    if (typeof handler !== 'function') {
      throw new TypeError('A render lifecycle handler must be a function.');
    }

    let phaseHooks = hooks.get(phase);
    if (!phaseHooks) {
      phaseHooks = new Map();
      hooks.set(phase, phaseHooks);
    }

    if (phaseHooks.has(key)) {
      return Object.freeze({ registered: false, unsubscribe: function () { return false; } });
    }

    const entry = {
      key,
      handler,
      priority: Number.isFinite(options.priority) ? options.priority : 0,
      order: nextOrder++,
    };
    phaseHooks.set(key, entry);

    let active = true;
    return Object.freeze({
      registered: true,
      unsubscribe: function () {
        if (!active || phaseHooks.get(key) !== entry) return false;
        active = false;
        phaseHooks.delete(key);
        if (phaseHooks.size === 0) hooks.delete(phase);
        return true;
      },
    });
  }

  function reportError(phase, key, error) {
    if (global.console && typeof global.console.error === 'function') {
      global.console.error('[POYOZZ render lifecycle] ' + phase + '/' + key + ' failed:', error);
    }
  }

  function run(phase, context) {
    let called = 0;
    let errors = 0;
    for (const entry of getEntries(phase)) {
      try {
        entry.handler(context);
        called += 1;
      } catch (error) {
        errors += 1;
        reportError(phase, entry.key, error);
      }
    }
    return Object.freeze({ called, errors });
  }

  function render(phase, context, fallback) {
    for (const entry of getEntries(phase)) {
      try {
        if (entry.handler(context) === true) {
          return Object.freeze({ handled: true, handler: entry.key, fallback: false });
        }
      } catch (error) {
        reportError(phase, entry.key, error);
      }
    }

    if (typeof fallback === 'function') {
      return Object.freeze({
        handled: false,
        handler: null,
        fallback: true,
        value: fallback(context),
      });
    }
    return Object.freeze({ handled: false, handler: null, fallback: false });
  }

  global.PoyozzChatRenderLifecycle = Object.freeze({
    register,
    run,
    render,
  });
})(window);
