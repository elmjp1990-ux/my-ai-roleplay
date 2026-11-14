/* Read-only author data adapters.
 * Public visibility and ownership remain enforced by the query/RPC and Supabase RLS.
 * Rendering, local state merging and pagination lifecycle stay in the app.
 */
(function (global) {
  'use strict';

  async function fetchLatestCharactersByAuthor(client, authorIds) {
    const result = new Map();
    const ids = [...new Set((Array.isArray(authorIds) ? authorIds : []).filter(Boolean))];
    if (!client || !ids.length) return result;

    for (let offset = 0; offset < ids.length; offset += 10) {
      const batch = ids.slice(offset, offset + 10);
      const { data, error } = await client.rpc('get_public_author_latest_characters', {
        p_author_ids: batch,
      });
      if (error) throw new Error('讀取作者最新公開角色失敗：' + error.message);
      const grouped = new Map();
      for (const row of Array.isArray(data) ? data : []) {
        if (!row?.author_id || !row?.character_data) continue;
        const rows = grouped.get(row.author_id) || [];
        rows.push(row.character_data);
        grouped.set(row.author_id, rows);
      }
      for (const authorId of batch) result.set(authorId, grouped.get(authorId) || []);
    }
    return result;
  }

  async function fetchPublicCharacterPage(client, authorId, offset, pageSize) {
    if (!client || !authorId) return { rows: [], hasMore: false };
    const { data, error } = await client.from('characters')
      .select('id,author_id,name,gender,age,avatar_url,avatar_video_path,is_nsfw,visibility,review_status,intro,race,style,tags,created_at,first_published_at,latest_eligible')
      .eq('author_id', authorId)
      .eq('visibility', 'public')
      .is('deleted_at', null)
      .order('first_published_at', { ascending: false, nullsFirst: false })
      .order('id', { ascending: false })
      .range(offset, offset + pageSize - 1);
    if (error) throw new Error(error.message);
    const rows = Array.isArray(data) ? data : [];
    return { rows, hasMore: rows.length === pageSize };
  }

  global.PoyozzAuthorData = Object.freeze({
    fetchLatestCharactersByAuthor,
    fetchPublicCharacterPage,
  });
})(window);
