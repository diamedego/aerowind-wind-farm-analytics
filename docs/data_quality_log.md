# Data quality log

Every issue found in the raw data, how it was detected, what was done and why.
Row counts come from `data/processed/data_quality_report.csv` (written by `python/clean.py`).

## Issues and decisions

| # | Table | Issue | Detection rule | Rows | Decision | Rationale |
|---|---|---|---|---|---|---|
| 1 | production | 3-4 records for the same turbine-day (T003 and T005 in 2023, T007 in 2024) | `GROUP BY turbine_id, date HAVING COUNT(*) > 1` | 4,019 rows → 1,096 days | **Hours: SUM. Energy: AVG** | Operating and inactive hours add up to 24 h across the records, so they are partial. Each record repeats the full-day energy value, which matches the output of the same-model turbines on that day (ratio 1.0, r = 0.99) |
| 2 | production | Energy above nominal power × 24 h (up to 199% capacity factor) | `energy > nominal_power_kw * 24` | 226 days | Removed | Physically impossible |
| 3 | production | Production before the turbine's installation date | `date < installation_date` | 9 days (20 raw rows) | Removed | A turbine cannot generate before it exists |
| 4 | production | Operating + inactive hours ≠ 24 after consolidation | `ABS(op + inactive - 24) > 0.05` | 3 days | Removed | Incomplete day |
| 5 | weather | Temperature below -20 °C in January (southern-hemisphere summer) | outside [-20, 60] | 3 | Field set to NULL, day kept | Wind data for those days is valid and needed |
| 6 | weather | Missing wind speed | `IS NULL` (after `NULLIF` on load) | 1 | Kept as NULL | Missing value |
| 7 | weather | Relative humidity -69.6 % | outside [0, 100] | 1 | Field set to NULL | Impossible value |
| 8 | weather | Pressure 2,005.5 hPa | outside [900, 1100] | 1 | Field set to NULL | Impossible value (sea level ≈ 1,013 hPa) |
| 9 | price | Negative price (2023-03) and empty price (2023-05) | `<= 0 OR IS NULL` | 2 | Imputed with the same month of 2024 | The tariff repeats an identical monthly profile each year, so every month keeps its revenue |
| 10 | turbines | Nominal power -2,000 kW (T001) | ≠ model rated power (max of power curve) | 1 | Replaced with rated power | Sign error, model known |
| 11 | turbines | Header `nominal_power_mw` but values in kW | Value vs. model spec | whole column | Renamed to `nominal_power_kw` | Units |
| 12 | maintenance | Preventive jobs with empty category | `category IS NULL AND type = 'Preventive'` | 45 | Set to "Preventive without failure" | By design: no failure behind a preventive job |
| 13 | maintenance | Unknown turbine `BAD999` | `LEFT JOIN turbines … IS NULL` | 1 | Removed | Referential integrity |
| 14 | maintenance | Negative cost | `cost_usd <= 0` | 1 | Removed | Loading error |
| 15 | maintenance | Zero duration | `duration_hs <= 0` | 1 | Removed | Not a real job |
| 16 | loader | Comma-delimited files (maintenance, curves); empty numeric fields load as `0` in MySQL | Row inspection after load | n/a | Per-file delimiter; `NULLIF(@var, '')` | Otherwise the null checks can never fire |

## Resulting row counts

| Table | Raw rows | Clean rows |
|---|---|---|
| turbines | 10 | 10 |
| weather | 1,096 | 1,096 (6 fields set to null) |
| production | 10,960 | 7,799 turbine-days |
| maintenance | 109 | 106 |
| price | 36 | 36 (2 imputed) |
| theoretical_curves | 69 | 69 |

## Automated checks

`python/clean.py` ends with assertions that fail the run if any of these is violated:

- One production row per turbine per day, and unique `record_id`
- All `turbine_id`s exist in `turbines`
- Energy ≤ nominal power × 24 h, and operating + inactive hours = 24 h
- No production or maintenance before the installation date
- Maintenance cost and duration > 0, and no empty category
- 36 monthly prices, all positive

## Note on rule 1

The split records carry `record_id`s from other turbines' sequences (e.g. `P006_0069` filed under T003 in 2023, before T006 existed), which points to a routing problem in the source system. The rule applied (AVG energy, SUM hours) is the one consistent with both the hours and the comparison with same-model turbines. In a real engagement it would be confirmed with the data owner.
