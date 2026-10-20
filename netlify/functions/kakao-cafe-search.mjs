// Kakao Daum Cafe search proxy
// Netlify environment variable required: KAKAO_REST_API_KEY
// Never put the Kakao REST API key in index.html or config.js.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

export default async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "GET") return json({ error: "GET only" }, 405);

  const key = process.env.KAKAO_REST_API_KEY;
  if (!key) return json({ error: "Netlify 환경변수 KAKAO_REST_API_KEY가 설정되지 않았습니다." }, 500);

  const url = new URL(req.url);
  const q = (url.searchParams.get("q") || "").trim();
  const cafeId = (url.searchParams.get("cafeId") || "").trim().toLowerCase();
  const page = Math.max(1, Math.min(50, Number(url.searchParams.get("page") || 1)));

  if (!q) return json({ error: "검색어(q)가 필요합니다." }, 400);
  if (!cafeId) return json({ error: "카페 ID(cafeId)가 필요합니다." }, 400);
  if (!/^[a-z0-9._-]+$/i.test(cafeId)) return json({ error: "잘못된 카페 ID입니다." }, 400);

  const api = new URL("https://dapi.kakao.com/v2/search/cafe");
  api.searchParams.set("query", q);
  api.searchParams.set("size", "50");
  api.searchParams.set("page", String(page));
  api.searchParams.set("sort", "recency");

  const r = await fetch(api, {
    headers: { Authorization: `KakaoAK ${key}` },
  });
  const data = await r.json();
  if (!r.ok) return json({ error: data?.message || "Kakao API 검색 실패", status: r.status }, r.status);

  // 검색 결과 중 지정한 다음카페의 글만 통과시킵니다.
  const prefix = `https://cafe.daum.net/${cafeId}/`.toLowerCase();
  const documents = (data.documents || []).filter((d) =>
    String(d.url || "").toLowerCase().startsWith(prefix)
  );

  return json({
    documents,
    meta: data.meta || {},
    cafe_id: cafeId,
    query: q,
  });
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8" },
  });
}
