(function attachPoyozzCoreUtils(global) {
  'use strict';

  // Keep these helpers pure: no DOM, storage, network, or application state.
  const countChars = value => [...String(value)].length;
  const clone = value => JSON.parse(JSON.stringify(value));
  function isUuid(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ''));
  }

  global.PoyozzCoreUtils = Object.freeze({ countChars, clone, isUuid });
})(window);
