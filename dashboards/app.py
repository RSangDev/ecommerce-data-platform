"""
E-Commerce Data Platform - Streamlit Dashboard
Real-time visualization of data lake metrics
"""

import streamlit as st
import pandas as pd
import boto3
import json
from datetime import datetime
import plotly.express as px
import plotly.graph_objects as go
from io import BytesIO

# Page config
st.set_page_config(page_title="E-Commerce Dashboard", layout="wide", initial_sidebar_state="expanded")

# Title
st.title("📊 E-Commerce Data Platform Dashboard")
st.markdown("Real-time data lake visualization")

# Initialize S3 client with Streamlit Secrets
@st.cache_resource
def get_s3_client():
    try:
        # Try to get credentials from Streamlit secrets
        if "aws" in st.secrets:
            return boto3.client(
                's3',
                region_name=st.secrets["aws"].get("region", "us-east-1"),
                aws_access_key_id=st.secrets["aws"]["access_key_id"],
                aws_secret_access_key=st.secrets["aws"]["secret_access_key"]
            )
        else:
            # Fallback to environment variables or default credentials
            return boto3.client('s3', region_name='us-east-1')
    except Exception as e:
        st.error(f"AWS Configuration Error: {e}")
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
                        
                        # Handle both list and dict responses
                        if isinstance(content, list):
                            data.extend(content)
                        elif isinstance(content, dict):
                            data.append(content)
                    except Exception as e:
                        st.warning(f"Error parsing {obj['Key']}: {str(e)}")
                        continue
        
        df = pd.DataFrame(data) if data else pd.DataFrame()
        
        # Debug: Show loaded data structure
        if len(df) > 0:
            st.sidebar.info(f"✅ Loaded {len(df)} records from {prefix}")
        else:
            st.sidebar.warning(f"⚠️ No data loaded from {prefix}")
        
        return df
    except Exception as e:
        st.sidebar.error(f"Error loading data from {prefix}: {e}")
        return pd.DataFrame()

# Sidebar config
st.sidebar.header("⚙️ Configuration")
bucket = st.sidebar.text_input("S3 Bucket", "ecommerce-data-platform-datalake-211854352436")
account_id = "211854352436"
bucket = f"ecommerce-data-platform-datalake-{account_id}"

# Load data
st.sidebar.header("📥 Load Data")
if st.sidebar.button("🔄 Refresh Data", use_container_width=True):
    st.cache_data.clear()
    st.rerun()

# Load datasets
with st.spinner("Loading data from S3..."):
    products_df = load_data_from_s3(bucket, "bronze/products/")
    customers_df = load_data_from_s3(bucket, "bronze/customers/")
    orders_df = load_data_from_s3(bucket, "bronze/orders/")
    events_df = load_data_from_s3(bucket, "bronze/events/")

# KPIs
col1, col2, col3, col4 = st.columns(4)

with col1:
    st.metric("📦 Products", len(products_df) if not products_df.empty else 0)

with col2:
    st.metric("👥 Customers", len(customers_df) if not customers_df.empty else 0)

with col3:
    st.metric("🛒 Orders", len(orders_df) if not orders_df.empty else 0)

with col4:
    st.metric("📊 Events", len(events_df) if not events_df.empty else 0)

st.divider()

# Tabs
tab1, tab2, tab3, tab4, tab5 = st.tabs(["📦 Products", "👥 Customers", "🛒 Orders", "📈 Events", "📋 Raw Data"])

# Products Tab
with tab1:
    if not products_df.empty:
        try:
            col1, col2 = st.columns(2)
            
            with col1:
                st.subheader("Price Distribution by Category")
                if 'category' in products_df.columns and 'price' in products_df.columns:
                    # Ensure price is numeric
                    products_df['price'] = pd.to_numeric(products_df['price'], errors='coerce')
                    products_df_clean = products_df.dropna(subset=['price'])
                    
                    if len(products_df_clean) > 0:
                        fig = px.box(products_df_clean, x='category', y='price', color='category', 
                                    title="Product Prices by Category")
                        st.plotly_chart(fig, use_container_width=True)
                    else:
                        st.info("No valid price data available")
                else:
                    st.info("Missing required columns (category, price)")
            
            with col2:
                st.subheader("Products per Category")
                if 'category' in products_df.columns:
                    category_counts = products_df['category'].value_counts()
                    if len(category_counts) > 0:
                        fig = px.pie(values=category_counts.values, names=category_counts.index,
                                    title="Product Distribution")
                        st.plotly_chart(fig, use_container_width=True)
                    else:
                        st.info("No categories found")
                else:
                    st.info("Missing category column")
            
            st.subheader("Product Ratings")
            if 'rating' in products_df.columns:
                try:
                    ratings = pd.json_normalize(products_df['rating'])
                    if len(ratings) > 0 and 'count' in ratings.columns and 'rate' in ratings.columns:
                        ratings['count'] = pd.to_numeric(ratings['count'], errors='coerce')
                        ratings['rate'] = pd.to_numeric(ratings['rate'], errors='coerce')
                        ratings_clean = ratings.dropna(subset=['count', 'rate'])
                        
                        if len(ratings_clean) > 0:
                            fig = px.scatter(ratings_clean, x='count', y='rate', 
                                            title="Rating vs Review Count",
                                            labels={'count': 'Review Count', 'rate': 'Rating'})
                            st.plotly_chart(fig, use_container_width=True)
                except Exception as e:
                    st.info(f"Could not display ratings: {str(e)}")
            
            st.subheader("All Products")
            st.dataframe(products_df, use_container_width=True)
        except Exception as e:
            st.error(f"Error displaying products: {str(e)}")
    else:
        st.info("No product data available")

# Customers Tab
with tab2:
    if not customers_df.empty:
        st.subheader("Customers by City")
        
        if 'address' in customers_df.columns:
            cities = customers_df['address'].apply(lambda x: x['city'] if isinstance(x, dict) else 'Unknown')
            city_counts = cities.value_counts()
            
            col1, col2 = st.columns(2)
            
            with col1:
                fig = px.bar(x=city_counts.index, y=city_counts.values,
                            title="Customers per City",
                            labels={'x': 'City', 'y': 'Count'})
                st.plotly_chart(fig, use_container_width=True)
            
            with col2:
                fig = px.pie(values=city_counts.values, names=city_counts.index,
                            title="Customer Distribution by City")
                st.plotly_chart(fig, use_container_width=True)
        
        st.subheader("All Customers")
        st.dataframe(customers_df[['id', 'email', 'username']], use_container_width=True)
    else:
        st.info("No customer data available")

# Orders Tab
with tab3:
    if not orders_df.empty:
        col1, col2 = st.columns(2)
        
        with col1:
            st.subheader("Orders by Status")
            status_counts = orders_df['status'].value_counts()
            fig = px.pie(values=status_counts.values, names=status_counts.index,
                        title="Order Status Distribution")
            st.plotly_chart(fig, use_container_width=True)
        
        with col2:
            st.subheader("Orders per Day")
            orders_df['date'] = pd.to_datetime(orders_df['date'])
            daily_orders = orders_df.groupby('date').size()
            fig = px.line(x=daily_orders.index, y=daily_orders.values,
                         title="Daily Orders",
                         labels={'x': 'Date', 'y': 'Order Count'})
            st.plotly_chart(fig, use_container_width=True)
        
        st.subheader("All Orders")
        st.dataframe(orders_df, use_container_width=True)
    else:
        st.info("No order data available")

# Events Tab
with tab4:
    if not events_df.empty:
        col1, col2 = st.columns(2)
        
        with col1:
            st.subheader("Events by Type")
            event_counts = events_df['event_type'].value_counts()
            fig = px.bar(x=event_counts.index, y=event_counts.values,
                        title="Event Distribution",
                        labels={'x': 'Event Type', 'y': 'Count'})
            st.plotly_chart(fig, use_container_width=True)
        
        with col2:
            st.subheader("Events by Device")
            device_counts = events_df['device'].value_counts()
            fig = px.pie(values=device_counts.values, names=device_counts.index,
                        title="Device Distribution")
            st.plotly_chart(fig, use_container_width=True)
        
        st.subheader("All Events")
        st.dataframe(events_df, use_container_width=True)
    else:
        st.info("No event data available")

# Raw Data Tab
with tab5:
    st.subheader("Raw Data Explorer")
    
    dataset = st.selectbox("Select Dataset", ["Products", "Customers", "Orders", "Events"])
    
    if dataset == "Products":
        st.dataframe(products_df, use_container_width=True)
    elif dataset == "Customers":
        st.dataframe(customers_df, use_container_width=True)
    elif dataset == "Orders":
        st.dataframe(orders_df, use_container_width=True)
    elif dataset == "Events":
        st.dataframe(events_df, use_container_width=True)

# Footer
st.divider()
st.markdown("""
**E-Commerce Data Platform** | 
Last Updated: """ + datetime.now().strftime("%Y-%m-%d %H:%M:%S") + """ |
Data Source: AWS S3 Data Lake
""")