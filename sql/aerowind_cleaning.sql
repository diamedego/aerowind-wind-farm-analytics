-- =============================================================================
-- AEROWIND - Data cleaning and validation (MySQL 8)
-- -----------------------------------------------------------------------------
-- Raw CSVs (data/raw/) -> validated clean tables -> Power BI.
-- Every rule below is documented in docs/data_quality_log.md and mirrored in
-- python/clean.py, which is the tested reference implementation.
--
-- Before running: replace /path/to/repo with your local clone path and enable
-- LOCAL INFILE (SET GLOBAL local_infile = 1; and allow it in your client).
-- =============================================================================

DROP DATABASE IF EXISTS aerowind;
CREATE DATABASE aerowind;
USE aerowind;

SET SQL_SAFE_UPDATES = 0;

-- =============================================================================
-- 1) RAW TABLES
-- Dates and fields that may arrive empty are loaded as text, then converted.
-- =============================================================================

CREATE TABLE turbines_raw (
    turbine_id        VARCHAR(10),
    model             VARCHAR(50),
    nominal_power_kw  DECIMAL(10,2),   -- source header says "_mw" but values are kW
    location          VARCHAR(100),
    installation_date VARCHAR(20)
);

CREATE TABLE weather_raw (
    date                  VARCHAR(20),
    wind_speed_mps        DECIMAL(5,1),
    temperature_c         DECIMAL(5,1),
    relative_humidity_pct DECIMAL(5,1),
    pressure_hpa          DECIMAL(7,1)
);

CREATE TABLE production_raw (
    record_id            VARCHAR(20),
    turbine_id           VARCHAR(10),
    date                 DATE,
    generated_energy_kwh DECIMAL(12,2),
    operating_hours      DECIMAL(5,2),
    inactive_hours       DECIMAL(5,2),
    year                 INT,
    temperature_c        DECIMAL(5,2)
);

CREATE TABLE maintenance_raw (
    maintenance_id   VARCHAR(30),
    turbine_id       VARCHAR(10),
    maintenance_date DATE,
    maintenance_type VARCHAR(20),
    duration_hs      DECIMAL(5,2),
    cost_usd         DECIMAL(10,2),
    year             INT,
    category         VARCHAR(100)
);

CREATE TABLE price_raw (
    price_id      INT,
    date          VARCHAR(20),
    price_kwh_usd DECIMAL(10,5)
);

CREATE TABLE theoretical_curves_raw (
    model                VARCHAR(50),
    wind_speed_mps       INT,
    theoretical_power_kw INT
);

-- =============================================================================
-- 2) CSV IMPORT
-- Note the delimiters: maintenance and curves use ',', the rest use ';'.
-- Empty numeric fields are captured in a variable and turned into NULL
-- (otherwise MySQL silently loads them as 0 and the null checks miss them).
-- =============================================================================

LOAD DATA LOCAL INFILE '/path/to/repo/data/raw/turbines_raw.csv'
INTO TABLE turbines_raw
FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 LINES
(turbine_id, model, nominal_power_kw, location, installation_date);

LOAD DATA LOCAL INFILE '/path/to/repo/data/raw/weather_raw.csv'
INTO TABLE weather_raw
FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 LINES
(date, @wind, @temp, @hum, @pres)
SET wind_speed_mps        = NULLIF(@wind, ''),
    temperature_c         = NULLIF(@temp, ''),
    relative_humidity_pct = NULLIF(@hum, ''),
    pressure_hpa          = NULLIF(@pres, '');

LOAD DATA LOCAL INFILE '/path/to/repo/data/raw/production_raw.csv'
INTO TABLE production_raw
FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 LINES
(record_id, turbine_id, date, generated_energy_kwh, operating_hours, inactive_hours, year, temperature_c);

LOAD DATA LOCAL INFILE '/path/to/repo/data/raw/maintenance_raw.csv'
INTO TABLE maintenance_raw
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 LINES
(maintenance_id, turbine_id, maintenance_date, maintenance_type, duration_hs, cost_usd, year, @cat)
SET category = NULLIF(@cat, '');

LOAD DATA LOCAL INFILE '/path/to/repo/data/raw/prices_raw.csv'
INTO TABLE price_raw
FIELDS TERMINATED BY ';' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 LINES
(price_id, date, @price)
SET price_kwh_usd = NULLIF(@price, '');

LOAD DATA LOCAL INFILE '/path/to/repo/data/raw/theoretical_curves_raw.csv'
INTO TABLE theoretical_curves_raw
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' LINES TERMINATED BY '\n'
IGNORE 1 LINES
(model, wind_speed_mps, theoretical_power_kw);

-- Initial row counts
SELECT 'turbines_raw' AS table_name, COUNT(*) AS n_rows FROM turbines_raw
UNION ALL SELECT 'weather_raw', COUNT(*) FROM weather_raw
UNION ALL SELECT 'production_raw', COUNT(*) FROM production_raw
UNION ALL SELECT 'maintenance_raw', COUNT(*) FROM maintenance_raw
UNION ALL SELECT 'price_raw', COUNT(*) FROM price_raw
UNION ALL SELECT 'theoretical_curves_raw', COUNT(*) FROM theoretical_curves_raw;

-- =============================================================================
-- 3) DATE STANDARDIZATION  (source format d/m/yy -> DATE)
-- %y (two-digit year) is used on purpose: '2/1/23' -> 2023-01-02.
-- =============================================================================

UPDATE turbines_raw SET installation_date = STR_TO_DATE(TRIM(installation_date), '%e/%c/%y');
ALTER TABLE turbines_raw MODIFY installation_date DATE;

UPDATE weather_raw SET date = STR_TO_DATE(TRIM(date), '%e/%c/%y');
ALTER TABLE weather_raw MODIFY date DATE;

UPDATE price_raw SET date = STR_TO_DATE(TRIM(date), '%e/%c/%y');
ALTER TABLE price_raw MODIFY date DATE;

-- Check: every table must cover 2023-01-01 .. 2025-12-31
SELECT 'turbines' AS t, MIN(installation_date), MAX(installation_date) FROM turbines_raw
UNION ALL SELECT 'weather', MIN(date), MAX(date) FROM weather_raw
UNION ALL SELECT 'production', MIN(date), MAX(date) FROM production_raw
UNION ALL SELECT 'maintenance', MIN(maintenance_date), MAX(maintenance_date) FROM maintenance_raw
UNION ALL SELECT 'price', MIN(date), MAX(date) FROM price_raw;

-- =============================================================================
-- 4) TURBINES
-- =============================================================================

-- Uniqueness: expected 0 rows
SELECT turbine_id, COUNT(*) FROM turbines_raw GROUP BY turbine_id HAVING COUNT(*) > 1;

-- Nominal power must equal the model's rated power (max of its power curve)
SELECT t.turbine_id, t.model, t.nominal_power_kw, c.rated_kw
FROM turbines_raw t
JOIN (SELECT model, MAX(theoretical_power_kw) AS rated_kw FROM theoretical_curves_raw GROUP BY model) c
  ON c.model = t.model
WHERE t.nominal_power_kw <> c.rated_kw;
-- 1 row: T001 = -2000 kW (sign error). Fix with the model's rated power.

UPDATE turbines_raw t
JOIN (SELECT model, MAX(theoretical_power_kw) AS rated_kw FROM theoretical_curves_raw GROUP BY model) c
  ON c.model = t.model
SET t.nominal_power_kw = c.rated_kw
WHERE t.nominal_power_kw IS NULL OR t.nominal_power_kw <= 0;

-- =============================================================================
-- 5) WEATHER  - invalidate the bad FIELD, keep the day
-- Deleting the whole row would also throw away valid wind data for that date.
-- =============================================================================

SELECT date FROM weather_raw GROUP BY date HAVING COUNT(*) > 1;   -- expected 0 rows

SELECT * FROM weather_raw
WHERE wind_speed_mps IS NULL OR wind_speed_mps NOT BETWEEN 0 AND 40
   OR temperature_c IS NULL OR temperature_c NOT BETWEEN -20 AND 60
   OR relative_humidity_pct IS NULL OR relative_humidity_pct NOT BETWEEN 0 AND 100
   OR pressure_hpa IS NULL OR pressure_hpa NOT BETWEEN 900 AND 1100;
-- 6 findings on 4 days: 1 missing wind, 3 temps < -20 °C, 1 humidity < 0 %, 1 pressure of 2005 hPa

UPDATE weather_raw SET wind_speed_mps = NULL        WHERE wind_speed_mps NOT BETWEEN 0 AND 40;
UPDATE weather_raw SET temperature_c = NULL         WHERE temperature_c NOT BETWEEN -20 AND 60;
UPDATE weather_raw SET relative_humidity_pct = NULL WHERE relative_humidity_pct NOT BETWEEN 0 AND 100;
UPDATE weather_raw SET pressure_hpa = NULL          WHERE pressure_hpa NOT BETWEEN 900 AND 1100;

-- =============================================================================
-- 6) PRICE  - impute instead of delete
-- Deleting a month leaves all of that month's energy without a price (revenue = 0).
-- The tariff repeats the same monthly profile every year, so a missing month
-- takes the value of the same month one year later, and is flagged.
-- =============================================================================

ALTER TABLE price_raw ADD COLUMN is_imputed TINYINT NOT NULL DEFAULT 0;

SELECT * FROM price_raw WHERE price_kwh_usd IS NULL OR price_kwh_usd <= 0;
-- 2 rows: 2023-03 (negative) and 2023-05 (empty)

UPDATE price_raw p
JOIN price_raw nxt ON nxt.date = DATE_ADD(p.date, INTERVAL 1 YEAR)
SET p.price_kwh_usd = nxt.price_kwh_usd,
    p.is_imputed = 1
WHERE p.price_kwh_usd IS NULL OR p.price_kwh_usd <= 0;

-- =============================================================================
-- 7) PRODUCTION  - target grain: one row per turbine per day
-- =============================================================================

-- a) Nulls / negatives: expected 0 rows
SELECT COUNT(*) FROM production_raw
WHERE generated_energy_kwh IS NULL OR generated_energy_kwh < 0
   OR operating_hours IS NULL OR operating_hours < 0
   OR inactive_hours IS NULL OR inactive_hours < 0;

-- b) Rows sharing (turbine_id, date)
SELECT turbine_id, COUNT(*) AS split_days
FROM (SELECT turbine_id, date FROM production_raw GROUP BY turbine_id, date HAVING COUNT(*) > 1) d
GROUP BY turbine_id;
-- T003 (2023), T005 (2023) and T007 (2024) have 3-4 records per day.

-- c) Diagnosis: are the fragments partial measurements of the same day?
--    Hours: yes, operating + inactive add up to 24 h ACROSS the fragments.
--    Energy: no, EACH fragment carries a full-day value (~1.0x what the
--    same-model peers produced that day). Summing energy would inflate those
--    turbine-days 3-4x (T003 2023 capacity factor 30% vs 19% for its peers).
SELECT p.turbine_id, p.date,
       COUNT(*)                                 AS fragments,
       SUM(p.operating_hours + p.inactive_hours) AS total_hours,
       SUM(p.generated_energy_kwh)              AS energy_summed,
       AVG(p.generated_energy_kwh)              AS energy_avg,
       (SELECT AVG(q.generated_energy_kwh) FROM production_raw q
         WHERE q.date = p.date AND q.turbine_id IN ('T001','T002','T004')) AS peers_avg
FROM production_raw p
WHERE p.turbine_id = 'T003' AND p.date BETWEEN '2023-03-01' AND '2023-03-07'
GROUP BY p.turbine_id, p.date;

-- d) Consolidation rule: hours -> SUM, energy -> AVG, temperature -> AVG
DROP TABLE IF EXISTS production_daily;
CREATE TABLE production_daily AS
SELECT p.turbine_id,
       p.date,
       COUNT(*)                            AS n_fragments,
       ROUND(AVG(p.generated_energy_kwh), 2) AS generated_energy_kwh,
       SUM(p.operating_hours)              AS operating_hours,
       SUM(p.inactive_hours)               AS inactive_hours,
       ROUND(AVG(p.temperature_c), 2)      AS temperature_c
FROM production_raw p
GROUP BY p.turbine_id, p.date;

-- e) Referential integrity: expected 0 rows
SELECT COUNT(*) FROM production_daily d LEFT JOIN turbines_raw t USING (turbine_id) WHERE t.turbine_id IS NULL;

-- f) Production before installation date -> remove (9 turbine-days)
DELETE d FROM production_daily d
JOIN turbines_raw t USING (turbine_id)
WHERE d.date < t.installation_date;

-- g) A day must add up to 24 h -> remove (3 turbine-days)
DELETE FROM production_daily
WHERE ABS(operating_hours + inactive_hours - 24) > 0.05;

-- h) Energy above nominal power x 24 h is physically impossible -> remove (226 turbine-days)
DELETE d FROM production_daily d
JOIN turbines_raw t USING (turbine_id)
WHERE d.generated_energy_kwh > t.nominal_power_kw * 24;

-- =============================================================================
-- 8) MAINTENANCE
-- =============================================================================

SELECT turbine_id, maintenance_date FROM maintenance_raw
GROUP BY turbine_id, maintenance_date HAVING COUNT(*) > 1;           -- expected 0 rows

-- Preventive jobs have no failure category by design -> standard label (45 rows)
UPDATE maintenance_raw
SET category = 'Preventive without failure'
WHERE maintenance_type = 'Preventive' AND (category IS NULL OR category = '');

-- Unknown turbine (BAD999) -> remove (1 row)
DELETE m FROM maintenance_raw m
LEFT JOIN turbines_raw t USING (turbine_id)
WHERE t.turbine_id IS NULL;

-- Non-positive cost or duration -> remove (1 + 1 rows)
DELETE FROM maintenance_raw WHERE cost_usd IS NULL OR cost_usd <= 0;
DELETE FROM maintenance_raw WHERE duration_hs IS NULL OR duration_hs <= 0;

-- Maintenance before installation: expected 0 rows
SELECT COUNT(*) FROM maintenance_raw m JOIN turbines_raw t USING (turbine_id)
WHERE m.maintenance_date < t.installation_date;

-- =============================================================================
-- 9) CLEAN TABLES (with keys) AND LOAD
-- =============================================================================

CREATE TABLE turbines (
    turbine_id        VARCHAR(10) PRIMARY KEY,
    model             VARCHAR(50) NOT NULL,
    nominal_power_kw  DECIMAL(10,2) NOT NULL CHECK (nominal_power_kw > 0),
    location          VARCHAR(100),
    installation_date DATE NOT NULL
);

CREATE TABLE weather (
    date                  DATE PRIMARY KEY,
    wind_speed_mps        DECIMAL(5,1),
    temperature_c         DECIMAL(5,1),
    relative_humidity_pct DECIMAL(5,1),
    pressure_hpa          DECIMAL(7,1)
);

CREATE TABLE price (
    date          DATE PRIMARY KEY,           -- first day of the month
    price_kwh_usd DECIMAL(10,5) NOT NULL CHECK (price_kwh_usd > 0),
    is_imputed    TINYINT NOT NULL
);

CREATE TABLE theoretical_curves (
    model                VARCHAR(50) NOT NULL,
    wind_speed_mps       INT NOT NULL,
    theoretical_power_kw INT NOT NULL,
    PRIMARY KEY (model, wind_speed_mps)
);

CREATE TABLE production (
    record_id            VARCHAR(20) PRIMARY KEY,
    turbine_id           VARCHAR(10) NOT NULL,
    date                 DATE NOT NULL,
    year                 INT NOT NULL,
    generated_energy_kwh DECIMAL(12,2) NOT NULL,
    operating_hours      DECIMAL(5,2) NOT NULL,
    inactive_hours       DECIMAL(5,2) NOT NULL,
    temperature_c        DECIMAL(5,2),
    n_fragments          INT NOT NULL,
    UNIQUE (turbine_id, date),
    FOREIGN KEY (turbine_id) REFERENCES turbines(turbine_id)
);

CREATE TABLE maintenance (
    maintenance_id   VARCHAR(30) PRIMARY KEY,
    turbine_id       VARCHAR(10) NOT NULL,
    maintenance_date DATE NOT NULL,
    maintenance_type VARCHAR(20) NOT NULL,
    duration_hs      DECIMAL(5,2) NOT NULL CHECK (duration_hs > 0),
    cost_usd         DECIMAL(10,2) NOT NULL CHECK (cost_usd > 0),
    year             INT NOT NULL,
    category         VARCHAR(100) NOT NULL,
    FOREIGN KEY (turbine_id) REFERENCES turbines(turbine_id)
);

INSERT INTO turbines SELECT * FROM turbines_raw;
INSERT INTO weather SELECT * FROM weather_raw;
INSERT INTO price SELECT date, price_kwh_usd, is_imputed FROM price_raw;
INSERT INTO theoretical_curves SELECT * FROM theoretical_curves_raw;

INSERT INTO production
SELECT CONCAT('P', SUBSTRING(turbine_id, 2), '_',
              LPAD(ROW_NUMBER() OVER (PARTITION BY turbine_id ORDER BY date), 4, '0')),
       turbine_id, date, YEAR(date), generated_energy_kwh,
       operating_hours, inactive_hours, temperature_c, n_fragments
FROM production_daily;

INSERT INTO maintenance
SELECT maintenance_id, turbine_id, maintenance_date, maintenance_type,
       duration_hs, cost_usd, year, category
FROM maintenance_raw;

-- Final counts (expected: 10 / 1096 / 7799 / 106 / 36 / 69)
SELECT 'turbines' AS table_name, COUNT(*) AS n_rows FROM turbines
UNION ALL SELECT 'weather', COUNT(*) FROM weather
UNION ALL SELECT 'production', COUNT(*) FROM production
UNION ALL SELECT 'maintenance', COUNT(*) FROM maintenance
UNION ALL SELECT 'price', COUNT(*) FROM price
UNION ALL SELECT 'theoretical_curves', COUNT(*) FROM theoretical_curves;

-- =============================================================================
-- 10) CLEANUP
-- The clean tables can be read by Power BI directly (MySQL connector) or
-- exported to CSV; the repository ships them in data/processed/.
-- =============================================================================

DROP TABLE turbines_raw, weather_raw, production_raw, maintenance_raw,
           price_raw, theoretical_curves_raw, production_daily;

SET SQL_SAFE_UPDATES = 1;
