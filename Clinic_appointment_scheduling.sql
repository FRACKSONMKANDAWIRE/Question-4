-- =====================================================================
-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Name: ________________ | Student number: ____________ | PostgreSQL 16 (PL/pgSQL)
-- Slots: 09:00, 10:00, 11:00, 12:00. Two non-cancelled appointments may
-- never share the same doctor, date and slot.
-- =====================================================================

DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4;

-- ---------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL
        CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count  INTEGER NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES
    ('Mwila Banda'), ('Natasha Phiri'), ('Chanda Mulenga');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Kunda Sakala'), ('Dr. Bwalya Tembo'), ('Dr. Mutale Zulu');
-- Six appointments are loaded after the trigger in (d) is installed.

-- ---------------------------------------------------------------------
-- (b) Function [6 marks]
-- COUNT(*) returns 0 when the day has no bookings.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure [8 marks]
-- The clash rule itself is enforced by the trigger in (d).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Invalid appointment date: % (past dates are not allowed)', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: %. Use 09:00, 10:00, 11:00 or 12:00.', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE: reject a clash with another non-cancelled
-- appointment. On UPDATE the row being changed is excluded from the
-- search (appointment_id <> NEW.appointment_id). A transaction-level
-- advisory lock per doctor/day stops two sessions booking the same slot
-- at the same moment.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;   -- a cancelled appointment never occupies a slot
    END IF;

    PERFORM pg_advisory_xact_lock(NEW.doctor_id, NEW.appointment_day - DATE '2000-01-01');

    IF EXISTS (
        SELECT 1
        FROM appointments a
        WHERE a.doctor_id       = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time       = NEW.slot_time
          AND a.status         <> 'CANCELLED'
          AND a.appointment_id <> NEW.appointment_id   -- exclude the row being updated
    ) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

-- ---------------------------------------------------------------------
-- (a) continued: six appointments, no slot clashes
-- Yesterday's history is inserted directly (the procedure rejects past
-- dates); the trigger still checks these rows.
-- ---------------------------------------------------------------------
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, TIME '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, TIME '10:00', 'CANCELLED'),
    (3, 2, CURRENT_DATE - 1, TIME '09:00', 'ATTENDED');

CALL pr_book_appointment(2, 1, CURRENT_DATE,     TIME '09:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     TIME '10:00');
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, TIME '11:00');

-- Tests for (b)
SELECT fn_daily_load(1, CURRENT_DATE - 1) AS doc1_yesterday,   -- 1 (cancelled excluded)
       fn_daily_load(1, CURRENT_DATE)     AS doc1_today,       -- 1
       fn_daily_load(3, CURRENT_DATE)     AS doc3_today;       -- 0
-- SELECT fn_daily_load(99, CURRENT_DATE); -- ERROR: Unknown doctor_id

-- Tests for (c)
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, TIME '11:00'); -- ERROR: past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, TIME '13:00'); -- ERROR: unsupported slot
-- CALL pr_book_appointment(99, 1, CURRENT_DATE, TIME '11:00'); -- ERROR: unknown patient

-- Tests for (d)
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, TIME '09:00'); -- ERROR: slot clash
-- UPDATE appointments SET doctor_id = 1, slot_time = TIME '09:00' WHERE appointment_id = 5; -- ERROR: clashes with appointment 4
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;  -- same row: no false clash
-- Re-using a CANCELLED slot is allowed:
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
VALUES (3, 1, CURRENT_DATE - 1, TIME '10:00', 'ATTENDED');
DELETE FROM appointments WHERE appointment_id = 7;   -- undo the demo row (keeps 6 seed rows)
SELECT * FROM appointments ORDER BY appointment_id;

-- ---------------------------------------------------------------------
-- (e) View [5 marks]
-- Only the columns needed for today's list; no other patient data.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT a.appointment_id,
       a.slot_time,
       p.full_name AS patient_name,
       d.full_name AS doctor_name
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- ---------------------------------------------------------------------
-- (f) Index [5 marks]
-- Non-unique composite index (appointment_day, doctor_id). Both columns
-- are equality filters; appointment_day first also supports "all
-- appointments for a day" queries (clinic schedule, daily summary).
-- Non-unique because cancelled rows may legitimately repeat a slot.
-- ---------------------------------------------------------------------
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- demo only: tiny table would otherwise use Seq Scan
EXPLAIN ANALYZE
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;
-- Plan: Index Scan using idx_appointments_day_doctor on appointments
-- Index Cond: ((appointment_day = CURRENT_DATE) AND (doctor_id = 1))

-- ---------------------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM clinic_summary;                       -- yesterday | 0 | 2 | 1

-- Schedule daily at 01:00 for the previous day (requires pg_cron)
ALTER PROCEDURE q4.pr_refresh_clinic_summary(DATE) SET search_path = q4;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $$CALL q4.pr_refresh_clinic_summary((CURRENT_DATE - 1)::date)$$
);
