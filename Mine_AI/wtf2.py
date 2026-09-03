"""
MineRisk — real satellite-photo heatmap (Leaflet).

Produces a single HTML file with an actual ESRI World Imagery satellite photo
of the mine site, a risk heat-blob overlay (green -> orange -> red), zone
labels/popups, a legend, and a scale bar. Since Leaflet loads map tiles
client-side in your browser when you open the file, this works over any
normal internet connection — no Python-side tile-fetching required.

Requirements:
    pip install pandas

Usage:
    python generate_leaflet_map.py
    -> open minerisk_satellite_heatmap.html in your browser
"""

import json
import pandas as pd

from risk_engine import calculate_zone_risk, check_emergency_conditions


def load_scored_zones():
    current_df = pd.read_csv("current_zone_data.csv")
    precomputed_cols = [
        "methane_risk", "co_risk", "oxygen_risk", "dust_risk", "gas_risk",
        "equipment_risk", "violation_risk", "incident_risk", "inspection_risk",
        "risk_score", "risk_level", "reasons",
    ]
    current_df = current_df.drop(columns=[c for c in precomputed_cols if c in current_df.columns])

    risk_results = current_df.apply(calculate_zone_risk, axis=1)
    scored_df = pd.concat([current_df.reset_index(drop=True), risk_results.reset_index(drop=True)], axis=1)
    scored_df["emergency_alerts"] = scored_df.apply(check_emergency_conditions, axis=1)
    return scored_df


LEVEL_COLOR = {"Low": "#1a9850", "Moderate": "#fdae61", "High": "#d73027", "Critical": "#7f0000"}


def build_zone_records(scored_df):
    records = []
    for _, row in scored_df.iterrows():
        records.append({
            "zone_id": row["zone_id"],
            "name": row["zone_name"],
            "lat": row["latitude"],
            "lon": row["longitude"],
            "risk_score": row["risk_score"],
            "risk_level": row["risk_level"],
            "color": LEVEL_COLOR.get(row["risk_level"], "#999999"),
            "methane_pct": row["methane_pct"],
            "co_ppm": row["co_ppm"],
            "oxygen_pct": row["oxygen_pct"],
            "worker_count": int(row["worker_count"]),
            "reasons": row["reasons"],
            "alerts": row["emergency_alerts"],
            "components": {
                "Gas": row["gas_risk"],
                "Equipment": row["equipment_risk"],
                "Safety observations": row["violation_risk"],
                "Incident history": row["incident_risk"],
                "Inspection overdue": row["inspection_risk"],
            },
        })
    return records


HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<title>MineRisk Satellite Heatmap</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script src="https://cdn.jsdelivr.net/npm/leaflet.heat@0.2.0/dist/leaflet-heat.js"></script>
<style>
  html, body { margin:0; padding:0; height:100%; font-family:'Segoe UI', Arial, sans-serif; }
  #map { width:100%; height:100vh; background:#111; }

  .legend-box {
    background: rgba(20,20,20,0.85);
    color:#fff; padding:12px 16px; border-radius:6px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.5);
    font-size:13px; line-height:1.6; min-width:190px;
  }
  .legend-box h4 { margin:0 0 8px 0; font-size:13px; letter-spacing:0.5px; }
  .legend-row { display:flex; align-items:center; gap:8px; margin:3px 0; }
  .swatch { width:16px; height:16px; border-radius:3px; display:inline-block; border:1px solid rgba(255,255,255,0.3);}

  .title-box {
    background: rgba(20,20,20,0.85); color:#fff; padding:10px 18px;
    border-radius:6px; box-shadow: 0 2px 8px rgba(0,0,0,0.5);
  }
  .title-box h2 { margin:0; font-size:16px; }
  .title-box .sub { font-size:11px; color:#ccc; margin-top:2px; }

  .zone-label {
    background: rgba(0,0,0,0.65); color:#fff; font-weight:700; font-size:11px;
    padding:2px 6px; border-radius:3px; white-space:nowrap; border:none; box-shadow:none;
  }
  .zone-label::before { display:none; }

  .leaflet-popup-content { font-size:12.5px; line-height:1.5; min-width:220px; }
  .leaflet-popup-content h3 { margin:0 0 4px 0; font-size:14px; }
  .risk-pill {
    display:inline-block; padding:2px 8px; border-radius:10px; color:#fff;
    font-weight:700; font-size:11px; margin-bottom:6px;
  }
  .alert-line { color:#c0392b; font-weight:600; }
  .reason-line { color:#555; }
</style>
</head>
<body>
<div id="map"></div>

<script>
const zones = __ZONE_DATA__;

const map = L.map('map', { zoomControl: true }).setView([__CENTER_LAT__, __CENTER_LON__], 15);

// Real ESRI World Imagery satellite basemap (loads directly in your browser)
const satellite = L.tileLayer(
  'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
  { attribution: 'Tiles &copy; Esri', maxZoom: 19 }
).addTo(map);

// Optional road/label reference overlay for context
const labels = L.tileLayer(
  'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
  { attribution: 'Esri', maxZoom: 19, opacity: 0.9 }
).addTo(map);

// Fallback plain street layer, selectable via layer control
const streets = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  attribution: '&copy; OpenStreetMap contributors', maxZoom: 19
});

L.control.layers({ "Satellite": satellite, "Streets": streets }, {}, { position: 'topright' }).addTo(map);

// --- Risk heat-blob overlay ---
const heatPoints = zones.map(z => [z.lat, z.lon, Math.max(z.risk_score / 100, 0.08)]);
const heat = L.heatLayer(heatPoints, {
  radius: 65,
  blur: 55,
  maxZoom: 17,
  max: 1.0,
  gradient: { 0.0: '#1a9850', 0.3: '#66bd63', 0.5: '#fee08b', 0.7: '#fdae61', 0.85: '#f46d43', 1.0: '#7f0000' }
}).addTo(map);

// --- Zone markers, labels, popups ---
zones.forEach(z => {
  const marker = L.circleMarker([z.lat, z.lon], {
    radius: 6, color: '#fff', weight: 1.5, fillColor: z.color, fillOpacity: 0.95
  }).addTo(map);

  marker.bindTooltip(z.name.toUpperCase(), {
    permanent: true, direction: 'top', offset: [0, -8], className: 'zone-label'
  });

  let reasonsHtml = z.reasons.map(r => `<div class="reason-line">&bull; ${r}</div>`).join('');
  let alertsHtml = z.alerts.length
    ? z.alerts.map(a => `<div class="alert-line">${a}</div>`).join('')
    : '<div style="color:#2e7d32;">No emergency-rule condition detected.</div>';

  marker.bindPopup(`
    <h3>${z.name}</h3>
    <span class="risk-pill" style="background:${z.color};">${z.risk_level} &middot; ${z.risk_score}/100</span>
    <div>Methane: ${z.methane_pct}% &nbsp;|&nbsp; CO: ${z.co_ppm} ppm &nbsp;|&nbsp; O2: ${z.oxygen_pct}%</div>
    <div>Workers on site: ${z.worker_count}</div>
    <hr style="margin:6px 0;">
    <b>Why:</b>${reasonsHtml}
    <hr style="margin:6px 0;">
    <b>Safety status:</b>${alertsHtml}
  `);
});

// --- Legend ---
const legend = L.control({ position: 'bottomright' });
legend.onAdd = function () {
  const div = L.DomUtil.create('div', 'legend-box');
  div.innerHTML = `
    <h4>RISK ASSESSMENT HEATMAP</h4>
    <div class="legend-row"><span class="swatch" style="background:#d73027;"></span> RED: High / Critical Risk</div>
    <div class="legend-row"><span class="swatch" style="background:#fdae61;"></span> ORANGE: Moderate Risk</div>
    <div class="legend-row"><span class="swatch" style="background:#1a9850;"></span> GREEN: Low Risk</div>
  `;
  return div;
};
legend.addTo(map);

// --- Title box ---
const title = L.control({ position: 'topleft' });
title.onAdd = function () {
  const div = L.DomUtil.create('div', 'title-box');
  div.innerHTML = `<h2>&#9935; MineRisk Heatmap</h2><div class="sub">Live satellite view &middot; explainable zone risk</div>`;
  return div;
};
title.addTo(map);

// --- Scale bar ---
L.control.scale({ position: 'bottomleft', metric: true, imperial: false }).addTo(map);
</script>
</body>
</html>
"""


def main():
    scored_df = load_scored_zones()
    records = build_zone_records(scored_df)

    center_lat = scored_df["latitude"].mean()
    center_lon = scored_df["longitude"].mean()

    html = HTML_TEMPLATE
    html = html.replace("__ZONE_DATA__", json.dumps(records))
    html = html.replace("__CENTER_LAT__", str(center_lat))
    html = html.replace("__CENTER_LON__", str(center_lon))

    out_path = "minerisk_satellite_heatmap.html"
    with open(out_path, "w") as f:
        f.write(html)

    print(f"Wrote {out_path} — open it in your browser (needs internet for the satellite tiles).")


if __name__ == "__main__":
    main()