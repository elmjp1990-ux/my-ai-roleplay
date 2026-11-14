\set ON_ERROR_STOP on

INSERT INTO public.characters (id, author_id, visibility, deleted_at, is_nsfw, review_status, rights_confirmed)
VALUES
 ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','public',NULL,false,'approved',true),
 ('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','public',NULL,true,'approved',true),
 ('20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001','private',NULL,false,'approved',true),
 ('20000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001','public',clock_timestamp(),false,'approved',true),
 ('20000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000001','public',NULL,false,'pending',true),
 ('20000000-0000-4000-8000-000000000006','10000000-0000-4000-8000-000000000001','public',NULL,false,'approved',false),
 ('20000000-0000-4000-8000-000000000007','10000000-0000-4000-8000-000000000002','public',NULL,false,'approved',true);

INSERT INTO public.character_stories (id, character_id, opening_message, visibility, created_at)
VALUES
 ('30000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','older opening','public','2026-11-01T00:00:00Z'),
 ('30000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','newest opening','public','2026-11-02T00:00:00Z'),
 ('30000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000007','other owner opening','public','2026-11-03T00:00:00Z');

INSERT INTO public.character_schedules (id, character_id, weekday, day_type, start_time, end_time, location_key, activity, priority, is_active)
VALUES
 ('40000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',1,'weekday','09:00','10:00','library','reading',10,true),
 ('40000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001',1,'weekday','10:00','11:00','library','inactive row',9,false),
 ('40000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000002',1,'weekday','09:00','10:00','city','nsfw schedule',10,true),
 ('40000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000003',1,'weekday','09:00','10:00','city','private schedule',10,true),
 ('40000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000004',1,'weekday','09:00','10:00','city','deleted schedule',10,true),
 ('40000000-0000-4000-8000-000000000006','20000000-0000-4000-8000-000000000005',1,'weekday','09:00','10:00','city','unapproved schedule',10,true),
 ('40000000-0000-4000-8000-000000000007','20000000-0000-4000-8000-000000000006',1,'weekday','09:00','10:00','city','rights missing schedule',10,true),
 ('40000000-0000-4000-8000-000000000008','20000000-0000-4000-8000-000000000007',1,'weekday','09:00','10:00','city','other author schedule',10,true);

INSERT INTO public.chat_sessions (id, user_id, character_id, deleted_at, chat_mode, session_data, updated_at)
VALUES
 ('60000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',NULL,'story','{}','2026-11-01T00:00:00Z'),
 ('60000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',NULL,'story','{}','2026-11-02T00:00:00Z'),
 ('60000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',NULL,'encounter','{"encounter":{}}','2026-11-05T00:00:00Z'),
 ('60000000-0000-4000-8000-000000000004','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001',clock_timestamp(),'story','{}','2026-11-06T00:00:00Z'),
 ('60000000-0000-4000-8000-000000000005','10000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001',NULL,'story','{}','2026-11-07T00:00:00Z');

INSERT INTO public.chat_messages (id, session_id, role, deleted_at, created_at)
VALUES
 ('70000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001','user',NULL,'2026-11-02T00:00:00Z'),
 ('70000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002','user',NULL,'2026-11-03T00:00:00Z'),
 ('70000000-0000-4000-8000-000000000003','60000000-0000-4000-8000-000000000003','user',NULL,'2026-11-08T00:00:00Z'),
 ('70000000-0000-4000-8000-000000000004','60000000-0000-4000-8000-000000000004','user',NULL,'2026-11-09T00:00:00Z'),
 ('70000000-0000-4000-8000-000000000005','60000000-0000-4000-8000-000000000005','user',NULL,'2026-11-10T00:00:00Z');

INSERT INTO public.character_comments (id, character_id, author_id, content, parent_id, is_whisper, is_deleted, created_at, updated_at)
SELECT
  ('50000000-0000-4000-8000-' || pg_catalog.lpad(n::text,12,'0'))::uuid,
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002',
  'comment-' || n,
  NULL,
  n = 2,
  n = 3,
  '2026-11-01T00:00:00Z'::timestamptz + n * interval '1 minute',
  '2026-11-01T00:00:00Z'::timestamptz + n * interval '1 minute'
FROM generate_series(1,12) AS n;

INSERT INTO public.character_comments (id, character_id, author_id, content, parent_id, is_whisper, is_deleted, created_at, updated_at)
VALUES
 ('50000000-0000-4000-8000-000000000013','20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','nsfw comment',NULL,false,false,'2026-11-01T00:00:00Z','2026-11-01T00:00:00Z');

-- Function ACLs are part of the migration contract.
DO $$
BEGIN
  IF NOT has_function_privilege('authenticated','public.get_latest_owned_character_stories(uuid[])','EXECUTE')
     OR has_function_privilege('anon','public.get_latest_owned_character_stories(uuid[])','EXECUTE') THEN
    RAISE EXCEPTION 'owner story RPC grants are incorrect';
  END IF;
  IF NOT has_function_privilege('anon','public.get_encounter_character_schedules(uuid[])','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.get_encounter_character_schedules(uuid[])','EXECUTE') THEN
    RAISE EXCEPTION 'public Encounter schedule RPC grants are incorrect';
  END IF;
  IF NOT has_function_privilege('authenticated','public.find_existing_story_chat_session(uuid)','EXECUTE')
     OR has_function_privilege('anon','public.find_existing_story_chat_session(uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'Story session lookup RPC grants are incorrect';
  END IF;
  IF NOT has_function_privilege('anon','public.get_character_comments_safe_page(uuid,integer,integer)','EXECUTE')
     OR NOT has_function_privilege('authenticated','public.get_character_comments_safe_page(uuid,integer,integer)','EXECUTE') THEN
    RAISE EXCEPTION 'bounded comment RPC grants are incorrect';
  END IF;
END
$$;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SELECT set_config('request.jwt.claim.adult','false',false);

DO $$
DECLARE
  v_count integer;
  v_story text;
  v_session uuid;
BEGIN
  SELECT count(*), max(opening_message)
    INTO v_count, v_story
  FROM public.get_latest_owned_character_stories(ARRAY[
    '20000000-0000-4000-8000-000000000001'::uuid,
    '20000000-0000-4000-8000-000000000007'::uuid
  ]);
  IF v_count <> 1 OR v_story <> 'newest opening' THEN
    RAISE EXCEPTION 'owner latest-story RPC leaked another owner or failed newest-row selection: %, %', v_count, v_story;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.get_latest_owned_character_stories(ARRAY[
    '20000000-0000-4000-8000-000000000001'::uuid,
    '20000000-0000-4000-8000-000000000002'::uuid,
    '20000000-0000-4000-8000-000000000003'::uuid,
    '20000000-0000-4000-8000-000000000004'::uuid,
    '20000000-0000-4000-8000-000000000005'::uuid,
    '20000000-0000-4000-8000-000000000006'::uuid,
    '20000000-0000-4000-8000-000000000007'::uuid,
    '30000000-0000-4000-8000-000000000001'::uuid,
    '30000000-0000-4000-8000-000000000002'::uuid,
    '30000000-0000-4000-8000-000000000003'::uuid,
    '30000000-0000-4000-8000-000000000004'::uuid
  ]);
  IF v_count <> 0 THEN RAISE EXCEPTION 'story RPC accepted more than ten IDs'; END IF;

  SELECT count(*) INTO v_count
  FROM public.get_encounter_character_schedules(ARRAY[
    '20000000-0000-4000-8000-000000000001'::uuid,
    '20000000-0000-4000-8000-000000000002'::uuid,
    '20000000-0000-4000-8000-000000000003'::uuid,
    '20000000-0000-4000-8000-000000000004'::uuid,
    '20000000-0000-4000-8000-000000000005'::uuid,
    '20000000-0000-4000-8000-000000000006'::uuid,
    '20000000-0000-4000-8000-000000000007'::uuid
  ]);
  IF v_count <> 1 THEN RAISE EXCEPTION 'Encounter schedule RPC returned private, deleted, unapproved, rights-missing, inactive or NSFW rows'; END IF;

  SELECT session_id INTO v_session
  FROM public.find_existing_story_chat_session('20000000-0000-4000-8000-000000000001');
  IF v_session <> '60000000-0000-4000-8000-000000000002'::uuid THEN
    RAISE EXCEPTION 'Story session lookup did not choose newest eligible user activity: %', v_session;
  END IF;
END
$$;

-- Non-owner, non-adult user sees public comments with whisper content masked.
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',false);
DO $$
DECLARE
  v_count integer;
  v_content text;
  v_redacted boolean;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000001',100,0);
  IF v_count <> 10 THEN RAISE EXCEPTION 'comment page limit was not clamped to ten: %', v_count; END IF;

  SELECT content, is_redacted INTO v_content, v_redacted
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000001',10,0)
  WHERE id = '50000000-0000-4000-8000-000000000002';
  IF v_content <> '這是一則悄悄話留言' OR v_redacted IS NOT TRUE THEN
    RAISE EXCEPTION 'whisper content was not masked for a non-owner';
  END IF;

  SELECT content INTO v_content
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000001',10,0)
  WHERE id = '50000000-0000-4000-8000-000000000003';
  IF v_content <> '該筆評論已被刪除' THEN
    RAISE EXCEPTION 'deleted comment content was not masked';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000001',10,10);
  IF v_count <> 2 THEN RAISE EXCEPTION 'comment offset did not return the remaining two rows: %', v_count; END IF;

  SELECT count(*) INTO v_count
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000003',10,0);
  IF v_count <> 0 THEN RAISE EXCEPTION 'private character comments were exposed'; END IF;

  SELECT count(*) INTO v_count
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000002',10,0);
  IF v_count <> 0 THEN RAISE EXCEPTION 'NSFW comments were exposed to a non-adult user'; END IF;
END
$$;

-- Adult verification unlocks NSFW schedules/comments; character owner can see whisper text.
SELECT set_config('request.jwt.claim.adult','true',false);
DO $$
DECLARE v_count integer; v_content text;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.get_encounter_character_schedules(ARRAY['20000000-0000-4000-8000-000000000002'::uuid]);
  IF v_count <> 1 THEN RAISE EXCEPTION 'adult-verified user could not read eligible NSFW schedule'; END IF;

  SELECT count(*) INTO v_count
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000002',10,0);
  IF v_count <> 1 THEN RAISE EXCEPTION 'adult-verified user could not read NSFW comments'; END IF;
END
$$;

SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SELECT set_config('request.jwt.claim.adult','false',false);
DO $$
DECLARE v_content text; v_redacted boolean;
BEGIN
  SELECT content, is_redacted INTO v_content, v_redacted
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000001',10,0)
  WHERE id = '50000000-0000-4000-8000-000000000002';
  IF v_content <> 'comment-2' OR v_redacted IS NOT FALSE THEN
    RAISE EXCEPTION 'character author should see the unmasked whisper thread';
  END IF;
END
$$;

RESET ROLE;

SET ROLE anon;
SELECT set_config('request.jwt.claim.sub','',false);
SELECT set_config('request.jwt.claim.adult','false',false);
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.get_encounter_character_schedules(ARRAY[
    '20000000-0000-4000-8000-000000000001'::uuid,
    '20000000-0000-4000-8000-000000000002'::uuid
  ]);
  IF v_count <> 1 THEN RAISE EXCEPTION 'anonymous schedule access must exclude NSFW rows'; END IF;

  SELECT count(*) INTO v_count
  FROM public.get_character_comments_safe_page('20000000-0000-4000-8000-000000000001',10,0);
  IF v_count <> 10 THEN RAISE EXCEPTION 'anonymous public comment page did not return ten rows'; END IF;
END
$$;
RESET ROLE;

SELECT 'batched read migration scenarios passed' AS result;
