// Supabase Edge Function: cafe-search
// 산악회별 다음 카페 검색어로 최신 글을 찾아 "산행 공지 후보"(trip_candidates)에 저장합니다. (카카오 Daum 검색 API 사용)
// 필요한 Secrets: KAKAO_REST_API_KEY (선택: CRON_SECRET - 자동 예약 실행용)
// 호출: ① 관리자 화면의 "지금 검색"(로그인한 담당자/총괄) ② pg_cron(x-cron-secret 헤더)
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-cron-secret',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const strip = (h: unknown) =>
  String(h ?? '').replace(/<[^>]*>/g, '').replace(/&quot;/g, '"').replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();

// https://cafe.daum.net/카페아이디/... 형태에서 카페 아이디만 뽑습니다.
const cafeId = (url: unknown) => {
  const m = String(url ?? '').match(/cafe\.daum\.net\/([^\/?#]+)/i);
  return m ? decodeURIComponent(m[1]).toLowerCase() : null;
};

// 제목·요약에서 산행일을 추정합니다. (정확하지 않을 수 있어 화면에서 "추정"으로 표시)
function guessDate(text: string, postedAt: string | null): string | null {
  const base = postedAt ? new Date(postedAt) : new Date();
  let y: number | null = null, mo = 0, d = 0, m: RegExpMatchArray | null;
  if ((m = text.match(/(20\d{2})\s*[-./년]\s*(\d{1,2})\s*[-./월]\s*(\d{1,2})/))) { y = +m[1]; mo = +m[2]; d = +m[3]; }
  else if ((m = text.match(/(\d{1,2})\s*월\s*(\d{1,2})\s*일/))) { mo = +m[1]; d = +m[2]; }
  else if ((m = text.match(/(\d{1,2})\s*\/\s*(\d{1,2})\s*[\(（]?\s*[월화수목금토일]/))) { mo = +m[1]; d = +m[2]; }
  else return null;
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  if (y === null) {
    y = base.getFullYear();
    if (Date.UTC(y, mo - 1, d) < base.getTime() - 45 * 864e5) y += 1; // 글 작성 한참 전 날짜면 내년으로 봅니다
  }
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCMonth() !== mo - 1) return null;
  return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const kakaoKey = Deno.env.get('KAKAO_REST_API_KEY');
    if (!kakaoKey) return json({ ok: false, error: '카카오 REST API 키(KAKAO_REST_API_KEY)가 설정되지 않았습니다.' });

    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const body = await req.json().catch(() => ({}));

    // 누가 호출했는지 확인: 예약 실행(CRON_SECRET) 또는 로그인한 담당자/총괄
    const cron = Deno.env.get('CRON_SECRET');
    const isCron = !!cron && req.headers.get('x-cron-secret') === cron;
    let allowed: number[] | null = null; // null = 전체 산악회
    if (!isCron) {
      const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
      const { data: u } = await db.auth.getUser(token);
      if (!u?.user) return json({ ok: false, error: '로그인이 필요합니다.' }, 401);
      const { data: sa } = await db.from('super_admins').select('user_id').eq('user_id', u.user.id).maybeSingle();
      if (!sa) {
        const { data: ca } = await db.from('club_admins').select('club_id').eq('user_id', u.user.id);
        allowed = (ca ?? []).map((x) => x.club_id);
        if (!allowed.length) return json({ ok: false, error: '담당 산악회가 없습니다.' }, 403);
      }
    }

    let q = db.from('clubs').select('id, name, cafe_url, search_query');
    if (allowed) q = q.in('id', allowed);
    if (body.club_id) q = q.eq('id', Number(body.club_id));
    const { data: clubs } = await q;

    let found = 0, added = 0;
    const errors: string[] = [];
    for (const club of clubs ?? []) {
      const query = (club.search_query || `${club.cafe.url} 산행공지`).trim();
      const id = cafeId(club.cafe_url);
      const url = new URL('https://dapi.kakao.com/v2/search/cafe');
      url.searchParams.set('query', query);
      url.searchParams.set('sort', 'recency');
      url.searchParams.set('size', '30');
      const res = await fetch(url, { headers: { Authorization: `KakaoAK ${kakaoKey}` } });
      if (!res.ok) { errors.push(`${club.cafe.url}: 검색 실패(${res.status})`); continue; }
      const docs = (await res.json()).documents ?? [];
      found += docs.length;
      const mine = id ? docs.filter((d: { url: string }) => cafeId(d.url) === id) : docs;
      if (id && docs.length && !mine.length) errors.push(`${club.cafe.url}: 검색된 ${docs.length}건 중 등록한 카페 주소의 글이 없습니다.`);
      if (!docs.length) errors.push(`${club.cafe.url}: 검색 결과가 없습니다. (검색어 "${query}")`);
      const rows = mine.map((d: Record<string, string>) => {
        const title = strip(d.title), summary = strip(d.contents);
        return {
          club_id: club.id, title, url: d.url, summary: summary.slice(0, 300),
          cafe_name: d.cafename ? strip(d.cafename) : null, posted_at: d.datetime || null,
          guess_date: guessDate(`${title} ${summary}`, d.datetime || null),
        };
      });
      if (rows.length) {
        const { data: ins, error } = await db.from('trip_candidates')
          .upsert(rows, { onConflict: 'club_id,url', ignoreDuplicates: true }).select('id');
        if (error) errors.push(`${club.cafe.url}: 저장 실패(${error.message})`); else added += ins?.length ?? 0;
      }
    }
    return json({ ok: true, clubs: clubs?.length ?? 0, found, added, errors });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
