-- Test-only fixtures inserted before the character deletion draft installs its AFTER INSERT origin trigger.
-- All rows are inside replay-and-test-character-deletion.sql's outer transaction and are rolled back.
INSERT INTO auth.users (id)
VALUES ('10000000-0000-4000-8000-000000000001')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, handle, nickname)
VALUES ('10000000-0000-4000-8000-000000000001', 'pr200-disposable-001', 'PR200 Disposable Test')
ON CONFLICT (id) DO NOTHING;

-- A legacy private draft with no trustworthy proof of when it was created.
INSERT INTO public.characters (id, author_id, name, visibility, review_status, first_published_at)
VALUES ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Legacy private draft', 'private', 'draft', NULL);

-- A legacy character that is public at rollout; the draft must backfill first_published_at.
INSERT INTO public.characters (id, author_id, name, visibility, review_status, first_published_at)
VALUES ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001', 'Legacy public character', 'public', 'approved', NULL);

-- A legacy character that was public before rollout but is already private by rollout.
-- It cannot be proven never-published and therefore must remain soft-delete-only.
INSERT INTO public.characters (id, author_id, name, visibility, review_status, first_published_at)
VALUES ('20000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000001', 'Legacy formerly public character', 'public', 'approved', NULL);
UPDATE public.characters
SET visibility = 'private', review_status = 'draft'
WHERE id = '20000000-0000-4000-8000-000000000003';
