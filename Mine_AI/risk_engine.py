import numpy as np
import pandas as pd


# --- Thresholds (tune these to your domain/safety standards) ---
METHANE_WARNING, METHANE_CRITICAL = 0.35, 0.80     # % CH4
CO_WARNING, CO_CRITICAL = 10.0, 35.0               # ppm
OXYGEN_WARNING, OXYGEN_CRITICAL = 20.9, 19.5        # % O2 (LOWER is worse)
DUST_WARNING, DUST_CRITICAL = 2.0, 5.0             # mg/m3


def threshold_risk(value, warning, critical):
    """Risk increases as value rises above 'warning' toward 'critical'."""
    if pd.isna(value):
        return 50.0
    if value <= warning:
        return 0.0
    if value >= critical:
        return 100.0
    return 100 * (value - warning) / (critical - warning)


def low_value_risk(value, warning, critical):
    """Risk increases as value FALLS below 'warning' toward 'critical' (e.g. oxygen)."""
    if pd.isna(value):
        return 50.0
    if value >= warning:
        return 0.0
    if value <= critical:
        return 100.0
    return 100 * (warning - value) / (warning - critical)


def calculate_zone_risk(row):
    reasons = []

    methane_risk = threshold_risk(row.get("methane_pct"), METHANE_WARNING, METHANE_CRITICAL)
    co_risk = threshold_risk(row.get("co_ppm"), CO_WARNING, CO_CRITICAL)
    oxygen_risk = low_value_risk(row.get("oxygen_pct"), OXYGEN_WARNING, OXYGEN_CRITICAL)
    dust_risk = threshold_risk(row.get("dust_mg_m3"), DUST_WARNING, DUST_CRITICAL)

    if methane_risk > 0:
        reasons.append(f"Methane risk elevated: {row.get('methane_pct'):.2f}%")
    if co_risk > 0:
        reasons.append(f"CO risk elevated: {row.get('co_ppm'):.1f} ppm")
    if oxygen_risk > 0:
        reasons.append(f"Oxygen level requires attention: {row.get('oxygen_pct'):.2f}%")
    if dust_risk > 0:
        reasons.append(f"Dust level elevated: {row.get('dust_mg_m3'):.2f} mg/m3")

    gas_risk = np.mean([methane_risk, co_risk, oxygen_risk, dust_risk])

    failures = row.get("failure_count_30d", 0) or 0
    equipment_risk = min(100, failures * 30)
    if failures > 0:
        reasons.append(f"{int(failures)} equipment failure(s) in 30 days")

    observations = row.get("observations_48h", 0) or 0
    violation_risk = min(100, observations * 35)
    if observations > 0:
        reasons.append(f"{int(observations)} safety observation(s) in 48 hours")

    incidents = row.get("incidents_90d", 0) or 0
    severity = row.get("recent_incident_severity", 0) or 0
    incident_risk = min(100, incidents * 30 + severity * 10)
    if incidents > 0:
        reasons.append(f"{int(incidents)} incident(s) in the past 90 days")

    overdue = row.get("inspection_overdue_days", 0) or 0
    inspection_risk = min(100, overdue * 30)
    if overdue > 0:
        reasons.append(f"Inspection overdue by {int(overdue)} day(s)")

    risk_score = round(
        0.35 * gas_risk
        + 0.25 * equipment_risk
        + 0.20 * violation_risk
        + 0.10 * incident_risk
        + 0.10 * inspection_risk,
        1,
    )

    if risk_score < 30:
        risk_level = "Low"
    elif risk_score < 60:
        risk_level = "Moderate"
    elif risk_score < 85:
        risk_level = "High"
    else:
        risk_level = "Critical"

    if not reasons:
        reasons.append("No elevated risk factors detected")

    return pd.Series({
        "methane_risk": round(methane_risk, 1),
        "co_risk": round(co_risk, 1),
        "oxygen_risk": round(oxygen_risk, 1),
        "dust_risk": round(dust_risk, 1),
        "gas_risk": round(gas_risk, 1),
        "equipment_risk": equipment_risk,
        "violation_risk": violation_risk,
        "incident_risk": incident_risk,
        "inspection_risk": inspection_risk,
        "risk_score": risk_score,
        "risk_level": risk_level,
        "reasons": reasons,
    })


def check_emergency_conditions(row):
    alerts = []

    if row.get("methane_pct", 0) >= METHANE_CRITICAL:
        alerts.append(f"CRITICAL: Methane at {row['methane_pct']:.2f}% — evacuate zone")

    if row.get("oxygen_pct", 100) <= OXYGEN_CRITICAL:
        alerts.append(f"CRITICAL: Oxygen at {row['oxygen_pct']:.2f}% — below safe minimum")

    if row.get("co_ppm", 0) >= CO_CRITICAL:
        alerts.append(f"CRITICAL: CO at {row['co_ppm']:.1f} ppm — exceeds exposure limit")

    if row.get("equipment_status") == "Failed":
        alerts.append("CRITICAL: Equipment failure reported — halt operations")

    return alerts
