import streamlit as st
import pandas as pd
import plotly.express as px

from risk_engine import (
    calculate_zone_risk,
    check_emergency_conditions
)


st.set_page_config(
    page_title="MineRisk Heatmap",
    page_icon="⛏️",
    layout="wide"
)


@st.cache_data
def load_data():
    sensor_df = pd.read_csv(
        "sensor_readings.csv",
        parse_dates=["timestamp"]
    )

    current_df = pd.read_csv(
        "current_zone_data.csv"
    )

    zones_df = pd.read_csv(
        "zones.csv"
    )
    precomputed_cols = [
    "methane_risk", "co_risk", "oxygen_risk", "dust_risk", "gas_risk",
    "equipment_risk", "violation_risk", "incident_risk", "inspection_risk",
    "risk_score", "risk_level", "reasons"
    ]
    current_df = current_df.drop(columns=[c for c in precomputed_cols if c in current_df.columns])
    

    return sensor_df, current_df, zones_df


sensor_df, current_df, zones_df = load_data()


# Calculate current risk for every zone
risk_results = current_df.apply(
    calculate_zone_risk,
    axis=1
)

scored_df = pd.concat(
    [
        current_df.reset_index(drop=True),
        risk_results.reset_index(drop=True)
    ],
    axis=1
)


# Add emergency alerts
scored_df["emergency_alerts"] = scored_df.apply(
    check_emergency_conditions,
    axis=1
)


st.title("⛏️ MineRisk Heatmap")
st.caption(
    "Explainable mine-zone risk prioritisation prototype"
)


st.warning(
    "Prototype only: this system does not replace certified monitoring, "
    "statutory mine-safety procedures or qualified safety personnel."
)


# Sidebar
st.sidebar.header("Dashboard Controls")

selected_zone = st.sidebar.selectbox(
    "Select a mine zone",
    scored_df["zone_name"].tolist()
)

selected = scored_df[
    scored_df["zone_name"] == selected_zone
].iloc[0]


# Summary metrics
col1, col2, col3, col4 = st.columns(4)

col1.metric(
    "Risk score",
    f"{selected['risk_score']}/100"
)

col2.metric(
    "Risk level",
    selected["risk_level"]
)

col3.metric(
    "Methane",
    f"{selected['methane_pct']:.2f}%"
)

col4.metric(
    "Workers",
    int(selected["worker_count"])
)


# Risk map
st.subheader("Mine risk map")

map_df = scored_df.copy()

fig = px.scatter_map(
    map_df,
    lat="latitude",
    lon="longitude",
    color="risk_level",
    size="risk_score",
    hover_name="zone_name",
    hover_data={
        "risk_score": True,
        "methane_pct": True,
        "co_ppm": True,
        "oxygen_pct": True,
        "worker_count": True,
        "latitude": False,
        "longitude": False
    },
    color_discrete_map={
        "Low": "green",
        "Moderate": "orange",
        "High": "red",
        "Critical": "purple"
    },
    zoom=11,
    height=550,
    map_style="open-street-map"
)

st.plotly_chart(
    fig,
    use_container_width=True
)


# Top five zones
st.subheader("Top five risky locations")

top_5 = (
    scored_df[
        [
            "zone_id",
            "zone_name",
            "risk_score",
            "risk_level",
            "methane_pct",
            "co_ppm",
            "worker_count"
        ]
    ]
    .sort_values(
        "risk_score",
        ascending=False
    )
    .head(5)
)

st.dataframe(
    top_5,
    use_container_width=True,
    hide_index=True
)


# Zone explanation
st.subheader(f"Why is {selected_zone} risky?")

for reason in selected["reasons"]:
    st.warning(reason)


# Risk components
st.subheader("Risk-score components")

component_df = pd.DataFrame({
    "Component": [
        "Gas",
        "Equipment",
        "Safety observations",
        "Incident history",
        "Inspection overdue"
    ],
    "Component risk": [
        selected["gas_risk"],
        selected["equipment_risk"],
        selected["violation_risk"],
        selected["incident_risk"],
        selected["inspection_risk"]
    ]
})

component_fig = px.bar(
    component_df,
    x="Component",
    y="Component risk",
    range_y=[0, 100],
    color="Component risk",
    color_continuous_scale="RdYlGn_r"
)

st.plotly_chart(
    component_fig,
    use_container_width=True
)


# Sensor history
st.subheader(f"24-hour sensor history: {selected_zone}")

history_df = sensor_df[
    sensor_df["zone_id"] == selected["zone_id"]
].sort_values("timestamp")

history_df["risk_score"] = history_df.apply(
    calculate_zone_risk,
    axis=1
)["risk_score"].values

gas_fig = px.line(
    history_df,
    x="timestamp",
    y=["methane_pct", "co_ppm"],
    markers=True,
    title="Methane and CO trend"
)

st.plotly_chart(
    gas_fig,
    use_container_width=True
)

risk_fig = px.line(
    history_df,
    x="timestamp",
    y="risk_score",
    markers=True,
    title="Risk-score trend"
)

st.plotly_chart(
    risk_fig,
    use_container_width=True
)


# Emergency alert
alerts = selected["emergency_alerts"]

st.subheader("Safety status")

if len(alerts) > 0:
    for alert in alerts:
        st.error(alert)
else:
    st.success(
        "No prototype emergency-rule condition detected."
    )


# Field observation form
st.subheader("Submit field observation")

with st.form("observation_form"):
    observation_type = st.selectbox(
        "Observation type",
        [
            "Reduced ventilation",
            "Equipment damage",
            "Dust accumulation",
            "PPE violation",
            "Water accumulation",
            "Other"
        ]
    )

    severity = st.slider(
        "Severity",
        min_value=1,
        max_value=5,
        value=3
    )

    description = st.text_area(
        "Observation description"
    )

    submitted = st.form_submit_button(
        "Submit observation"
    )

if submitted:
    st.success(
        f"Observation submitted for {selected_zone}."
    )

    st.info(
        "Corrective-action ticket created and assigned to the area supervisor."
    )