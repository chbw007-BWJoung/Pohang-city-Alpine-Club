-- 기존에 schema.sql을 이미 실행한 프로젝트용 업그레이드 (안내 문자 + 산행공지 링크)
-- 데이터는 유지됩니다. SQL Editor에 통째로 붙여넣고 Run 하세요.
alter table reservations add column if not exists sms_sent_at timestamptz;
alter table trips add column if not exists notice_url text
  check (notice_url is null or notice_url ~* '^https?://');

drop function if exists reserve_seats(bigint, text, text, text, text, int[], text[]);
create or replace function reserve_seats(
  p_bus_id bigint, p_name text, p_phone text, p_depositor text, p_companions text, p_seats int[], p_types text[]
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_count int; v_hours int; v_fr int; v_fg int; v_reg int; v_guest int; v_exp timestamptz; v_amt int; v_id bigint;
begin
  perform release_expired_reservations();
  if coalesce(length(trim(p_name)), 0) = 0 then raise exception '대표 신청자 이름을 입력해주세요.'; end if;
  if length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 9 then
    raise exception '연락처를 정확히 입력해주세요.'; end if;
  if array_length(p_seats, 1) is null or array_length(p_seats, 1) > 4 then
    raise exception '좌석은 1~4개까지 선택할 수 있습니다.'; end if;
  if array_length(p_types, 1) is distinct from array_length(p_seats, 1)
     or exists (select 1 from unnest(p_types) x where x not in ('regular', 'guest')) then
    raise exception '회원 구분(정회원/일일회원)을 확인해주세요.'; end if;

  update bus_seats set status = 'locked'
  where bus_id = p_bus_id and seat_number = any (p_seats) and status = 'available' and row_number > 2;
  get diagnostics v_count = row_count;
  if v_count <> array_length(p_seats, 1) then
    raise exception '이미 예약되었거나 선택할 수 없는 좌석이 있습니다. 좌석을 다시 선택해주세요.'; end if;

  select c.payment_hours, t.fee_regular, t.fee_guest into v_hours, v_fr, v_fg from buses b
    join trips t on t.id = b.trip_id join clubs c on c.id = t.club_id where b.id = p_bus_id;
  select count(*) filter (where x = 'regular'), count(*) filter (where x = 'guest') into v_reg, v_guest from unnest(p_types) x;
  v_exp := now() + make_interval(hours => v_hours);
  v_amt := v_reg * v_fr + v_guest * v_fg;

  insert into reservations (bus_id, main_user_name, phone, depositor_name, headcount, seat_numbers,
                            companion_names, expires_at, amount, member_types)
  values (p_bus_id, trim(p_name), trim(p_phone), nullif(trim(p_depositor), ''), array_length(p_seats, 1),
          array_to_string(p_seats, ','), nullif(trim(p_companions), ''), v_exp, v_amt, array_to_string(p_types, ','))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'expires_at', v_exp, 'amount', v_amt);
end $$;

grant execute on function reserve_seats(bigint, text, text, text, text, int[], text[]) to anon, authenticated;
