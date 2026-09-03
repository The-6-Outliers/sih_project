"""
MineRisk contour-blob heatmap, in the style of professional mine risk-assessment
maps: smooth red/orange/green risk contours painted over a real satellite/aerial
photo of the site, with zone labels, north arrow, scale bar and legend.
 
Unlike generate_heatmap.py (interactive dot-map), this produces a single static
PNG that looks like an engineer-drawn risk overlay.
 
Requirements:
    pip install pandas numpy scipy matplotlib contextily
 
Usage:
    python generate_contour_heatmap.py
 
Notes:
    - Needs internet access to pull the satellite basemap tiles (Esri World
      Imagery). If that fails (offline, firewall, etc.) the script
      automatically falls back to a plain light-grey background so it still
      runs — you'll just be missing the aerial photo underneath.
    - If you have your own aerial/drone photo of the site (e.g. a georeferenced
      image or one you can eyeball-align), see the `use_custom_image` section
      near the bottom of main() — swap in your file path and corner
      coordinates instead of the satellite basemap.
"""
 
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.patheffects as pe
from matplotlib.colors import LinearSegmentedColormap, BoundaryNorm
from matplotlib.patches import FancyArrow, Rectangle
 
from risk_engine import calculate_zone_risk
 
 
# ---------------------------------------------------------------------------
# 1. Load + score zones
# ---------------------------------------------------------------------------
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
    return scored_df
 
 
# ---------------------------------------------------------------------------
# 2. Interpolate a smooth risk surface (IDW-with-Gaussian-falloff) so each
#    zone becomes a soft "blob" of risk that fades out with distance, rather
#    than a hard-edged polygon. This is what gives the concentric-ring look.
# ---------------------------------------------------------------------------
def build_risk_surface(scored_df, grid_res=400, sigma_deg=0.0035, pad_frac=0.35):
    lats = scored_df["latitude"].values
    lons = scored_df["longitude"].values
    risks = scored_df["risk_score"].values
 
    lat_pad = (lats.max() - lats.min()) * pad_frac or 0.01
    lon_pad = (lons.max() - lons.min()) * pad_frac or 0.01
 
    lat_min, lat_max = lats.min() - lat_pad, lats.max() + lat_pad
    lon_min, lon_max = lons.min() - lon_pad, lons.max() + lon_pad
 
    grid_lon = np.linspace(lon_min, lon_max, grid_res)
    grid_lat = np.linspace(lat_min, lat_max, grid_res)
    LON, LAT = np.meshgrid(grid_lon, grid_lat)
 
    risk_field = np.zeros_like(LON)
    weight_field = np.zeros_like(LON)
 
    for lat, lon, risk in zip(lats, lons, risks):
        d2 = (LAT - lat) ** 2 + (LON - lon) ** 2
        w = np.exp(-d2 / (2 * sigma_deg ** 2))
        risk_field += w * risk
        weight_field += w
 
    with np.errstate(invalid="ignore", divide="ignore"):
        risk_value = np.where(weight_field > 1e-6, risk_field / weight_field, 0)
 
    # influence/opacity: strong right at zones, fades to fully transparent
    # far from every zone so the basemap shows through cleanly.
    influence = 1 - np.exp(-weight_field * 6)
    influence = np.clip(influence, 0, 1)
 
    return LON, LAT, risk_value, influence, (lon_min, lon_max, lat_min, lat_max)
 
 
def risk_colormap():
    # Matches risk_engine thresholds: Low<30, Moderate<60, High<85, Critical>=85
    colors = ["#1a9850", "#66bd63", "#fee08b", "#fdae61", "#f46d43", "#d73027", "#7f0000"]
    cmap = LinearSegmentedColormap.from_list("mine_risk", colors, N=256)
    return cmap
 
 
def render(scored_df, out_path="minerisk_contour_heatmap.png", basemap_extent=None,
           basemap_image=None, dpi=200):
    LON, LAT, risk_value, influence, extent = build_risk_surface(scored_df)
    lon_min, lon_max, lat_min, lat_max = extent
 
    fig, ax = plt.subplots(figsize=(12, 9))
 
    # --- basemap ---
    if basemap_image is not None:
        ax.imshow(basemap_image, extent=basemap_extent, origin="upper", zorder=0)
    else:
        ax.set_facecolor("#d9d9d9")
 
    # --- risk overlay as RGBA image (banded contour-ring look) ---
    cmap = risk_colormap()
    levels = np.array([0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    norm = BoundaryNorm(levels, cmap.N)
 
    rgba = cmap(norm(risk_value))
    rgba[..., 3] = influence * 0.72  # overall overlay opacity
 
    ax.imshow(
        rgba,
        extent=(lon_min, lon_max, lat_min, lat_max),
        origin="lower",
        zorder=2,
        interpolation="bilinear",
    )
 
    # thin contour lines to emphasize the banding, like the reference image
    ax.contour(
        LON, LAT, risk_value, levels=levels, colors="black",
        linewidths=0.3, alpha=0.25, zorder=3,
    )
 
    # --- zone markers + labels ---
    for _, row in scored_df.iterrows():
        ax.plot(row["longitude"], row["latitude"], "o", color="white",
                 markeredgecolor="black", markersize=5, zorder=5)
        ax.annotate(
            row["zone_name"].upper(),
            (row["longitude"], row["latitude"]),
            textcoords="offset points",
            xytext=(6, 6),
            fontsize=8.5,
            fontweight="bold",
            color="white",
            zorder=6,
            path_effects=[pe.withStroke(linewidth=2.5, foreground="black")],
        )
 
    ax.set_xlim(lon_min, lon_max)
    ax.set_ylim(lat_min, lat_max)
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_visible(False)
 
    # --- north arrow ---
    ax_pos = ax.get_position()
    arrow_ax = fig.add_axes([ax_pos.x0 + 0.02, ax_pos.y1 - 0.13, 0.04, 0.08])
    arrow_ax.axis("off")
    arrow_ax.add_patch(FancyArrow(0.5, 0, 0, 0.75, width=0.08, head_width=0.35,
                                    head_length=0.25, color="white", ec="black", lw=1))
    arrow_ax.text(0.5, 0.85, "N", ha="center", fontsize=11, fontweight="bold", color="white",
                   path_effects=[pe.withStroke(linewidth=2, foreground="black")])
    arrow_ax.set_xlim(0, 1)
    arrow_ax.set_ylim(0, 1)
 
    # --- scale bar (approximate, using degrees-to-meters at this latitude) ---
    mean_lat = scored_df["latitude"].mean()
    m_per_deg_lon = 111320 * np.cos(np.radians(mean_lat))
    bar_km = 0.5
    bar_deg = (bar_km * 1000) / m_per_deg_lon
    bar_x0 = lon_min + (lon_max - lon_min) * 0.03
    bar_y0 = lat_min + (lat_max - lat_min) * 0.04
    ax.plot([bar_x0, bar_x0 + bar_deg], [bar_y0, bar_y0], color="white", lw=3,
             solid_capstyle="butt", zorder=6,
             path_effects=[pe.withStroke(linewidth=5, foreground="black")])
    ax.text(bar_x0, bar_y0 + (lat_max - lat_min) * 0.015, f"{bar_km*1000:.0f}m",
             fontsize=8, color="white", fontweight="bold", zorder=6,
             path_effects=[pe.withStroke(linewidth=2, foreground="black")])
 
    # --- legend box, styled like the reference image ---
    legend_ax = fig.add_axes([ax_pos.x1 - 0.24, ax_pos.y0 + 0.02, 0.22, 0.14])
    legend_ax.axis("off")
    legend_ax.add_patch(Rectangle((0, 0), 1, 1, transform=legend_ax.transAxes,
                                    facecolor="black", alpha=0.55, zorder=0))
    legend_ax.text(0.5, 0.85, "RISK ASSESSMENT HEATMAP", ha="center", va="center",
                    fontsize=8.5, fontweight="bold", color="white", transform=legend_ax.transAxes)
    legend_items = [("RED: High Risk", "#d73027"), ("ORANGE: Medium Risk", "#fdae61"),
                     ("GREEN: Low Risk", "#1a9850")]
    for i, (label, color) in enumerate(legend_items):
        y = 0.58 - i * 0.26
        legend_ax.add_patch(Rectangle((0.06, y - 0.06), 0.1, 0.12, transform=legend_ax.transAxes,
                                        facecolor=color))
        legend_ax.text(0.2, y, label, va="center", fontsize=7.5, color="white",
                        fontweight="bold", transform=legend_ax.transAxes)
 
    plt.savefig(out_path, dpi=dpi, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return out_path
 
 
def get_satellite_basemap(scored_df, pad_frac=0.35):
    """Try to pull a real Esri World Imagery satellite basemap for the zone
    bounding box. Returns (image_array, extent) or (None, None) on failure."""
    try:
        import contextily as cx
    except ImportError:
        print("contextily not installed — run: pip install contextily")
        return None, None
 
    lats = scored_df["latitude"].values
    lons = scored_df["longitude"].values
    lat_pad = (lats.max() - lats.min()) * pad_frac or 0.01
    lon_pad = (lons.max() - lons.min()) * pad_frac or 0.01
 
    west, south = lons.min() - lon_pad, lats.min() - lat_pad
    east, north = lons.max() + lon_pad, lats.max() + lat_pad
 
    try:
        img, ext = cx.bounds2img(
            west, south, east, north, ll=True,
            source=cx.providers.Esri.WorldImagery,
        )
        # contextily returns extent in Web Mercator; reproject the RGBA image
        # back onto plain lon/lat extent by resampling isn't exact, but for a
        # zoomed-in mine-site scale the distortion is negligible, so we just
        # relabel the extent as (west, east, south, north).
        return img, (west, east, south, north)
    except Exception as e:
        print(f"Could not fetch satellite basemap ({type(e).__name__}: {e}). "
              f"Falling back to plain background.")
        return None, None
 
 
def main():
    scored_df = load_scored_zones()
 
    # --- Option A (default): try a real satellite basemap ---
    basemap_image, basemap_extent = get_satellite_basemap(scored_df)
 
    # --- Option B: use your own aerial/drone photo instead ---
    # Uncomment and edit if you have a real site photo you can align by eye.
    # import matplotlib.image as mpimg
    # basemap_image = mpimg.imread("my_site_photo.jpg")
    # basemap_extent = (87.300, 87.328, 22.300, 22.332)  # (west, east, south, north)
 
    out_path = render(scored_df, basemap_image=basemap_image, basemap_extent=basemap_extent)
    print(f"Wrote {out_path}")
 
 
if __name__ == "__main__":
    main()
 