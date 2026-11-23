BEGIN;

-- Keep the database's modern-setting signal in sync with the TypeScript
-- classifier. Contemporary nightlife/entertainment roles can be modern even
-- when creators never use the literal word "現代".
DO $modern_context$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.encounter_schedule_source_payload(uuid)'::regprocedure
  ) INTO v_definition;

  v_old := $$~ '(現代世界|現代背景|現代都市|現代社會|現代生活|當代|財閥|企業集團|集團總裁|總裁夫人|企業|公司|商業盟約|慈善晚宴|時尚雜誌|名媛|豪門|媒體|智慧型手機|手機通訊|社群媒體|網路平台|科技業|捷運|地鐵|高鐵|信用卡|電子商務|藝術工作室|私人美術館)'$$;
  v_new := $$~ '(現代世界|現代背景|現代都市|現代社會|現代生活|當代|財閥|企業集團|集團總裁|總裁夫人|企業|公司|商業盟約|慈善晚宴|時尚雜誌|名媛|豪門|媒體|智慧型手機|手機通訊|社群媒體|網路平台|科技業|捷運|地鐵|高鐵|信用卡|電子商務|藝術工作室|私人美術館|男公關|牛郎|夜生活|地下樂團|Live[[:space:]-]*House|Livehouse|公寓|出租屋|VIP|黑卡)'$$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'modern_context_signal_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := 'poyozz-encounter-schedule-v9-modern-setting-inference-2026-11-19';
  v_new := 'poyozz-encounter-schedule-v10-modern-context-signals-2026-11-23';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'modern_context_source_version_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$modern_context$;

COMMENT ON FUNCTION public.encounter_schedule_source_payload(uuid) IS
  'Builds versioned public Encounter schedule context; explicit contemporary business, nightlife, entertainment, finance, media, and urban-living signals count as modern-setting compatibility unless a higher-priority historical or non-modern classification applies in the application classifier.';

COMMIT;
