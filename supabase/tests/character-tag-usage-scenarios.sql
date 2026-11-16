SELECT set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',false);
SET ROLE authenticated;
DO $$
DECLARE v_tags text[];
BEGIN
  v_tags:=public.get_active_character_tags('20000000-0000-0000-0000-000000000001');
  IF NOT ('共用標籤'=ANY(v_tags)) THEN
    RAISE EXCEPTION 'tag shared with another active public card must remain available: %',v_tags;
  END IF;
  IF '只在本卡'=ANY(v_tags) THEN
    RAISE EXCEPTION 'tag used only by the edited card must disappear: %',v_tags;
  END IF;
  IF '他人私密'=ANY(v_tags) OR '已刪除標籤'=ANY(v_tags) THEN
    RAISE EXCEPTION 'private or deleted-card tags must not be returned: %',v_tags;
  END IF;
END
$$;
RESET ROLE;
RESET request.jwt.claim.sub;
