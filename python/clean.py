"""
Aerowind - raw -> processed data pipeline with data-quality checks.

Reads the six raw CSVs in data/raw/, applies the cleaning rules documented in
docs/data_quality_log.md, writes the clean tables to data/processed/ in the format
the Power BI model reads (so a refresh picks them up directly) and a
machine-readable data-quality report (data/processed/data_quality_report.csv).

The same rules are implemented in MySQL in sql/aerowind_cleaning.sql; this
script is the reproducible, tested reference implementation.

Usage:  python python/clean.py
"""
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
OUT = ROOT / "data" / "processed"

dq_log = []  # one row per check: table, check, rows_affected, action


def log(table, check, rows, action):
    dq_log.append({"table": table, "check": check, "rows_affected": int(rows), "action": action})
    print(f"  [{table:<12}] {check:<58} {int(rows):>6}  -> {action}")


def parse_dmy(s):
    """Raw files store dates as d/m/yy (e.g. 2/1/23 = 2 Jan 2023)."""
    return pd.to_datetime(s.str.strip(), format="%d/%m/%y")


# --------------------------------------------------------------------------- #
# Theoretical power curves (reference table)
# --------------------------------------------------------------------------- #
def clean_curves():
    df = pd.read_csv(RAW / "theoretical_curves_raw.csv")
    log("curves", "rows loaded", len(df), "-")
    log("curves", "duplicate (model, wind_speed)", df.duplicated(["model", "wind_speed_mps"]).sum(), "none found")
    log("curves", "negative speed or power", ((df.wind_speed_mps < 0) | (df.theoretical_power_kw < 0)).sum(), "none found")
    return df


# --------------------------------------------------------------------------- #
# Turbines (dimension)
# --------------------------------------------------------------------------- #
def clean_turbines(curves):
    df = pd.read_csv(RAW / "turbines_raw.csv", sep=";")
    log("turbines", "rows loaded", len(df), "-")
    # Header says MW but values are kW (2000 = 2 MW V100) -> rename
    df = df.rename(columns={"nominal_power_mw": "nominal_power_kw"})
    df["installation_date"] = parse_dmy(df.installation_date)

    rated = curves.groupby("model").theoretical_power_kw.max()
    bad = df.nominal_power_kw <= 0
    log("turbines", "nominal power <= 0", bad.sum(), "replaced with model rated power (from power curve)")
    df.loc[bad, "nominal_power_kw"] = df.loc[bad, "model"].map(rated)

    mismatch = df.nominal_power_kw != df.model.map(rated)
    log("turbines", "nominal power != model rated power", mismatch.sum(), "none left")
    log("turbines", "duplicate turbine_id", df.turbine_id.duplicated().sum(), "none found")
    return df


# --------------------------------------------------------------------------- #
# Weather (dimension, 1 row per day)
# --------------------------------------------------------------------------- #
def clean_weather():
    df = pd.read_csv(RAW / "weather_raw.csv", sep=";")
    log("weather", "rows loaded", len(df), "-")
    df["date"] = parse_dmy(df.date)
    log("weather", "duplicate date", df.date.duplicated().sum(), "none found")

    # Invalidate the bad FIELD, keep the day: wind data on those days is still valid.
    rules = {
        "wind_speed_mps": (0, 40),
        "temperature_c": (-20, 60),
        "relative_humidity_pct": (0, 100),
        "pressure_hpa": (900, 1100),
    }
    for col, (lo, hi) in rules.items():
        bad = df[col].isna() | (df[col] < lo) | (df[col] > hi)
        log("weather", f"{col} missing or outside [{lo}, {hi}]", bad.sum(), "set to NULL, row kept")
        df.loc[bad, col] = np.nan
    return df


# --------------------------------------------------------------------------- #
# Price (dimension, 1 row per month)
# --------------------------------------------------------------------------- #
def clean_price():
    df = pd.read_csv(RAW / "prices_raw.csv", sep=";")
    log("price", "rows loaded", len(df), "-")
    df["date"] = parse_dmy(df.date)
    df["is_imputed"] = False

    bad = df.price_kwh_usd.isna() | (df.price_kwh_usd <= 0)
    # The tariff follows the same monthly profile every year, so a missing month
    # is imputed with the same month of the following year (instead of deleting
    # it, which would zero out revenue for that month).
    same_month_next_year = df.set_index(df.date + pd.DateOffset(years=-1)).price_kwh_usd
    df.loc[bad, "price_kwh_usd"] = df.loc[bad, "date"].map(same_month_next_year)
    df.loc[bad, "is_imputed"] = True
    log("price", "price missing or <= 0", bad.sum(), "imputed with same month of next year (flagged)")
    log("price", "months after imputation", len(df), "36 expected (2023-2025)")
    return df.drop(columns="price_id")


# --------------------------------------------------------------------------- #
# Production (fact, target grain = 1 row per turbine per day)
# --------------------------------------------------------------------------- #
def clean_production(turbines):
    df = pd.read_csv(RAW / "production_raw.csv", sep=";", parse_dates=["date"])
    log("production", "rows loaded", len(df), "-")

    null_or_neg = df[["generated_energy_kwh", "operating_hours", "inactive_hours"]].lt(0).any(axis=1) | df.isna().any(axis=1)
    log("production", "null or negative energy / hours", null_or_neg.sum(), "none found")

    dup = df.duplicated(["turbine_id", "date"], keep=False)
    log("production", "rows sharing (turbine_id, date) with another row", dup.sum(), "investigated, see below")

    # Diagnosis: on split days each fragment's operating+inactive hours add up to
    # 24 h across fragments (partial measurements), but EACH fragment carries a
    # full-day energy value (~1.0x the peer turbines' output, r = 0.99).
    # Summing energy would inflate those days 3-4x. Rule:
    #   hours  -> SUM   (they are genuinely split)
    #   energy -> AVG   (every fragment repeats the daily meter value)
    daily = (
        df.groupby(["turbine_id", "date"], as_index=False)
        .agg(
            n_fragments=("record_id", "size"),
            generated_energy_kwh=("generated_energy_kwh", "mean"),
            operating_hours=("operating_hours", "sum"),
            inactive_hours=("inactive_hours", "sum"),
            temperature_c=("temperature_c", "mean"),
        )
    )
    log("production", "turbine-days after consolidation", len(daily), "-")

    daily = daily.merge(turbines[["turbine_id", "nominal_power_kw", "installation_date"]], on="turbine_id", how="left")
    orphan = daily.nominal_power_kw.isna()
    log("production", "turbine_id not in turbines table", orphan.sum(), "none found")

    pre = daily.date < daily.installation_date
    log("production", "production before installation date", pre.sum(), "removed")
    daily = daily[~pre]

    hours = daily.operating_hours + daily.inactive_hours
    bad_hours = (hours - 24).abs() > 0.05
    log("production", "operating + inactive hours != 24", bad_hours.sum(), "removed")
    daily = daily[~bad_hours]

    over = daily.generated_energy_kwh > daily.nominal_power_kw * 24
    log("production", "energy > nominal power x 24 h (physically impossible)", over.sum(), "removed")
    daily = daily[~over]

    daily = daily.sort_values(["turbine_id", "date"]).reset_index(drop=True)
    daily["record_id"] = (
        "P" + daily.turbine_id.str[1:] + "_" + (daily.groupby("turbine_id").cumcount() + 1).astype(str).str.zfill(4)
    )
    daily["year"] = daily.date.dt.year
    # Source values have 2 decimals; round the aggregates to drop floating-point noise
    for col in ["generated_energy_kwh", "operating_hours", "inactive_hours", "temperature_c"]:
        daily[col] = daily[col].round(2)
    log("production", "final rows", len(daily), "-")
    cols = ["record_id", "turbine_id", "date", "year", "generated_energy_kwh",
            "operating_hours", "inactive_hours", "temperature_c", "n_fragments"]
    return daily[cols]


# --------------------------------------------------------------------------- #
# Maintenance (fact)
# --------------------------------------------------------------------------- #
def clean_maintenance(turbines):
    df = pd.read_csv(RAW / "maintenance_raw.csv", parse_dates=["maintenance_date"])
    log("maintenance", "rows loaded", len(df), "-")
    log("maintenance", "duplicate (turbine_id, date)", df.duplicated(["turbine_id", "maintenance_date"]).sum(), "none found")

    empty_cat = df.category.isna() & (df.maintenance_type == "Preventive")
    log("maintenance", "preventive with empty category", empty_cat.sum(), "set to 'Preventive without failure'")
    df.loc[empty_cat, "category"] = "Preventive without failure"
    log("maintenance", "corrective with empty category", (df.category.isna()).sum(), "none found")

    orphan = ~df.turbine_id.isin(turbines.turbine_id)
    log("maintenance", "turbine_id not in turbines table", orphan.sum(), "removed")
    df = df[~orphan]

    neg_cost = df.cost_usd <= 0
    log("maintenance", "cost <= 0", neg_cost.sum(), "removed")
    df = df[~neg_cost]

    zero_dur = df.duration_hs <= 0
    log("maintenance", "duration <= 0", zero_dur.sum(), "removed")
    df = df[~zero_dur]

    inst = df.turbine_id.map(turbines.set_index("turbine_id").installation_date)
    pre = df.maintenance_date < inst
    log("maintenance", "maintenance before installation date", pre.sum(), "removed")
    df = df[~pre]

    year_mismatch = df.year != df.maintenance_date.dt.year
    log("maintenance", "year column != year of maintenance_date", year_mismatch.sum(), "none found")
    log("maintenance", "final rows", len(df), "-")
    return df.sort_values(["turbine_id", "maintenance_date"]).reset_index(drop=True)


# --------------------------------------------------------------------------- #
# Post-conditions: the pipeline fails loudly if a rule is violated
# --------------------------------------------------------------------------- #
def assert_quality(t, w, p, m, pr, c):
    assert t.turbine_id.is_unique and (t.nominal_power_kw > 0).all()
    assert w.date.is_unique
    assert not p.duplicated(["turbine_id", "date"]).any(), "production grain violated"
    assert p.record_id.is_unique
    assert p.turbine_id.isin(t.turbine_id).all() and m.turbine_id.isin(t.turbine_id).all()
    nominal = p.turbine_id.map(t.set_index("turbine_id").nominal_power_kw)
    assert (p.generated_energy_kwh <= nominal * 24).all()
    assert ((p.operating_hours + p.inactive_hours - 24).abs() <= 0.05).all()
    inst = t.set_index("turbine_id").installation_date
    assert (p.date >= p.turbine_id.map(inst)).all() and (m.maintenance_date >= m.turbine_id.map(inst)).all()
    assert (m.cost_usd > 0).all() and (m.duration_hs > 0).all() and m.category.notna().all()
    assert len(pr) == 36 and (pr.price_kwh_usd > 0).all() and pr.date.is_unique
    assert not c.duplicated(["model", "wind_speed_mps"]).any()
    print("\nAll data-quality assertions passed.")


def write_table(df, name, columns, decimals=None, quoted=()):
    """Write a table in the format the Power BI model reads: ';'-separated, surrogate
    `id` first, fixed decimals, and strings with spaces quoted in `quoted` columns."""
    decimals = decimals or {}
    lines = [";".join(["id", *columns])]
    for i, row in enumerate(df[columns].itertuples(index=False), start=1):
        cells = [str(i)]
        for col, val in zip(columns, row):
            if pd.isna(val):
                cells.append("")
            elif isinstance(val, pd.Timestamp):
                cells.append(val.strftime("%Y-%m-%d"))
            elif col in decimals:
                cells.append(f"{val:.{decimals[col]}f}")
            else:
                text = str(val)
                cells.append(f'"{text}"' if col in quoted and " " in text else text)
        lines.append(";".join(cells))
    (OUT / name).write_text("\n".join(lines) + "\n")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    print("Data-quality checks\n" + "-" * 100)
    curves = clean_curves()
    turbines = clean_turbines(curves)
    weather = clean_weather()
    price = clean_price()
    production = clean_production(turbines)
    maintenance = clean_maintenance(turbines)
    assert_quality(turbines, weather, production, maintenance, price, curves)

    for old in OUT.glob("*.csv"):  # file names are case-insensitive on macOS/Windows
        old.unlink()
    two = lambda *cols: {c: 2 for c in cols}
    write_table(turbines, "Turbines.csv",
                ["turbine_id", "model", "nominal_power_kw", "location", "installation_date"],
                two("nominal_power_kw"), quoted=("model", "location"))
    write_table(weather, "Weather.csv",
                ["date", "wind_speed_mps", "temperature_c", "relative_humidity_pct", "pressure_hpa"],
                two("wind_speed_mps", "temperature_c", "relative_humidity_pct", "pressure_hpa"))
    write_table(production, "Production.csv",
                ["record_id", "turbine_id", "date", "generated_energy_kwh", "operating_hours",
                 "inactive_hours", "year", "temperature_c"],
                two("generated_energy_kwh", "operating_hours", "inactive_hours", "temperature_c"))
    write_table(maintenance, "Maintenance.csv",
                ["maintenance_id", "turbine_id", "maintenance_date", "maintenance_type", "duration_hs",
                 "cost_usd", "year", "category"],
                two("duration_hs", "cost_usd"))
    write_table(price, "Price.csv", ["date", "price_kwh_usd"], {"price_kwh_usd": 5})
    write_table(curves, "Theoretical Curves.csv", ["model", "wind_speed_mps", "theoretical_power_kw"],
                quoted=("model",))
    pd.DataFrame(dq_log).to_csv(OUT / "data_quality_report.csv", index=False)
    print(f"Processed tables written to {OUT.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
