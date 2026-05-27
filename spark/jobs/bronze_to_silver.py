"""
Bronze to Silver ETL Job
Cleans, validates, and transforms raw data into curated format
"""

from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, current_timestamp, to_date, year, month, day,
    when, regexp_replace, trim, lower, upper, concat_ws,
    row_number, dense_rank, lit, coalesce, monotonically_increasing_id
)
from pyspark.sql.window import Window
from pyspark.sql.types import StructType, StructField, StringType, DoubleType, IntegerType, TimestampType
from datetime import datetime, timedelta
import sys


def create_spark_session(app_name="BronzeToSilver"):
    """Create Spark session with optimized configs"""
    return SparkSession.builder \
        .appName(app_name) \
        .config("spark.sql.adaptive.enabled", "true") \
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true") \
        .config("spark.sql.parquet.compression.codec", "snappy") \
        .config("spark.sql.sources.partitionOverwriteMode", "dynamic") \
        .enableHiveSupport() \
        .getOrCreate()


def clean_products(spark, bronze_path, silver_path):
    """
    Clean and transform products data
    - Remove duplicates
    - Standardize categories
    - Create surrogate keys (SCD Type 2)
    """
    print("Processing products...")
    
    # Read bronze data
    df = spark.read.json(f"{bronze_path}/products/")
    
    # Data quality checks
    initial_count = df.count()
    print(f"Initial products: {initial_count}")
    
    # Clean data
    df_clean = df \
        .dropDuplicates(["id"]) \
        .filter(col("id").isNotNull()) \
        .filter(col("price") > 0) \
        .withColumn("product_name", trim(col("title"))) \
        .withColumn("category", upper(trim(col("category")))) \
        .withColumn("price", col("price").cast("decimal(10,2)")) \
        .withColumn("rating", coalesce(col("rating.rate"), lit(0.0)).cast("decimal(3,2)")) \
        .withColumn("review_count", coalesce(col("rating.count"), lit(0)).cast("integer"))
    
    # Create surrogate key and SCD Type 2 columns
    df_final = df_clean \
        .withColumn("product_key", monotonically_increasing_id()) \
        .withColumn("product_id", col("id").cast("string")) \
        .withColumn("effective_date", to_date(current_timestamp())) \
        .withColumn("expiration_date", lit("2099-12-31").cast("date")) \
        .withColumn("is_current", lit(True)) \
        .withColumn("load_timestamp", current_timestamp()) \
        .select(
            "product_key",
            "product_id",
            "product_name",
            "category",
            "price",
            "rating",
            "review_count",
            col("description").alias("product_description"),
            col("image").alias("image_url"),
            "effective_date",
            "expiration_date",
            "is_current",
            "load_timestamp"
        )
    
    final_count = df_final.count()
    print(f"Final products: {final_count} (removed {initial_count - final_count} invalid records)")
    
    # Write to Silver (partitioned by category)
    df_final.write \
        .mode("overwrite") \
        .partitionBy("category") \
        .parquet(f"{silver_path}/dim_products/")
    
    print(f"✓ Products written to {silver_path}/dim_products/")
    return df_final


def clean_customers(spark, bronze_path, silver_path):
    """
    Clean and transform customers data
    - Deduplicate by email
    - Standardize names
    - Create customer segments
    """
    print("Processing customers...")
    
    # Read bronze data
    df = spark.read.json(f"{bronze_path}/customers/")
    
    initial_count = df.count()
    print(f"Initial customers: {initial_count}")
    
    # Clean data
    df_clean = df \
        .dropDuplicates(["email"]) \
        .filter(col("email").isNotNull()) \
        .withColumn("customer_id", col("id").cast("string")) \
        .withColumn("first_name", trim(col("name.firstname"))) \
        .withColumn("last_name", trim(col("name.lastname"))) \
        .withColumn("full_name", concat_ws(" ", col("first_name"), col("last_name"))) \
        .withColumn("email", lower(trim(col("email")))) \
        .withColumn("phone", regexp_replace(col("phone"), "[^0-9]", "")) \
        .withColumn("city", trim(col("address.city"))) \
        .withColumn("street", trim(col("address.street"))) \
        .withColumn("zipcode", trim(col("address.zipcode"))) \
        .withColumn("country", upper(trim(coalesce(col("address.country"), lit("US")))))
    
    # Create customer segments (based on mock data - you can enhance this)
    df_segmented = df_clean \
        .withColumn("segment", 
            when(col("customer_id").cast("int") % 10 == 0, "VIP")
            .when(col("customer_id").cast("int") % 5 == 0, "ACTIVE")
            .otherwise("NEW")
        ) \
        .withColumn("lifetime_value", lit(0.0).cast("decimal(10,2)"))  # Will be updated later
    
    # Create surrogate key and SCD Type 2
    df_final = df_segmented \
        .withColumn("customer_key", monotonically_increasing_id()) \
        .withColumn("effective_date", to_date(current_timestamp())) \
        .withColumn("expiration_date", lit("2099-12-31").cast("date")) \
        .withColumn("is_current", lit(True)) \
        .withColumn("load_timestamp", current_timestamp()) \
        .select(
            "customer_key",
            "customer_id",
            "full_name",
            "first_name",
            "last_name",
            "email",
            "phone",
            "street",
            "city",
            "zipcode",
            "country",
            "segment",
            "lifetime_value",
            "effective_date",
            "expiration_date",
            "is_current",
            "load_timestamp"
        )
    
    final_count = df_final.count()
    print(f"Final customers: {final_count}")
    
    # Write to Silver (partitioned by country)
    df_final.write \
        .mode("overwrite") \
        .partitionBy("country") \
        .parquet(f"{silver_path}/dim_customers/")
    
    print(f"✓ Customers written to {silver_path}/dim_customers/")
    return df_final


def clean_orders(spark, bronze_path, silver_path):
    """
    Clean and transform orders data (fact table)
    - Join with products and customers
    - Calculate metrics
    - Handle incremental loads
    """
    print("Processing orders...")
    
    # Read bronze data
    df_orders = spark.read.json(f"{bronze_path}/orders/")
    
    initial_count = df_orders.count()
    print(f"Initial orders: {initial_count}")
    
    # Explode products array to get order items
    from pyspark.sql.functions import explode, size
    
    df_exploded = df_orders \
        .filter(col("id").isNotNull()) \
        .withColumn("order_id", col("id").cast("string")) \
        .withColumn("customer_id", col("userId").cast("string")) \
        .withColumn("order_date", to_date(col("date"))) \
        .withColumn("product", explode(col("products"))) \
        .withColumn("product_id", col("product.productId").cast("string")) \
        .withColumn("quantity", col("product.quantity").cast("integer"))
    
    # Read dimension tables for lookups
    dim_products = spark.read.parquet(f"{silver_path}/dim_products/") \
        .filter(col("is_current") == True) \
        .select("product_key", "product_id", "price", "category")
    
    dim_customers = spark.read.parquet(f"{silver_path}/dim_customers/") \
        .filter(col("is_current") == True) \
        .select("customer_key", "customer_id")
    
    # Join with dimensions
    df_enriched = df_exploded \
        .join(dim_products, "product_id", "left") \
        .join(dim_customers, "customer_id", "left")
    
    # Calculate metrics
    df_final = df_enriched \
        .withColumn("revenue", (col("quantity") * col("price")).cast("decimal(10,2)")) \
        .withColumn("cost", (col("revenue") * 0.6).cast("decimal(10,2)"))  # Mock cost (60% of revenue)
        .withColumn("profit", (col("revenue") - col("cost")).cast("decimal(10,2)")) \
        .withColumn("discount", lit(0.0).cast("decimal(10,2)"))  # Can be enhanced
        .withColumn("load_timestamp", current_timestamp()) \
        .withColumn("year", year(col("order_date"))) \
        .withColumn("month", month(col("order_date"))) \
        .withColumn("day", day(col("order_date"))) \
        .select(
            "order_id",
            "order_date",
            "customer_key",
            "customer_id",
            "product_key",
            "product_id",
            "category",
            "quantity",
            "revenue",
            "cost",
            "profit",
            "discount",
            "year",
            "month",
            "day",
            "load_timestamp"
        ) \
        .filter(col("product_key").isNotNull()) \
        .filter(col("customer_key").isNotNull())
    
    final_count = df_final.count()
    print(f"Final order items: {final_count}")
    
    # Write to Silver (partitioned by year, month)
    df_final.write \
        .mode("overwrite") \
        .partitionBy("year", "month") \
        .parquet(f"{silver_path}/fact_orders/")
    
    print(f"✓ Orders written to {silver_path}/fact_orders/")
    return df_final


def create_date_dimension(spark, silver_path, start_date="2023-01-01", end_date="2025-12-31"):
    """
    Create date dimension table
    Pre-populated calendar with useful attributes
    """
    print("Creating date dimension...")
    
    from datetime import datetime, timedelta
    
    # Generate date range
    start = datetime.strptime(start_date, "%Y-%m-%d")
    end = datetime.strptime(end_date, "%Y-%m-%d")
    
    date_list = []
    current = start
    while current <= end:
        date_list.append({
            "date": current.strftime("%Y-%m-%d"),
            "year": current.year,
            "quarter": (current.month - 1) // 3 + 1,
            "month": current.month,
            "month_name": current.strftime("%B"),
            "week": current.isocalendar()[1],
            "day": current.day,
            "day_of_week": current.weekday() + 1,  # Monday = 1
            "day_name": current.strftime("%A"),
            "is_weekend": current.weekday() >= 5,
            "is_holiday": False  # Can be enhanced with holiday logic
        })
        current += timedelta(days=1)
    
    # Create DataFrame
    df_dates = spark.createDataFrame(date_list) \
        .withColumn("date_key", 
            (col("year") * 10000 + col("month") * 100 + col("day")).cast("integer")
        )
    
    print(f"Generated {df_dates.count()} dates")
    
    # Write to Silver
    df_dates.write \
        .mode("overwrite") \
        .parquet(f"{silver_path}/dim_date/")
    
    print(f"✓ Date dimension written to {silver_path}/dim_date/")
    return df_dates


def main():
    """Main ETL process"""
    
    print("=" * 60)
    print("BRONZE TO SILVER ETL JOB")
    print("=" * 60)
    
    # Get S3 paths from arguments or use defaults
    bucket = sys.argv[1] if len(sys.argv) > 1 else "ecommerce-data-platform-datalake"
    bronze_path = f"s3://{bucket}/bronze"
    silver_path = f"s3://{bucket}/silver"
    
    print(f"Bronze path: {bronze_path}")
    print(f"Silver path: {silver_path}")
    print("")
    
    # Create Spark session
    spark = create_spark_session()
    spark.sparkContext.setLogLevel("WARN")
    
    try:
        # Process dimensions first (for foreign keys)
        df_products = clean_products(spark, bronze_path, silver_path)
        df_customers = clean_customers(spark, bronze_path, silver_path)
        
        # Create date dimension
        df_dates = create_date_dimension(spark, silver_path)
        
        # Process facts
        df_orders = clean_orders(spark, bronze_path, silver_path)
        
        # Print summary
        print("")
        print("=" * 60)
        print("ETL SUMMARY")
        print("=" * 60)
        print(f"Products: {df_products.count():,} records")
        print(f"Customers: {df_customers.count():,} records")
        print(f"Dates: {df_dates.count():,} records")
        print(f"Order items: {df_orders.count():,} records")
        print("=" * 60)
        print("✓ Bronze to Silver ETL completed successfully!")
        
    except Exception as e:
        print(f"❌ ERROR: {str(e)}")
        raise
    finally:
        spark.stop()


if __name__ == "__main__":
    main()