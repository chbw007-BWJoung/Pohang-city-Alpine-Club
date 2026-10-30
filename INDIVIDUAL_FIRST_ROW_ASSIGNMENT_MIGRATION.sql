-- 단체 예약의 인원별 1열 개별 배정 및 개별 취소
-- Supabase SQL Editor에서 이 파일 전체를 한 번 실행하세요.

CREATE OR REPLACE FUNCTION assign_first_row_people(
  p_reservation_id bigint,
  p_person_indexes int[],
  p_seat_numbers int[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  r reservations;
  v_type text;
  v_club bigint;
  v_capacity int;
  v_old_seats int[];
  v_new_seats int[];
  v_i int;
  v_person int;
  v_seat int;
  v_count int;
BEGIN
  SELECT * INTO r FROM reservations WHERE id=p_reservation_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION '예약을 찾을 수 없습니다.'; END IF;
  IF r.status NOT IN ('pending','confirmed') THEN RAISE EXCEPTION '진행 중인 예약만 1열을 배정할 수 있습니다.'; END IF;

  SELECT b.vehicle_type,t.club_id INTO v_type,v_club
  FROM buses b JOIN trips t ON t.id=b.trip_id WHERE b.id=r.bus_id FOR UPDATE OF b;
  IF v_type NOT IN ('bus45','bus28') THEN RAISE EXCEPTION '1열 개별 배정은 45인승·28인승 버스에서만 사용할 수 있습니다.'; END IF;
  IF v_club IS NULL OR NOT can_manage_club(v_club) THEN RAISE EXCEPTION '권한이 없습니다.'; END IF;

  v_capacity := CASE WHEN v_type='bus28' THEN 3 ELSE 4 END;
  v_old_seats := string_to_array(coalesce(r.seat_numbers,''), ',')::int[];
  IF coalesce(cardinality(v_old_seats),0) <> r.headcount THEN
    RAISE EXCEPTION '예약 인원과 기존 좌석 정보가 일치하지 않습니다.';
  END IF;
  IF p_person_indexes IS NULL OR p_seat_numbers IS NULL
     OR cardinality(p_person_indexes)=0
     OR cardinality(p_person_indexes) IS DISTINCT FROM cardinality(p_seat_numbers) THEN
    RAISE EXCEPTION '배정할 사람 번호와 좌석 번호를 같은 개수로 입력해주세요.';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_person_indexes) x WHERE x<1 OR x>r.headcount) THEN
    RAISE EXCEPTION '사람 번호는 예약 인원 범위 안에서 선택해주세요.';
  END IF;
  IF (SELECT count(*) FROM unnest(p_person_indexes)) <> (SELECT count(DISTINCT x) FROM unnest(p_person_indexes) x) THEN
    RAISE EXCEPTION '같은 사람을 중복 선택할 수 없습니다.';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_seat_numbers) x WHERE x<1 OR x>v_capacity) THEN
    RAISE EXCEPTION '1열 좌석번호를 확인해주세요.';
  END IF;
  IF (SELECT count(*) FROM unnest(p_seat_numbers)) <> (SELECT count(DISTINCT x) FROM unnest(p_seat_numbers) x) THEN
    RAISE EXCEPTION '같은 1열 좌석을 중복 지정할 수 없습니다.';
  END IF;

  v_new_seats := v_old_seats;
  FOR v_i IN 1..cardinality(p_person_indexes) LOOP
    v_person := p_person_indexes[v_i];
    v_seat := p_seat_numbers[v_i];
    v_new_seats[v_person] := v_seat;
  END LOOP;
  IF (SELECT count(*) FROM unnest(v_new_seats)) <> (SELECT count(DISTINCT x) FROM unnest(v_new_seats) x) THEN
    RAISE EXCEPTION '같은 좌석에 두 명을 배정할 수 없습니다. 기존 좌석과 겹치지 않게 선택해주세요.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM unnest(p_seat_numbers) wanted(n)
    LEFT JOIN bus_seats s ON s.bus_id=r.bus_id AND s.seat_number=wanted.n AND s.row_number=1
    WHERE s.seat_number IS NULL
  ) THEN RAISE EXCEPTION '선택한 좌석이 이 버스의 1열 좌석이 아닙니다.'; END IF;

  IF EXISTS (
    SELECT 1 FROM reservations x
    WHERE x.id<>r.id AND x.bus_id=r.bus_id AND x.status IN ('pending','confirmed')
      AND string_to_array(x.seat_numbers, ',')::int[] && p_seat_numbers
  ) THEN RAISE EXCEPTION '선택한 1열 좌석 중 다른 신청자에게 배정된 좌석이 있습니다.'; END IF;

  -- 선택한 사람의 기존 좌석 중 새 좌석 배열에서 빠진 좌석만 비웁니다.
  UPDATE bus_seats s
  SET status='available'
  WHERE s.bus_id=r.bus_id
    AND s.seat_number = ANY(ARRAY(SELECT v_old_seats[u.person_idx] FROM unnest(p_person_indexes) AS u(person_idx)))
    AND NOT (s.seat_number = ANY(v_new_seats));

  UPDATE bus_seats
  SET status=CASE WHEN r.status='confirmed' THEN 'confirmed' ELSE 'locked' END,
      blocked=true
  WHERE bus_id=r.bus_id AND seat_number=ANY(p_seat_numbers) AND row_number=1;
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count <> cardinality(p_seat_numbers) THEN RAISE EXCEPTION '1열 좌석을 배정하지 못했습니다.'; END IF;

  UPDATE reservations SET seat_numbers=array_to_string(v_new_seats,',') WHERE id=r.id;
END;
$$;

CREATE OR REPLACE FUNCTION unassign_first_row_people(
  p_reservation_id bigint,
  p_person_indexes int[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  r reservations;
  v_type text;
  v_club bigint;
  v_capacity int;
  v_old_seats int[];
  v_new_seats int[];
  v_people int[];
  v_general int[];
  v_person int;
  v_i int;
BEGIN
  SELECT * INTO r FROM reservations WHERE id=p_reservation_id FOR UPDATE;
  IF r.id IS NULL THEN RAISE EXCEPTION '예약을 찾을 수 없습니다.'; END IF;
  IF r.status NOT IN ('pending','confirmed') THEN RAISE EXCEPTION '진행 중인 예약만 배정을 변경할 수 있습니다.'; END IF;

  SELECT b.vehicle_type,t.club_id INTO v_type,v_club
  FROM buses b JOIN trips t ON t.id=b.trip_id WHERE b.id=r.bus_id FOR UPDATE OF b;
  IF v_type NOT IN ('bus45','bus28') THEN RAISE EXCEPTION '1열 개별 배정 취소는 45인승·28인승 버스에서만 사용할 수 있습니다.'; END IF;
  IF v_club IS NULL OR NOT can_manage_club(v_club) THEN RAISE EXCEPTION '권한이 없습니다.'; END IF;

  v_capacity := CASE WHEN v_type='bus28' THEN 3 ELSE 4 END;
  v_old_seats := string_to_array(coalesce(r.seat_numbers,''), ',')::int[];
  IF coalesce(cardinality(v_old_seats),0) <> r.headcount THEN RAISE EXCEPTION '예약 인원과 좌석 정보가 일치하지 않습니다.'; END IF;
  IF p_person_indexes IS NULL OR cardinality(p_person_indexes)=0 THEN RAISE EXCEPTION '일반 좌석으로 이동할 사람 번호를 입력해주세요.'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(p_person_indexes) x WHERE x<1 OR x>r.headcount) THEN RAISE EXCEPTION '사람 번호를 확인해주세요.'; END IF;
  IF (SELECT count(*) FROM unnest(p_person_indexes)) <> (SELECT count(DISTINCT x) FROM unnest(p_person_indexes) x) THEN RAISE EXCEPTION '같은 사람을 중복 선택할 수 없습니다.'; END IF;

  v_people := p_person_indexes;
  FOREACH v_person IN ARRAY v_people LOOP
    IF v_old_seats[v_person] < 1 OR v_old_seats[v_person] > v_capacity THEN
      RAISE EXCEPTION '%번 사람은 현재 1열에 배정되어 있지 않습니다.', v_person;
    END IF;
  END LOOP;

  -- 비어 있는 일반 좌석을 필요한 수만큼 잠금 후 확보합니다.
  WITH chosen AS (
    SELECT seat_number FROM bus_seats
    WHERE bus_id=r.bus_id AND row_number>1 AND blocked=false AND status='available'
    ORDER BY row_number,seat_number
    FOR UPDATE SKIP LOCKED
    LIMIT cardinality(v_people)
  )
  SELECT array_agg(seat_number ORDER BY seat_number) INTO v_general FROM chosen;
  IF coalesce(cardinality(v_general),0) <> cardinality(v_people) THEN
    RAISE EXCEPTION '재배정할 빈 일반 좌석이 부족합니다. 기존 배정은 변경하지 않았습니다.';
  END IF;

  v_new_seats := v_old_seats;
  FOR v_i IN 1..cardinality(v_people) LOOP
    v_person := v_people[v_i];
    v_new_seats[v_person] := v_general[v_i];
  END LOOP;

  UPDATE bus_seats SET status='available'
  WHERE bus_id=r.bus_id AND seat_number=ANY(ARRAY(SELECT v_old_seats[u.person_idx] FROM unnest(v_people) AS u(person_idx))) AND row_number=1;

  UPDATE bus_seats s
  SET status=CASE WHEN r.status='confirmed' THEN 'confirmed' ELSE 'locked' END
  WHERE s.bus_id=r.bus_id AND s.seat_number=ANY(v_general) AND s.row_number>1;

  UPDATE reservations SET seat_numbers=array_to_string(v_new_seats,',') WHERE id=r.id;
END;
$$;

REVOKE ALL ON FUNCTION assign_first_row_people(bigint,int[],int[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION assign_first_row_people(bigint,int[],int[]) TO authenticated;
REVOKE ALL ON FUNCTION unassign_first_row_people(bigint,int[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION unassign_first_row_people(bigint,int[]) TO authenticated;
