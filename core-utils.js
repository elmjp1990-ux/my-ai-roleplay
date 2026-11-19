(function attachPoyozzCoreUtils(global) {
  'use strict';

  // Keep these helpers pure: no DOM, storage, network, or application state.
  const countChars = value => [...String(value)].length;
  const clone = value => JSON.parse(JSON.stringify(value));
  function isUuid(value) {
    return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value || ''));
  }


  function classifyCharacterProfileChanges({
    existingCharacter, existingPrivateProfile, character,
    normalizePersonalityProfile, rowPhoneSettingsForDiff,
  }) {
    const stableValue = value => {
      if (Array.isArray(value)) return value.map(stableValue);
      if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, stableValue(value[key])]));
      return value ?? null;
    };
    const changed = (before, after) => JSON.stringify(stableValue(before)) !== JSON.stringify(stableValue(after));
    const normalizedText = value => String(value ?? '').normalize('NFKC').replace(/[\s\u200B-\u200D\uFEFF]+/gu, '');
    const sourceChanged = (before, after) => typeof before === 'string' && typeof after === 'string'
      ? normalizedText(before) !== normalizedText(after) : changed(before, after);
    const ai = [], runtime = [], nonAi = [];
    const compare = (target, key, label, before, after) => { if (changed(before, after)) target.push({ key, label }); };
    const compareSource = (key, label, before, after) => {
      if (sourceChanged(before, after)) ai.push({ key, label });
      else if (changed(before, after)) nonAi.push({ key: key + '_format_only', label: label + '（僅空白／換行調整）' });
    };
    const previous = normalizePersonalityProfile(existingPrivateProfile?.personality_profile || {});
    const next = normalizePersonalityProfile(character.personalityProfile || {});
    compare(nonAi, 'name', '角色名稱', existingCharacter?.name, String(character.name || '').trim());
    compareSource('intro', '角色介紹／背景', existingCharacter?.intro || '', character.intro || '');
    compareSource('race', '種族／世界觀', existingCharacter?.race || '', character.race || '');
    compareSource('style', '角色風格', existingCharacter?.style || '', character.style || '');
    compareSource('private_info', '作者私密設定', existingPrivateProfile?.private_info || '', String(character.privateInfo || '').slice(0, 10000));
    const profileFields = {
      coreTraits: '核心特質', values: '價值觀', speechStyle: '說話方式',
      behaviorRules: '行為規則', likes: '喜好', dislikes: '厭惡',
      boundaries: '互動界線', relationshipPacing: '關係進展節奏',
    };
    for (const [key, label] of Object.entries(profileFields)) compare(ai, 'personality_profile.' + key, label, previous[key], next[key]);
    compare(nonAi, 'personality_profile.primaryIllustrationName', '主要立繪名稱', previous.primaryIllustrationName, next.primaryIllustrationName);
    compare(runtime, 'phone_settings', '手機通知生成設定', existingCharacter?.phone_settings || {}, rowPhoneSettingsForDiff(character.phoneSettings));
    compare(nonAi, 'tags', '角色標籤', existingCharacter?.tags || [], character.tags || []);
    const isNewCharacter = !existingCharacter;
    const requiresDerivedRefresh = ai.length > 0;
    return {
      version: 4,
      status: requiresDerivedRefresh ? 'needs_review' : 'not_needed',
      reason: requiresDerivedRefresh ? (isNewCharacter ? 'new_character_ai_source_present' : 'ai_source_fields_changed')
        : (isNewCharacter ? 'new_character_source_fields_available' : 'no_ai_relevant_change'),
      changeClass: requiresDerivedRefresh
        ? (ai.some(item => item.key.startsWith('personality_profile.')) ? 'personality_or_character_context_changed' : 'background_context_changed')
        : (nonAi.length ? 'presentation_or_opening_only' : 'no_profile_source_change'),
      openingMessagePolicy: 'runtime_only_no_profile_refresh',
      model: 'deepseek/deepseek-v4-flash-20260423',
      changedFields: ai.map(item => item.key),
      changedFieldLabels: ai.map(item => item.label),
      runtimeAiChangedFields: runtime.map(item => item.key),
      nonAiChangedFields: nonAi.map(item => item.key),
      requiresDerivedRefresh,
      shouldCallModel: false,
    };
  }

  global.PoyozzCoreUtils = Object.freeze({ countChars, clone, isUuid, classifyCharacterProfileChanges });
})(window);
