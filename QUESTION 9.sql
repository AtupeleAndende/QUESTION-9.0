-- ============================================================
-- Q9: FARMER COOPERATIVE MAIZE DELIVERIES
-- ============================================================

-- ---------- (a) DATABASE: TABLES ----------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,     -- set by trigger
    total_value  NUMERIC(14,2) NOT NULL,     -- set by trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

-- ---------- (b) FUNCTION ----------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;
    IF p_grade = 'A' THEN RETURN 5.00;
    ELSIF p_grade = 'B' THEN RETURN 4.00;
    ELSIF p_grade = 'C' THEN RETURN 3.00;
    END IF;
    RAISE EXCEPTION 'Unsupported grade: %', p_grade;
END $$;

-- ---------- (c) PROCEDURE ----------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive';
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;
    PERFORM fn_maize_rate(p_grade);   -- early, clear error for a bad grade

    -- unit_rate and total_value are supplied by the trigger
    INSERT INTO deliveries(farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- ---------- (d) TRIGGER ----------
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_pricing();

-- ---------- (a) SEED DATA (loaded after the trigger) ----------
INSERT INTO farmers(farmer_number, full_name) VALUES
 ('F001','Farmer One'), ('F002','Farmer Two'), ('F003','Farmer Three');

CALL pr_receive_delivery(1, 'A', 200, CURRENT_DATE - 1);   -- unpaid
CALL pr_receive_delivery(2, 'B', 150, CURRENT_DATE - 1);   -- unpaid
CALL pr_receive_delivery(3, 'C', 300, CURRENT_DATE - 2);   -- unpaid

-- Direct SQL follows the same pricing rule (trigger fills rate and value)
INSERT INTO deliveries(farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
 (1, 'B', 100, CURRENT_DATE - 3, TRUE),
 (2, 'A',  80, CURRENT_DATE - 3, TRUE),
 (3, 'A', 120, CURRENT_DATE - 1, TRUE);

-- ---------- (e) VIEW ----------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;

-- ---------- (f) INDEX ----------
-- farmer_id (equality) then delivered_on (range)
CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id, delivered_on);

-- SET enable_seqscan = off;
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- ---------- (g) SCHEDULED JOB ----------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases(purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg),0), COALESCE(SUM(total_value),0)
    FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;  -- replace, not add
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_purchases', '30 1 * * *',
       $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);