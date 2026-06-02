"""
E-Commerce Data Platform - Streamlit Dashboard (Simplified & Robust)
"""

import streamlit as st
import pandas as pd
import boto3
import json
from datetime import datetime
import plotly.express as px

# Page config
st.set_page_config(page_title="E-Commerce Dashboard", layout="wide")
st.title("📊 E-Commerce Data Platform Dashboard")
st.markdown("Real-time data lake visualization")

# Initialize S3 client with Streamlit Secrets
@st.cache_resource
def get_s3_client():
    try:
        if "aws" in st.secrets:
            return boto3.client(
                's3',
                region_name=st.secrets["aws"].get("region", "us-east-1"),
                aws_access_key_id=st.secrets["aws"]["access_key_id"],
                aws_secret_access_key=st.secrets["aws"]["secret_access_key"]
            )
        else:
            return boto3.client('s3', region_name='us-east-1')
    except Exception as e:
        st.error(f"AWS Config Error: {e}")
        st.stop()

@st.cache_data(ttl=300)
def load_data_from_s3(bucket, prefix):
    """Load JSON files from S3"""
    s3 = get_s3_client()
    try:
        response = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
        data = []
        
        if 'Contents' in response:
            for obj in response['Contents']:
                if obj['Key'].endswith('.json'):
                    try:
                        file_obj = s3.get_object(Bucket=bucket, Key=obj['Key'])
                        content = json.loads(file_obj['Body'].read().decode('utf-8'))
                        
                        if isinstance(content, list):
                            data.extend(content)
                        elif isinstance(content, dict):
                            data.append(content)
                    except:
                        continue
        
        return pd.DataFrame(data) if data else pd.DataFrame()
    except Exception as e:
        st.error(f"S3 Error: {e}")
        return pd.DataFrame()

# Sidebar
st.sidebar.header("⚙️ Configuration")
bucket = "ecommerce-data-platform-datalake-211854352436"

if st.sidebar.button("🔄 Refresh Data", use_container_width=True):
    st.cache_data.clear()
    st.rerun()

# Load data
with st.spinner("Loading data..."):
    products_df = load_data_from_s3(bucket, "bronze/products/")
    customers_df = load_data_from_s3(bucket, "bronze/customers/")
    orders_df = load_data_from_s3(bucket, "bronze/orders/")
    events_df = load_data_from_s3(bucket, "bronze/events/")

# KPIs
col1, col2, col3, col4 = st.columns(4)
col1.metric("📦 Products", len(products_df) if not products_df.empty else 0)
col2.metric("👥 Customers", len(customers_df) if not customers_df.empty else 0)
col3.metric("🛒 Orders", len(orders_df) if not orders_df.empty else 0)
col4.metric("📊 Events", len(events_df) if not events_df.empty else 0)

st.divider()

# Tabs
tab1, tab2, tab3, tab4, tab5 = st.tabs(["📦 Products", "👥 Customers", "🛒 Orders", "📈 Events", "📋 Raw Data"])

# Products
with tab1:
    if not products_df.empty:
        col1, col2 = st.columns(2)
        
        with col1:
            st.subheader("Products per Category")
            if 'category' in products_df.columns:
                counts = products_df['category'].value_counts()
                fig = px.bar(x=counts.index, y=counts.values, title="Products by Category",
                            labels={'x': 'Category', 'y': 'Count'})
                st.plotly_chart(fig, use_container_width=True)
        
        with col2:
            st.subheader("Price Statistics")
            if 'price' in products_df.columns:
                prices = pd.to_numeric(products_df['price'], errors='coerce').dropna()
                st.metric("Avg Price", f"${prices.mean():.2f}")
                st.metric("Max Price", f"${prices.max():.2f}")
                st.metric("Min Price", f"${prices.min():.2f}")
        
        st.subheader("All Products")
        st.dataframe(products_df, use_container_width=True)
    else:
        st.info("No product data")

# Customers
with tab2:
    if not customers_df.empty:
        st.subheader(f"Total Customers: {len(customers_df)}")
        
        if 'address' in customers_df.columns:
            try:
                cities = customers_df['address'].apply(lambda x: x.get('city', 'Unknown') if isinstance(x, dict) else 'Unknown')
                counts = cities.value_counts().head(10)
                
                fig = px.bar(x=counts.index, y=counts.values, title="Top 10 Cities",
                            labels={'x': 'City', 'y': 'Count'})
                st.plotly_chart(fig, use_container_width=True)
            except:
                pass
        
        st.subheader("All Customers")
        st.dataframe(customers_df[['id', 'email', 'username']] if set(['id', 'email', 'username']).issubset(customers_df.columns) else customers_df, use_container_width=True)
    else:
        st.info("No customer data")

# Orders
with tab3:
    if not orders_df.empty:
        col1, col2 = st.columns(2)
        
        with col1:
            st.subheader("Total Orders")
            st.metric("Orders", len(orders_df))
        
        with col2:
            st.subheader("Order Status")
            if 'status' in orders_df.columns:
                status_counts = orders_df['status'].value_counts()
                fig = px.pie(values=status_counts.values, names=status_counts.index,
                            title="Order Status Distribution")
                st.plotly_chart(fig, use_container_width=True)
        
        st.subheader("All Orders")
        st.dataframe(orders_df, use_container_width=True)
    else:
        st.info("No order data")

# Events
with tab4:
    if not events_df.empty:
        col1, col2 = st.columns(2)
        
        with col1:
            st.subheader("Events by Type")
            if 'event_type' in events_df.columns:
                counts = events_df['event_type'].value_counts()
                fig = px.bar(x=counts.index, y=counts.values, title="Event Distribution",
                            labels={'x': 'Event Type', 'y': 'Count'})
                st.plotly_chart(fig, use_container_width=True)
        
        with col2:
            st.subheader("Events by Device")
            if 'device' in events_df.columns:
                counts = events_df['device'].value_counts()
                fig = px.pie(values=counts.values, names=counts.index, title="Device Distribution")
                st.plotly_chart(fig, use_container_width=True)
        
        st.subheader("All Events")
        st.dataframe(events_df, use_container_width=True)
    else:
        st.info("No event data")

# Raw Data
with tab5:
    dataset = st.selectbox("Select Dataset", ["Products", "Customers", "Orders", "Events"])
    
    if dataset == "Products" and not products_df.empty:
        st.dataframe(products_df, use_container_width=True)
    elif dataset == "Customers" and not customers_df.empty:
        st.dataframe(customers_df, use_container_width=True)
    elif dataset == "Orders" and not orders_df.empty:
        st.dataframe(orders_df, use_container_width=True)
    elif dataset == "Events" and not events_df.empty:
        st.dataframe(events_df, use_container_width=True)
    else:
        st.info(f"No {dataset.lower()} data available")

# Footer
st.divider()
st.markdown(f"**Last Updated**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | **Data Source**: AWS S3")