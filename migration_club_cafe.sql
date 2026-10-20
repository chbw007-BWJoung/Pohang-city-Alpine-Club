-- 산악회 다음카페 연동 업그레이드
-- 기존 clubs / trips / 예약 데이터는 유지됩니다.
alter table clubs add column if not exists cafe_id text;
alter table clubs add column if not exists cafe_url text;
alter table clubs add column if not exists search_query text;
alter table clubs add column if not exists cafe_search_enabled boolean not null default true;

alter table clubs drop constraint if exists clubs_cafe_url_check;
alter table clubs add constraint clubs_cafe_url_check
  check (cafe_url is null or cafe_url ~* '^https?://cafe\.daum\.net/');

create index if not exists clubs_cafe_id_idx on clubs(cafe_id);

-- 현재 사용 중인 3개 산악회 기본값
insert into clubs (name, payment_hours, cafe_id, cafe_url, search_query, cafe_search_enabled)
values
  ('포항다음산악회', 48, 'pohanghanmailsan', 'https://cafe.daum.net/pohanghanmailsan', '포항다음{한메일}산악회 산행', true),
  ('아모르산악클럽', 48, 'amorclub', 'https://cafe.daum.net/amorclub', '아모르산악클럽 정기산행', true),
  ('포항마루금산악회', 48, 'marugeum', 'https://cafe.daum.net/marugeum', '포항마루금산악회 정기산행', true)
on conflict (name) do update set
  cafe_id = excluded.cafe_id,
  cafe_url = excluded.cafe_url,
  search_query = excluded.search_query,
  cafe_search_enabled = excluded.cafe_search_enabled;

-- 기존 update_club 함수는 유지하면서 다음카페 정보도 함께 수정할 수 있게 확장
drop function if exists update_club(bigint, text, int, text, text, text, text, text, text);
create or replace function update_club(
  p_club_id bigint, p_name text, p_payment_hours int, p_bank_name text, p_bank_account text, p_bank_holder text,
  p_cafe_id text default null, p_cafe_url text default null, p_search_query text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_manage_club(p_club_id) then raise exception '권한이 없습니다.'; end if;
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception '산악회 이름을 입력해주세요.'; end if;
  if p_cafe_url is not null and p_cafe_url !~* '^https?://cafe\.daum\.net/' then
    raise exception '다음카페 주소를 확인해주세요.';
  end if;
  update clubs set
    name = trim(p_name),
    payment_hours = greatest(coalesce(p_payment_hours, 48), 1),
    bank_name = nullif(trim(p_bank_name), ''),
    bank_account = nullif(trim(p_bank_account), ''),
    bank_holder = nullif(trim(p_bank_holder), ''),
    cafe_id = nullif(trim(p_cafe_id), ''),
    cafe_url = nullif(trim(p_cafe_url), ''),
    search_query = nullif(trim(p_search_query), '')
  where id = p_club_id;
end $$;

revoke execute on function update_club(bigint, text, int, text, text, text, text, text, text) from public, anon;
grant execute on function update_club(bigint, text, int, text, text, text, text, text, text) to authenticated;
