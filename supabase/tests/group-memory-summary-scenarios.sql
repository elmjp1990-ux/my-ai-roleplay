
-- Group Story AI summaries are owner-scoped, editable, and retained as 50–150 characters.
INSERT INTO auth.users(id) VALUES
 ('10000000-0000-4000-8000-000000000009'),
 ('10000000-0000-4000-8000-000000000010')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.chat_groups(id,owner_id,name) VALUES
 ('20000000-0000-4000-8000-000000000009','10000000-0000-4000-8000-000000000009','memory-summary');
INSERT INTO public.chat_group_turns(id,group_id,user_id,request_key,request_content,status,created_at)
SELECT
 ('51000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 '20000000-0000-4000-8000-000000000009',
 '10000000-0000-4000-8000-000000000009',
 ('52000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'group summary test turn '||n,
 'completed',
 now() + (n||' seconds')::interval
FROM generate_series(1,5) n;

INSERT INTO public.chat_group_messages(group_id,turn_id,sequence_no,speaker_type,content,speaker_snapshot)
SELECT
 '20000000-0000-4000-8000-000000000009'::uuid,
 t.id,0,'user',t.request_content,'{"name":"玩家"}'::jsonb
FROM public.chat_group_turns t
WHERE t.group_id='20000000-0000-4000-8000-000000000009'
UNION ALL
SELECT
 '20000000-0000-4000-8000-000000000009'::uuid,
 t.id,1,'character','角色回應：已確認本回合的調查進度。','{"name":"角色A"}'::jsonb
FROM public.chat_group_turns t
WHERE t.group_id='20000000-0000-4000-8000-000000000009';

SET ROLE service_role;
INSERT INTO public.chat_group_memory_summaries(
  group_id,user_id,batch_number,source_turn_ids,summary,status,model,processed_at
)
SELECT
 '20000000-0000-4000-8000-000000000009',
 '10000000-0000-4000-8000-000000000009',
 1,array_agg(id ORDER BY created_at),
 '玩家與角色A共同完成首次調查，確認彼此的分工與信任，並約定隔天前往車站追查失竊物品的線索，同時保留尚未解開的疑點與後續待辦。',
 'completed','openai/gpt-oss-20b',now()
FROM public.chat_group_turns
WHERE group_id='20000000-0000-4000-8000-000000000009';
RESET ROLE;
RESET request.jwt.claim.sub;

SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000009',false);
DO $$
DECLARE v_count integer; v_important boolean; v_edited boolean;
BEGIN
  SELECT count(*),bool_or(important),bool_or(user_edited)
  INTO v_count,v_important,v_edited
  FROM public.get_group_memory_summaries('20000000-0000-4000-8000-000000000009');
  IF v_count<>1 THEN RAISE EXCEPTION 'group memory summary owner read failed: %',v_count; END IF;
  IF public.set_group_memory_summary_important(
    '20000000-0000-4000-8000-000000000009',1,true
  ) IS DISTINCT FROM true THEN RAISE EXCEPTION 'group summary important update failed'; END IF;
  IF public.update_group_memory_summary(
    '20000000-0000-4000-8000-000000000009',1,
    '玩家與角色A完成首次調查，建立明確分工並確認互相信任，雙方約定隔天前往車站追查失竊物品，並保留尚未解開的線索作為下一段故事的起點。'
  ) IS DISTINCT FROM true THEN RAISE EXCEPTION 'group summary edit failed'; END IF;
  SELECT bool_or(important),bool_or(user_edited)
  INTO v_important,v_edited
  FROM public.get_group_memory_summaries('20000000-0000-4000-8000-000000000009');
  IF NOT v_important OR NOT v_edited THEN RAISE EXCEPTION 'group summary edits were not persisted'; END IF;
END $$;

SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000010',false);
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.get_group_memory_summaries('20000000-0000-4000-8000-000000000009');
  IF v_count<>0 THEN RAISE EXCEPTION 'group summary leaked to a non-owner'; END IF;
  IF public.set_group_memory_summary_important(
    '20000000-0000-4000-8000-000000000009',1,true
  ) IS DISTINCT FROM false THEN RAISE EXCEPTION 'non-owner changed group summary important state'; END IF;
END $$;
RESET ROLE;
