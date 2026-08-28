"""
Sales Analytics Pipeline — Reporting Dashboard
================================================
Runs natively inside Snowflake (Streamlit in Snowflake), reading directly
from the four Gold-layer report views via the active session — no
external connection, no credentials to manage. Solution Design Doc
Section 5, Option A.

FLAGGED: the underlying report views (gold/003_report_views.sql) are
first-pass, not yet validated against Avirup's reference report snapshot.
Numbers shown here should be treated the same way — a working dashboard
over provisional logic, not confirmed-correct output.
"""

import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Sales Analytics Pipeline", layout="wide")

session = get_active_session()


@st.cache_data(ttl=300)
def load_view(view_name: str) -> pd.DataFrame:
    """Cached for 5 minutes — Gold views query Silver live, so there's no
    point re-running an identical query on every widget interaction."""
    return session.table(f"GOLD.{view_name}").to_pandas()


st.title("Sales Analytics Pipeline")
st.caption(
    "First-pass report logic — not yet validated against the SME reference "
    "snapshot. See Solution Design Doc Section 10 (Next Steps)."
)

report = st.sidebar.radio(
    "Report",
    [
        "Inbound Setter Report",
        "Outbound Setter Report",
        "Closer Report",
        "Objections Faced Report",
    ],
)

if report == "Inbound Setter Report":
    df = load_view("INBOUND_SETTER_REPORT")
    st.header("Inbound Setter Report")

    if df.empty:
        st.info("No data yet — check that SP_SILVER_PROCESS has run and Bronze has been loaded.")
    else:
        col1, col2, col3 = st.columns(3)
        col1.metric("Total Inbound Booked", int(df["INBOUND_BOOKED"].sum()))
        col2.metric("Avg Show Rate", f"{df['SHOW_RATE'].mean():.1f}%")
        col3.metric("Total Sales", int(df["TOTAL_SALES"].sum()))

        st.subheader("By Setter and Date")
        st.dataframe(df.sort_values("TRIAGE_DATE", ascending=False), use_container_width=True)

        st.subheader("Show Rate Trend")
        trend = df.groupby("TRIAGE_DATE")["SHOW_RATE"].mean().reset_index()
        st.line_chart(trend.set_index("TRIAGE_DATE"))

elif report == "Outbound Setter Report":
    df = load_view("OUTBOUND_SETTER_REPORT")
    st.header("Outbound Setter Report")

    if df.empty:
        st.info("No data yet — check that SP_SILVER_PROCESS has run and Bronze has been loaded.")
    else:
        col1, col2, col3 = st.columns(3)
        col1.metric("Total Outbound Calls", int(df["TOTAL_OUTBOUND_CALLS"].sum()))
        col2.metric("Avg Dial-to-Set Rate", f"{df['DIAL_TO_SET_RATE'].mean():.1f}%")
        col3.metric("Total Revenue", f"${df['TOTAL_REVENUE'].sum():,.0f}")

        st.subheader("By Setter and Date")
        st.dataframe(df.sort_values("DIAL_DATE", ascending=False), use_container_width=True)

        st.subheader("Funnel Rates by Date")
        trend = df.groupby("DIAL_DATE")[["DIAL_TO_SET_RATE", "SET_TO_SHOW_RATE", "SHOW_TO_SALE_RATE"]].mean().reset_index()
        st.line_chart(trend.set_index("DIAL_DATE"))

elif report == "Closer Report":
    df = load_view("CLOSER_REPORT")
    st.header("Closer Report")

    if df.empty:
        st.info("No data yet — check that SP_SILVER_PROCESS has run and Bronze has been loaded.")
    else:
        col1, col2, col3 = st.columns(3)
        col1.metric("Total Calls Booked", int(df["CALL_BOOKED"].sum()))
        col2.metric("Total Sales", int(df["SALE"].sum()))
        col3.metric("Total Cash Collected", f"${df['CASH_COLLECTED'].sum():,.0f}")

        st.subheader("By Closer and Month")
        st.dataframe(df.sort_values("CALL_YEAR_MONTH", ascending=False), use_container_width=True)

        st.subheader("Cancellation Breakdown")
        cancel_summary = df[["ADMIN_CANCEL", "CANCEL_NURTURE", "CANCEL_NOT_INTEREST"]].sum()
        st.bar_chart(cancel_summary)

else:  # Objections Faced Report
    df = load_view("OBJECTIONS_FACED_REPORT")
    st.header("Objections Faced Report")
    st.warning(
        "Objection category matching is the least-validated part of this "
        "dashboard — it assumes category names appear as substrings in the "
        "raw field value, unconfirmed against real data. If these numbers "
        "look wrong, check gold/003_report_views.sql's OBJECTIONS_FACED_REPORT "
        "definition first."
    )

    if df.empty:
        st.info("No data yet — check that SP_SILVER_PROCESS has run and Bronze has been loaded.")
    else:
        st.subheader("By Closer and Date")
        st.dataframe(df.sort_values("ACTIVITY_DATE", ascending=False), use_container_width=True)

        st.subheader("Objection Category Totals")
        category_cols = [
            "MONEY_COUNT", "FEAR_COUNT", "HUNG_UP_COUNT", "LOGISTICAL_COUNT",
            "NO_OBJ_COUNT", "OTHER_COACHES_COUNT", "PARTNER_COUNT",
            "THINK_ABT_IT_COUNT", "TIME_COUNT", "TRUST_COUNT", "VALUE_COUNT",
            "NOT_LOOKING_COUNT",
        ]
        totals = df[category_cols].sum().sort_values(ascending=False)
        st.bar_chart(totals)
