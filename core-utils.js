(function attachPoyozzCoreUtils(global) {
  'use strict';

  // Keep these helpers pure: no DOM, storage, network, or application state.
  const countChars = value => [...String(value)].length;
  const clone = value => JSON.parse(JSON.stringify(value));
  function isUuid(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ''));
  }


  function classifyCharacterProfileChanges({existingCharacter, existingPrivateProfile, character, normalizePersonalityProfile, rowPhoneSettingsForDiff}) {
    const stable = v => Array.isArray(v) ? v.map(stable) : v && typeof v === 'object'
      ? Object.fromEntries(Object.keys(v).sort().map(k => [k, stable(v[k])])) : v ?? null;
    const changed = (a, b) => JSON.stringify(stable(a)) !== JSON.stringify(stable(b));
    const normalized = v => String(v ?? '').normalize('NFKC').replace(/[\s\u200B-\u200D\uFEFF]+/gu, '');
    const sourceChanged = (a, b) => typeof a === 'string' && typeof b === 'string'
      ? normalized(a) !== normalized(b) : changed(a, b);
    const ai = [], runtime = [], nonAi = [];
    const compare = (target, key, a, b) => { if (changed(a, b)) target.push({ key, label: key }); };
    const compareSource = (key, a, b) => {
      if (sourceChanged(a, b)) ai.push({ key, label: key });
      else if (changed(a, b)) nonAi.push({ key: key + '_format_only', label: key });
    };
    const prev = normalizePersonalityProfile(existingPrivateProfile?.personality_profile || {});
    const next = normalizePersonalityProfile(character.personalityProfile || {});
    compare(nonAi, 'name', existingCharacter?.name, String(character.name || '').trim());
    compareSource('intro', existingCharacter?.intro || '', character.intro || '');
    compareSource('race', existingCharacter?.race || '', character.race || '');
    compareSource('style', existingCharacter?.style || '', character.style || '');
    compareSource('private_info', existingPrivateProfile?.private_info || '', String(character.privateInfo || '').slice(0, 10000));
    const fields = ['coreTraits','values','speechStyle','behaviorRules','likes','dislikes','boundaries','relationshipPacing'];
    for (const key of fields) compare(ai, 'personality_profile.' + key, prev[key], next[key]);
    compare(nonAi, 'personality_profile.primaryIllustrationName', prev.primaryIllustrationName, next.primaryIllustrationName);
    compare(runtime, 'phone_settings', existingCharacter?.phone_settings || {}, rowPhoneSettingsForDiff(character.phoneSettings));
    compare(nonAi, 'tags', existingCharacter?.tags || [], character.tags || []);
    const isNew = !existingCharacter, refresh = ai.length > 0;
    return {
      version: 4,
      status: refresh ? 'needs_review' : 'not_needed',
      reason: refresh ? (isNew ? 'new_character_ai_source_present' : 'ai_source_fields_changed')
        : (isNew ? 'new_character_source_fields_available' : 'no_ai_relevant_change'),
      changeClass: refresh ? (ai.some(x => x.key.startsWith('personality_profile.'))
        ? 'personality_or_character_context_changed' : 'background_context_changed')
        : (nonAi.length ? 'presentation_or_opening_only' : 'no_profile_source_change'),
      openingMessagePolicy: 'runtime_only_no_profile_refresh',
      model: 'deepseek/deepseek-v4-flash-20260423',
      changedFields: ai.map(x => x.key), changedFieldLabels: ai.map(x => x.label),
      runtimeAiChangedFields: runtime.map(x => x.key), nonAiChangedFields: nonAi.map(x => x.key),
      requiresDerivedRefresh: refresh, shouldCallModel: false,
    };
  }

  global.PoyozzCoreUtils = Object.freeze({ countChars, clone, isUuid, classifyCharacterProfileChanges });
})(window);
