"""
Silver to Gold ETL Job
Creates business-ready aggregated tables and analytics views
"""

from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, sum, count, avg, max, min, round, current_timestamp,
    first, last, datediff, countDistinct, when, dense_rank,
    lag, lead, row_number, date_sub, date_add, concat_ws
)
from pyspark.sql.window import Window
from datetime import datetime
import sys


def create_spark_session(app_name="SilverToGold"):
    """Create Spark session"""
    return SparkSession.builder \
        .appName(app_name) \
        .config("spark.sql.adaptive.enabled", "true") \
        .config("spark.sql.parquet.compression.codec", "snappy") \
        .config("spark.sql.sources.partitionOverwriteMode", "dynamic") \
        .enableHiveSupport() \
        .getOrCreate()


def create_daily_sales_summary(spark, silver_path, gold_path):
    """
    Daily sales summary
    - Total revenue, orders, customers per day
    - Product and category breakdowns
    """
    print("Creating daily sales summary...")
    
    # Read fact_orders
    df_orders = spark.read.parquet(f"{silver_path}/fact_orders/")
    
    # Read date dimension
    df_dates = spark.read.parquet(f"{silver_path}/dim_date/")
    
    # Daily aggregation
    df_daily = df_orders \
        .groupBy("order_date", "year", "month") \
        .agg(
            sum("revenue").alias("total_revenue"),
            sum("profit").alias("total_profit"),
            sum("cost").alias("total_cost"),
            sum("quantity").alias("total_quantity"),
            countDistinct("order_id").alias("total_orders"),
            countDistinct("customer_id").alias("unique_customers"),
            countDistinct("product_id").alias("unique_products"),
            avg("revenue").alias("avg_order_value"),
            count("*").alias("total_items")
        )
    
    # Join with date dimension for additional attributes
    df_final = df_daily \
        .join(df_dates, df_daily.order_date == df_dates.date, "left") \
        .withColumn("profit_margin", 
            round((col("total_profit") / col("total_revenue")) * 100, 2)
        ) \
        .withColumn("avg_items_per_order",
            round(col("total_items") / col("total_orders"), 2)
        ) \
        .withColumn("load_timestamp", current_timestamp()) \
        .select(
            "order_date",
            "date_key",
            "year",
            "quarter",
            "month",
            "month_name",
            "day",
            "day_name",
            "is_weekend",
            "total_revenue",
            "total_profit",
            "total_cost",
            "profit_margin",
            "total_quantity",
            "total_orders",
            "total_items",
            "unique_customers",
            "unique_products",
            "avg_order_value",
            "avg_items_per_order",
            "load_timestamp"
        )
    
    print(f"Daily sales records: {df_final.count():,}")
    
    # Write to Gold (partitioned by year, month)
    df_final.write \
        .mode("overwrite") \
        .partitionBy("year", "month") \
        .parquet(f"{gold_path}/daily_sales_summary/")
    
    print(f"✓ Daily sales summary written to {gold_path}/daily_sales_summary/")
    return df_final


def create_product_performance(spark, silver_path, gold_path):
    """
    Product performance metrics
    - Sales by product
    - Rankings
    - Trends
    """
    print("Creating product performance metrics...")
    
    # Read orders and products
    df_orders = spark.read.parquet(f"{silver_path}/fact_orders/")
    df_products = spark.read.parquet(f"{silver_path}/dim_products/") \
        .filter(col("is_current") == True)
    
    # Product aggregation
    df_product_agg = df_orders \
        .groupBy("product_id", "category") \
        .agg(
            sum("revenue").alias("total_revenue"),
            sum("profit").alias("total_profit"),
            sum("quantity").alias("total_quantity_sold"),
            countDistinct("order_id").alias("total_orders"),
            countDistinct("customer_id").alias("unique_customers"),
            avg("revenue").alias("avg_revenue_per_order")
        )
    
    # Join with product dimension
    df_enriched = df_product_agg \
        .join(df_products.select("product_id", "product_name", "price", "rating"), 
              "product_id", "left")
    
    # Calculate rankings
    window_revenue = Window.orderBy(col("total_revenue").desc())
    window_category = Window.partitionBy("category").orderBy(col("total_revenue").desc())
    
    df_final = df_enriched \
        .withColumn("revenue_rank_overall", dense_rank().over(window_revenue)) \
        .withColumn("revenue_rank_in_category", dense_rank().over(window_category)) \
        .withColumn("profit_margin", 
            round((col("total_profit") / col("total_revenue")) * 100, 2)
        ) \
        .withColumn("avg_revenue_per_unit",
            round(col("total_revenue") / col("total_quantity_sold"), 2)
        ) \
        .withColumn("load_timestamp", current_timestamp()) \
        .select(
            "product_id",
            "product_name",
            "category",
            "price",
            "rating",
            "total_revenue",
            "total_profit",
            "profit_margin",
            "total_quantity_sold",
            "total_orders",
            "unique_customers",
            "avg_revenue_per_order",
            "avg_revenue_per_unit",
            "revenue_rank_overall",
            "revenue_rank_in_category",
            "load_timestamp"
        )
    
    print(f"Product performance records: {df_final.count():,}")
    
    # Write to Gold
    df_final.write \
        .mode("overwrite") \
        .partitionBy("category") \
        .parquet(f"{gold_path}/product_performance/")
    
    print(f"✓ Product performance written to {gold_path}/product_performance/")
    return df_final


def create_customer_360(spark, silver_path, gold_path):
    """
    Customer 360 view
    - Lifetime metrics
    - Segmentation
    - RFM analysis (Recency, Frequency, Monetary)
    """
    print("Creating customer 360 view...")
    
    # Read data
    df_orders = spark.read.parquet(f"{silver_path}/fact_orders/")
    df_customers = spark.read.parquet(f"{silver_path}/dim_customers/") \
        .filter(col("is_current") == True)
    
    # Customer aggregation
    df_customer_agg = df_orders \
        .groupBy("customer_id") \
        .agg(
            sum("revenue").alias("lifetime_revenue"),
            sum("profit").alias("lifetime_profit"),
            sum("quantity").alias("total_items_purchased"),
            countDistinct("order_id").alias("total_orders"),
            countDistinct("product_id").alias("unique_products_bought"),
            avg("revenue").alias("avg_order_value"),
            max("order_date").alias("last_order_date"),
            min("order_date").alias("first_order_date")
        )
    
    # Join with customer dimension
    df_enriched = df_customers \
        .join(df_customer_agg, "customer_id", "left") \
        .na.fill({
            "lifetime_revenue": 0.0,
            "lifetime_profit": 0.0,
            "total_items_purchased": 0,
            "total_orders": 0,
            "unique_products_bought": 0,
            "avg_order_value": 0.0
        })
    
    # Calculate RFM metrics
    from datetime import datetime, timedelta
    current_date = datetime.now().date()
    
    df_rfm = df_enriched \
        .withColumn("days_since_last_order",
            when(col("last_order_date").isNotNull(),
                 datediff(col("load_timestamp"), col("last_order_date"))
            ).otherwise(9999)
        ) \
        .withColumn("days_as_customer",
            when(col("first_order_date").isNotNull(),
                 datediff(col("load_timestamp"), col("first_order_date"))
            ).otherwise(0)
        )
    
    # RFM scoring (1-5 scale)
    window_recency = Window.orderBy(col("days_since_last_order"))
    window_frequency = Window.orderBy(col("total_orders").desc())
    window_monetary = Window.orderBy(col("lifetime_revenue").desc())
    
    df_final = df_rfm \
        .withColumn("recency_score",
            when(col("days_since_last_order") <= 30, 5)
            .when(col("days_since_last_order") <= 90, 4)
            .when(col("days_since_last_order") <= 180, 3)
            .when(col("days_since_last_order") <= 365, 2)
            .otherwise(1)
        ) \
        .withColumn("frequency_score",
            when(col("total_orders") >= 10, 5)
            .when(col("total_orders") >= 7, 4)
            .when(col("total_orders") >= 4, 3)
            .when(col("total_orders") >= 2, 2)
            .otherwise(1)
        ) \
        .withColumn("monetary_score",
            when(col("lifetime_revenue") >= 1000, 5)
            .when(col("lifetime_revenue") >= 500, 4)
            .when(col("lifetime_revenue") >= 200, 3)
            .when(col("lifetime_revenue") >= 50, 2)
            .otherwise(1)
        ) \
        .withColumn("rfm_score",
            concat_ws("-", col("recency_score"), col("frequency_score"), col("monetary_score"))
        ) \
        .withColumn("customer_segment",
            when((col("recency_score") >= 4) & (col("frequency_score") >= 4) & (col("monetary_score") >= 4), "Champions")
            .when((col("recency_score") >= 3) & (col("frequency_score") >= 3), "Loyal Customers")
            .when((col("recency_score") >= 4) & (col("frequency_score") <= 2), "Promising")
            .when((col("recency_score") <= 2) & (col("frequency_score") >= 4), "At Risk")
            .when((col("recency_score") <= 2) & (col("monetary_score") >= 4), "Can't Lose Them")
            .when(col("recency_score") <= 2, "Hibernating")
            .otherwise("Needs Attention")
        ) \
        .withColumn("load_timestamp", current_timestamp()) \
        .select(
            "customer_key",
            "customer_id",
            "full_name",
            "email",
            "country",
            "segment",
            "lifetime_revenue",
            "lifetime_profit",
            "total_orders",
            "total_items_purchased",
            "unique_products_bought",
            "avg_order_value",
            "first_order_date",
            "last_order_date",
            "days_since_last_order",
            "days_as_customer",
            "recency_score",
            "frequency_score",
            "monetary_score",
            "rfm_score",
            "customer_segment",
            "load_timestamp"
        )
    
    print(f"Customer 360 records: {df_final.count():,}")
    
    # Customer segment distribution
    print("\nCustomer Segment Distribution:")
    df_final.groupBy("customer_segment").count().orderBy(col("count").desc()).show()
    
    # Write to Gold
    df_final.write \
        .mode("overwrite") \
        .partitionBy("country") \
        .parquet(f"{gold_path}/customer_360/")
    
    print(f"✓ Customer 360 written to {gold_path}/customer_360/")
    return df_final


def create_category_analysis(spark, silver_path, gold_path):
    """
    Category performance analysis
    - Revenue by category
    - Growth trends
    - Product mix
    """
    print("Creating category analysis...")
    
    df_orders = spark.read.parquet(f"{silver_path}/fact_orders/")
    
    # Category aggregation
    df_category = df_orders \
        .groupBy("category", "year", "month") \
        .agg(
            sum("revenue").alias("total_revenue"),
            sum("profit").alias("total_profit"),
            sum("quantity").alias("total_quantity"),
            countDistinct("product_id").alias("unique_products"),
            countDistinct("customer_id").alias("unique_customers"),
            countDistinct("order_id").alias("total_orders")
        ) \
        .withColumn("profit_margin",
            round((col("total_profit") / col("total_revenue")) * 100, 2)
        ) \
        .withColumn("revenue_per_product",
            round(col("total_revenue") / col("unique_products"), 2)
        ) \
        .withColumn("load_timestamp", current_timestamp())
    
    print(f"Category analysis records: {df_category.count():,}")
    
    # Write to Gold
    df_category.write \
        .mode("overwrite") \
        .partitionBy("year", "month") \
        .parquet(f"{gold_path}/category_analysis/")
    
    print(f"✓ Category analysis written to {gold_path}/category_analysis/")
    return df_category


def create_cohort_analysis(spark, silver_path, gold_path):
    """
    Customer cohort analysis
    - Group customers by first purchase month
    - Track retention over time
    """
    print("Creating cohort analysis...")
    
    df_orders = spark.read.parquet(f"{silver_path}/fact_orders/")
    
    # Get first purchase date per customer
    df_first_purchase = df_orders \
        .groupBy("customer_id") \
        .agg(
            min("order_date").alias("first_purchase_date"),
            year(min("order_date")).alias("cohort_year"),
            month(min("order_date")).alias("cohort_month")
        )
    
    # Join with all orders
    df_cohort = df_orders \
        .join(df_first_purchase, "customer_id") \
        .withColumn("months_since_first_purchase",
            ((col("year") - col("cohort_year")) * 12) + (col("month") - col("cohort_month"))
        )
    
    # Aggregate by cohort
    df_cohort_agg = df_cohort \
        .groupBy("cohort_year", "cohort_month", "months_since_first_purchase") \
        .agg(
            countDistinct("customer_id").alias("active_customers"),
            sum("revenue").alias("cohort_revenue"),
            avg("revenue").alias("avg_revenue_per_customer")
        ) \
        .withColumn("cohort_period", concat_ws("-", col("cohort_year"), col("cohort_month"))) \
        .withColumn("load_timestamp", current_timestamp())
    
    print(f"Cohort analysis records: {df_cohort_agg.count():,}")
    
    # Write to Gold
    df_cohort_agg.write \
        .mode("overwrite") \
        .parquet(f"{gold_path}/cohort_analysis/")
    
    print(f"✓ Cohort analysis written to {gold_path}/cohort_analysis/")
    return df_cohort_agg


def main():
    """Main aggregation process"""
    
    print("=" * 60)
    print("SILVER TO GOLD ETL JOB")
    print("=" * 60)
    
    # Get S3 paths
    bucket = sys.argv[1] if len(sys.argv) > 1 else "ecommerce-data-platform-datalake"
    silver_path = f"s3://{bucket}/silver"
    gold_path = f"s3://{bucket}/gold"
    
    print(f"Silver path: {silver_path}")
    print(f"Gold path: {gold_path}")
    print("")
    
    # Create Spark session
    spark = create_spark_session()
    spark.sparkContext.setLogLevel("WARN")
    
    try:
        # Create all gold tables
        df_daily_sales = create_daily_sales_summary(spark, silver_path, gold_path)
        df_product_perf = create_product_performance(spark, silver_path, gold_path)
        df_customer_360 = create_customer_360(spark, silver_path, gold_path)
        df_category = create_category_analysis(spark, silver_path, gold_path)
        df_cohort = create_cohort_analysis(spark, silver_path, gold_path)
        
        # Print summary
        print("")
        print("=" * 60)
        print("ETL SUMMARY")
        print("=" * 60)
        print(f"Daily Sales Summary: {df_daily_sales.count():,} records")
        print(f"Product Performance: {df_product_perf.count():,} records")
        print(f"Customer 360: {df_customer_360.count():,} records")
        print(f"Category Analysis: {df_category.count():,} records")
        print(f"Cohort Analysis: {df_cohort.count():,} records")
        print("=" * 60)
        print("✓ Silver to Gold ETL completed successfully!")
        
    except Exception as e:
        print(f"❌ ERROR: {str(e)}")
        raise
    finally:
        spark.stop()


if __name__ == "__main__":
    main()