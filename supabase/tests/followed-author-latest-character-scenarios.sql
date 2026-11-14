SET ROLE authenticated;
DO $$
DECLARE
  total_rows integer;
  first_name text;
BEGIN
  SELECT count(*) INTO total_rows
  FROM public.get_public_author_latest_characters(ARRAY[
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
    'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid
  ]);
  IF total_rows <> 10 THEN
    RAISE EXCEPTION 'Expected five rows per public author, received %', total_rows;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.get_public_author_latest_characters(ARRAY[
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
      'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
      'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid
    ])
    WHERE character_data->>'name' IN ('A-private', 'A-deleted', 'C-private')
       OR author_rank > 5
  ) THEN
    RAISE EXCEPTION 'Private, deleted, or over-limit character preview leaked';
  END IF;

  SELECT character_data->>'name' INTO first_name
  FROM public.get_public_author_latest_characters(ARRAY[
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid
  ])
  WHERE author_rank = 1;
  IF first_name <> 'A-6' THEN
    RAISE EXCEPTION 'Expected newest character A-6 first, received %', first_name;
  END IF;

  SELECT count(*) INTO total_rows
  FROM public.get_public_author_latest_characters(ARRAY[
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid,
    'cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid,
    'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid,
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'::uuid,
    'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid,
    '22222222-2222-2222-2222-222222222222'::uuid,
    '33333333-3333-3333-3333-333333333333'::uuid,
    '44444444-4444-4444-4444-444444444444'::uuid,
    '55555555-5555-5555-5555-555555555555'::uuid
  ]);
  IF total_rows <> 0 THEN
    RAISE EXCEPTION 'Expected over-limit author input to return no rows';
  END IF;
END
$$;
RESET ROLE;
