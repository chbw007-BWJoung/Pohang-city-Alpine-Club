-- 관리자 좌석 배치표에서 사람 한 명을 다른 빈 좌석으로 이동
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행하세요.

CREATE OR REPLACE FUNCTION admin_move_reserved_person(
  p_reservation_id bigint,
  p_person_index integer,
  p_target_seat_number integer
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  r reservations;
  v_club bigint;
  v_old_seats integer[];
  v_new_seats integer[];
  v_source_seat integer;
  v_target_row integer;
  v_source_row integer;
  v_count integer;
BEGIN
  SELECT * INTO r FROM reservations WHERE id=p_reservation_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION '예약을 찾을 수 없습니다.'; END IF;
  IF r.status NOT IN ('pending','confirmed') THEN RAISE EXCEPTION '진행 중인 예약만 좌석을 이동할 수 있습니다.'; END IF;

  SELECT t.club_id INTO v_club
  FROM buses b JOIN trips t ON t.id=b.trip_id WHERE b.id=r.bus_id FOR UPDATE OF b;
  IF v_club IS NULL OR NOT can_manage_club(v_club) THEN RAISE EXCEPTION '권한이 없습니다.'; END IF;

  v_old_seats := string_to_array(coalesce(r.seat_numbers,''), ',')::integer[];
  IF coalesce(cardinality(v_old_seats),0) <> r.headcount THEN
    RAISE EXCEPTION '예약 인원과 좌석 정보가 일치하지 않습니다.';
  END IF;
  IF p_person_index IS NULL OR p_person_index < 1 OR p_person_index > r.headcount THEN
    RAISE EXCEPTION '이동할 사람 번호가 올바르지 않습니다.';
  END IF;
  IF p_target_seat_number IS NULL OR p_target_seat_number < 1 THEN
    RAISE EXCEPTION '이동할 좌석 번호가 올바르지 않습니다.';
  END IF;

  v_source_seat := v_old_seats[p_person_index];
  IF v_source_seat = p_target_seat_number THEN RETURN; END IF;
  IF p_target_seat_number = ANY(v_old_seats) THEN
    RAISE EXCEPTION '같은 단체의 다른 사람이 사용 중인 좌석입니다. 먼저 그 사람을 빈 좌석으로 이동해주세요.';
  END IF;

  SELECT row_number INTO v_source_row FROM bus_seats
  WHERE bus_id=r.bus_id AND seat_number=v_source_seat FOR UPDATE;
  SELECT row_number, blocked, status INTO v_target_row, v_target_blocked, v_target_status FROM bus_seats
  WHERE bus_id=r.bus_id AND seat_number=p_target_seat_number FOR UPDATE;
  IF v_source_row IS NULL OR v_target_row IS NULL THEN RAISE EXCEPTION '좌석 정보를 찾을 수 없습니다.'; END IF;
  IF v_target_row > 1 AND (coalesce(v_target_blocked,false) OR v_target_status <> 'available') THEN
    RAISE EXCEPTION '이 좌석은 이동할 수 없는 좌석입니다. 빈 일반 좌석을 선택해주세요.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM reservations x
    WHERE x.id<>r.id AND x.bus_id=r.bus_id AND x.status IN ('pending','confirmed')
      AND string_to_array(coalesce(x.seat_numbers,''), ',')::integer[] @> ARRAY[p_target_seat_number]
  ) THEN RAISE EXCEPTION '이동할 좌석은 이미 다른 예약자가 사용 중입니다.'; END IF;

  v_new_seats := v_old_seats;
  v_new_seats[p_person_index] := p_target_seat_number;

  -- 출발 좌석을 비우고, 도착 좌석을 해당 예약 상태로 점유 처리합니다.
  UPDATE bus_seats SET status='available', blocked=(row_number=1)
  WHERE bus_id=r.bus_id AND seat_number=v_source_seat;
  UPDATE bus_seats SET status=CASE WHEN r.status='confirmed' THEN 'confirmed' ELSE 'locked' END,
                        blocked=(row_number=1)
  WHERE bus_id=r.bus_id AND seat_number=p_target_seat_number;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count <> 1 THEN RAISE EXCEPTION '도착 좌석을 갱신하지 못했습니다.'; END IF;

  UPDATE reservations SET seat_numbers=array_to_string(v_new_seats, ',') WHERE id=r.id;
END;
$$;

REVOKE ALL ON FUNCTION admin_move_reserved_person(bigint,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_move_reserved_person(bigint,integer,integer) TO authenticated;
