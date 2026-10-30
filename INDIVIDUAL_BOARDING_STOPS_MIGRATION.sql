-- 신청자와 동승자별 개별 탑승지 저장 및 예약 RPC 갱신
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS boarding_stops_per_person text[] NOT NULL DEFAULT '{}';

DROP FUNCTION IF EXISTS reserve_seats(bigint, text, text, text, text, int[], text[]);
DROP FUNCTION IF EXISTS reserve_seats(bigint, text, text, text, text, text, int[], text[]);
DROP FUNCTION IF EXISTS reserve_seats(bigint, text, text, text, text, text, text[], int[], text[]);

CREATE OR REPLACE FUNCTION reserve_seats(
  p_bus_id bigint,
  p_name text,
  p_phone text,
  p_depositor text,
  p_companions text,
  p_boarding_stop text,
  p_boarding_stops_per_person text[],
  p_seats int[],
  p_types text[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_count int; v_hours int; v_fr int; v_fg int; v_reg int; v_guest int;
  v_exp timestamptz; v_amt int; v_id bigint; v_mode text; v_post boolean;
BEGIN
  perform pg_advisory_xact_lock(p_bus_id);
  perform release_expired_reservations();

  IF coalesce(length(trim(p_name)), 0) = 0 THEN RAISE EXCEPTION '대표 신청자 이름을 입력해주세요.'; END IF;
  IF length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 9 THEN
    RAISE EXCEPTION '연락처를 정확히 입력해주세요.';
  END IF;
  IF coalesce(array_length(p_boarding_stops_per_person, 1), 0) <> coalesce(array_length(p_seats, 1), 0)
     OR EXISTS (SELECT 1 FROM unnest(p_boarding_stops_per_person) x WHERE coalesce(length(trim(x)), 0) = 0) THEN
    RAISE EXCEPTION '신청자와 동승자 각각의 탑승지를 선택해주세요.';
  END IF;
  IF array_length(p_seats, 1) IS NULL OR array_length(p_seats, 1) > 8 THEN
    RAISE EXCEPTION '좌석은 1~8개까지 선택할 수 있습니다.';
  END IF;
  IF array_length(p_types, 1) IS DISTINCT FROM array_length(p_seats, 1)
     OR EXISTS (SELECT 1 FROM unnest(p_types) x WHERE x NOT IN ('regular','guest')) THEN
    RAISE EXCEPTION '회원 구분(정회원/일일회원)을 확인해주세요.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM buses b JOIN trips t ON t.id=b.trip_id
    WHERE b.id=p_bus_id AND t.trip_date <= now()
  ) THEN
    RAISE EXCEPTION '이미 지난 산행은 신청할 수 없습니다.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM reservations r
    WHERE r.bus_id=p_bus_id AND r.status IN ('pending','confirmed')
      AND string_to_array(r.seat_numbers, ',')::int[] && p_seats
  ) THEN
    RAISE EXCEPTION '이미 예약된 좌석이 포함되어 있습니다. 좌석을 다시 선택해주세요.';
  END IF;

  UPDATE bus_seats
  SET status='locked'
  WHERE bus_id=p_bus_id AND seat_number=ANY(p_seats)
    AND status='available' AND NOT blocked;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count <> array_length(p_seats,1) THEN
    RAISE EXCEPTION '이미 예약되었거나 선택할 수 없는 좌석이 있습니다. 좌석을 다시 선택해주세요.';
  END IF;

  SELECT c.payment_hours, t.fee_regular, t.fee_guest, t.pay_mode
    INTO v_hours, v_fr, v_fg, v_mode
  FROM buses b JOIN trips t ON t.id=b.trip_id JOIN clubs c ON c.id=t.club_id
  WHERE b.id=p_bus_id;

  SELECT count(*) FILTER (WHERE x='regular'), count(*) FILTER (WHERE x='guest')
    INTO v_reg, v_guest FROM unnest(p_types) x;

  v_post := (v_mode='postpaid');
  v_exp := CASE WHEN v_post THEN now() ELSE now()+make_interval(hours=>v_hours) END;
  v_amt := v_reg*v_fr + v_guest*v_fg;

  IF v_post THEN
    UPDATE bus_seats SET status='confirmed'
    WHERE bus_id=p_bus_id AND seat_number=ANY(p_seats);
  END IF;

  INSERT INTO reservations (
    bus_id, main_user_name, phone, depositor_name, headcount, seat_numbers,
    companion_names, boarding_stop, boarding_stops_per_person, expires_at, amount, member_types, status
  ) VALUES (
    p_bus_id, trim(p_name), trim(p_phone), nullif(trim(p_depositor), ''),
    array_length(p_seats,1), array_to_string(p_seats, ','),
    nullif(trim(p_companions), ''), trim(p_boarding_stop), p_boarding_stops_per_person, v_exp, v_amt,
    array_to_string(p_types, ','), CASE WHEN v_post THEN 'confirmed' ELSE 'pending' END
  ) RETURNING id INTO v_id;

  RETURN jsonb_build_object('id',v_id,'expires_at',v_exp,'amount',v_amt,'postpaid',v_post);
END $$;

GRANT EXECUTE ON FUNCTION reserve_seats(bigint,text,text,text,text,text,text[],int[],text[]) TO anon, authenticated;

