BEGIN;

-- Bump the source payload so all existing test jobs become eligible for an
-- explicit re-enqueue after the modern-setting inference fix.
DO $source_version$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.encounter_schedule_source_payload(uuid)'::regprocedure
  ) INTO v_definition;

  v_old := $$~ '(現代世界|現代背景|現代都市|現代社會|現代生活|當代)'$$;
  v_new := $$~ '(現代世界|現代背景|現代都市|現代社會|現代生活|當代|財閥|企業集團|集團總裁|總裁夫人|企業|公司|商業盟約|慈善晚宴|時尚雜誌|名媛|豪門|媒體|智慧型手機|手機通訊|社群媒體|網路平台|科技業|捷運|地鐵|高鐵|信用卡|電子商務|藝術工作室|私人美術館)'$$;
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'modern_setting_inference_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  v_old := 'poyozz-encounter-schedule-v8-compact-24-hour-options-2026-11-19';
  v_new := 'poyozz-encounter-schedule-v9-modern-setting-inference-2026-11-19';
  SELECT (pg_catalog.length(v_definition) - pg_catalog.length(pg_catalog.replace(v_definition, v_old, '')))
    / pg_catalog.length(v_old) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'modern_setting_source_version_contract_count_unexpected: %', v_count;
  END IF;
  v_definition := pg_catalog.replace(v_definition, v_old, v_new);

  EXECUTE v_definition;
END;
$source_version$;

COMMENT ON FUNCTION public.encounter_schedule_source_payload(uuid) IS
  'Builds versioned public Encounter schedule context; contemporary business, finance, media, and urban-life signals count as modern-setting compatibility even without an explicit modern keyword.';

COMMIT;
