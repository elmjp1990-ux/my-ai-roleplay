-- Verify the page-scoped group preview RPC returns one newest message only
-- for groups owned by the authenticated caller.
\set ON_ERROR_STOP on

INSERT INTO public.chat_group_turns(id,group_id,user_id,request_key,request_content,status)
VALUES
 ('50000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001','preview-old','completed'),
 ('50000000-0000-4000-8000-000000000002','20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002','preview-new','completed'),
 ('50000000-0000-4000-8000-000000000003','20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000003','other-owner','completed'),
 ('50000000-0000-4000-8000-000000000004','20000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000003','60000000-0000-4000-8000-000000000004','deleted-group','completed'),
 ('50000000-0000-4000-8000-000000000005','20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000005','deleted-message','completed');

INSERT INTO public.chat_group_messages(group_id,turn_id,sequence_no,speaker_type,content,created_at,deleted_at)
VALUES
 ('20000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001',1,'character','older owned preview',clock_timestamp() - interval '1 second',NULL),
 ('20000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000002',1,'character','newest owned preview',clock_timestamp() + interval '1 second',NULL),
 ('20000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000003',1,'character','other owner preview',clock_timestamp(),NULL),
 ('20000000-0000-4000-8000-000000000003','50000000-0000-4000-8000-000000000004',1,'character','deleted group preview',clock_timestamp(),NULL),
 ('20000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000005',1,'character','deleted message must not win',clock_timestamp() + interval '2 minutes',clock_timestamp());

SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;

DO $$
DECLARE
  v_count integer;
  v_preview record;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.get_my_group_list_previews(ARRAY[
    '20000000-0000-4000-8000-000000000001'::uuid,
    '20000000-0000-4000-8000-000000000002'::uuid,
    '20000000-0000-4000-8000-000000000003'::uuid
  ]);
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'expected only one active caller-owned group preview, got %', v_count;
  END IF;

  SELECT * INTO v_preview
  FROM public.get_my_group_list_previews(ARRAY[
    '20000000-0000-4000-8000-000000000001'::uuid
  ]);
  IF v_preview.content <> 'newest owned preview' OR v_preview.sequence_no <> 1 THEN
    RAISE EXCEPTION 'group preview did not select the latest message: %', row_to_json(v_preview);
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.get_my_group_list_previews(ARRAY[
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid,
      '20000000-0000-4000-8000-000000000001'::uuid
    ])
  ) THEN
    RAISE EXCEPTION 'group preview RPC accepted more than ten IDs';
  END IF;
END
$$;

RESET ROLE;
