
"""
Data Generator Lambda
Generates realistic e-commerce data using Faker and external APIs
Writes to Bronze layer in S3
"""

import json
import boto3
import os
from datetime import datetime, timedelta
from decimal import Decimal
import random
import uuid

# AWS clients
s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

# Environment variables
DATA_LAKE_BUCKET = os.environ.get('DATA_LAKE_BUCKET')
WATERMARK_TABLE = os.environ.get('WATERMARK_TABLE')


def generate_products(count=50):
    """
    Generate fake product data
    Using predefined categories and realistic prices
    """
    categories = ['ELECTRONICS', 'CLOTHING', 'BOOKS', 'HOME', 'SPORTS', 'TOYS']
    
    products = []
    for i in range(1, count + 1):
        category = random.choice(categories)
        
        # Category-specific pricing
        price_ranges = {
            'ELECTRONICS': (50, 500),
            'CLOTHING': (20, 150),
            'BOOKS': (10, 40),
            'HOME': (15, 200),
            'SPORTS': (25, 300),
            'TOYS': (10, 80)
        }
        
        min_price, max_price = price_ranges[category]
        price = round(random.uniform(min_price, max_price), 2)
        
        product = {
            'id': i,
            'title': f"{category.title()} Product {i}",
            'price': price,
            'description': f"High quality {category.lower()} product with excellent features",
            'category': category,
            'image': f"https://fakestoreapi.com/img/{i}.jpg",
            'rating': {
                'rate': round(random.uniform(3.0, 5.0), 1),
                'count': random.randint(50, 500)
            }
        }
        products.append(product)
    
    return products


def generate_customers(count=100):
    """
    Generate fake customer data
    """
    first_names = ['John', 'Jane', 'Michael', 'Emily', 'David', 'Sarah', 'James', 'Emma', 
                   'Robert', 'Olivia', 'William', 'Sophia', 'Richard', 'Isabella', 'Joseph']
    last_names = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 
                  'Davis', 'Rodriguez', 'Martinez', 'Hernandez', 'Lopez', 'Wilson']
    cities = ['New York', 'Los Angeles', 'Chicago', 'Houston', 'Phoenix', 'Philadelphia',
              'San Antonio', 'San Diego', 'Dallas', 'San Jose']
    
    customers = []
    for i in range(1, count + 1):
        first_name = random.choice(first_names)
        last_name = random.choice(last_names)
        city = random.choice(cities)
        
        customer = {
            'id': i,
            'email': f"{first_name.lower()}.{last_name.lower()}{i}@email.com",
            'username': f"{first_name.lower()}{i}",
            'password': 'hashed_password',  # Mock
            'name': {
                'firstname': first_name,
                'lastname': last_name
            },
            'address': {
                'city': city,
                'street': f"{random.randint(100, 9999)} Main St",
                'number': random.randint(1, 200),
                'zipcode': f"{random.randint(10000, 99999)}",
                'geolocation': {
                    'lat': str(round(random.uniform(25.0, 49.0), 6)),
                    'long': str(round(random.uniform(-125.0, -65.0), 6))
                }
            },
            'phone': f"{random.randint(100, 999)}-{random.randint(100, 999)}-{random.randint(1000, 9999)}"
        }
        customers.append(customer)
    
    return customers


def generate_orders(customer_count=100, product_count=50, orders_count=200):
    """
    Generate fake order data
    Creates orders over the last 90 days
    """
    orders = []
    
    # Generate orders over last 90 days
    end_date = datetime.now()
    start_date = end_date - timedelta(days=90)
    
    for i in range(1, orders_count + 1):
        # Random date within last 90 days
        days_ago = random.randint(0, 90)
        order_date = end_date - timedelta(days=days_ago)
        
        # Random customer
        customer_id = random.randint(1, customer_count)
        
        # Random number of products (1-5 items per order)
        num_products = random.randint(1, 5)
        products = []
        
        for _ in range(num_products):
            products.append({
                'productId': random.randint(1, product_count),
                'quantity': random.randint(1, 3)
            })
        
        order = {
            'id': i,
            'userId': customer_id,
            'date': order_date.strftime('%Y-%m-%d'),
            'products': products,
            'status': random.choice(['completed', 'processing', 'shipped'])
        }
        orders.append(order)
    
    return orders


def generate_events(count=500):
    """
    Generate fake event/clickstream data
    Page views, add to cart, purchases
    """
    event_types = ['page_view', 'product_view', 'add_to_cart', 'remove_from_cart', 'purchase']
    
    events = []
    now = datetime.now()
    
    for i in range(count):
        # Events over last 24 hours
        minutes_ago = random.randint(0, 1440)  # 24 hours = 1440 minutes
        event_time = now - timedelta(minutes=minutes_ago)
        
        event = {
            'event_id': str(uuid.uuid4()),
            'event_type': random.choice(event_types),
            'timestamp': event_time.isoformat(),
            'user_id': random.randint(1, 100),
            'session_id': str(uuid.uuid4()),
            'product_id': random.randint(1, 50),
            'page_url': f"/products/{random.randint(1, 50)}",
            'referrer': random.choice(['google', 'facebook', 'direct', 'email']),
            'device': random.choice(['desktop', 'mobile', 'tablet'])
        }
        events.append(event)
    
    return events


def save_to_s3(data, prefix, filename):
    """
    Save data to S3 in JSON format
    """
    today = datetime.now()
    date_partition = today.strftime('date=%Y-%m-%d')
    
    s3_key = f"{prefix}/{date_partition}/{filename}.json"
    
    # Convert to JSON
    json_data = json.dumps(data, indent=2, default=str)
    
    # Upload to S3
    s3.put_object(
        Bucket=DATA_LAKE_BUCKET,
        Key=s3_key,
        Body=json_data.encode('utf-8'),
        ContentType='application/json'
    )
    
    print(f"✓ Saved {len(data)} records to s3://{DATA_LAKE_BUCKET}/{s3_key}")
    return s3_key


def save_events_partitioned(events):
    """
    Save events with year/month/day partitioning
    """
    today = datetime.now()
    year = today.year
    month = today.month
    day = today.day
    
    s3_key = f"bronze/events/year={year}/month={month:02d}/day={day:02d}/events_{today.strftime('%Y%m%d_%H%M%S')}.json"
    
    json_data = json.dumps(events, indent=2, default=str)
    
    s3.put_object(
        Bucket=DATA_LAKE_BUCKET,
        Key=s3_key,
        Body=json_data.encode('utf-8'),
        ContentType='application/json'
    )
    
    print(f"✓ Saved {len(events)} events to s3://{DATA_LAKE_BUCKET}/{s3_key}")
    return s3_key


def update_watermark(pipeline_name, last_run_date):
    """
    Update watermark in DynamoDB for incremental loads
    """
    try:
        table = dynamodb.Table(WATERMARK_TABLE)
        
        table.put_item(
            Item={
                'pipeline_name': pipeline_name,
                'last_run_date': last_run_date,
                'last_run_timestamp': datetime.now().isoformat(),
                'status': 'completed'
            }
        )
        
        print(f"✓ Updated watermark for {pipeline_name}")
    except Exception as e:
        print(f"Warning: Could not update watermark: {str(e)}")


def lambda_handler(event, context):
    """
    Main Lambda handler
    Generates data and saves to Bronze layer
    """
    
    print("=" * 60)
    print("DATA GENERATOR LAMBDA")
    print("=" * 60)
    print(f"Bucket: {DATA_LAKE_BUCKET}")
    print("")
    
    try:
        # Check event for custom parameters
        config = event.get('config', {})
        num_products = config.get('products', 50)
        num_customers = config.get('customers', 100)
        num_orders = config.get('orders', 200)
        num_events = config.get('events', 500)
        
        print(f"Generating data:")
        print(f"  - Products: {num_products}")
        print(f"  - Customers: {num_customers}")
        print(f"  - Orders: {num_orders}")
        print(f"  - Events: {num_events}")
        print("")
        
        # Generate data
        products = generate_products(num_products)
        customers = generate_customers(num_customers)
        orders = generate_orders(num_customers, num_products, num_orders)
        events = generate_events(num_events)
        
        # Save to S3
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        
        products_key = save_to_s3(products, 'bronze/products', f'products_{timestamp}')
        customers_key = save_to_s3(customers, 'bronze/customers', f'customers_{timestamp}')
        orders_key = save_to_s3(orders, 'bronze/orders', f'orders_{timestamp}')
        events_key = save_events_partitioned(events)
        
        # Update watermarks
        today_str = datetime.now().strftime('%Y-%m-%d')
        update_watermark('products', today_str)
        update_watermark('customers', today_str)
        update_watermark('orders', today_str)
        update_watermark('events', today_str)
        
        # Summary
        summary = {
            'status': 'success',
            'timestamp': datetime.now().isoformat(),
            'records_generated': {
                'products': len(products),
                'customers': len(customers),
                'orders': len(orders),
                'events': len(events)
            },
            's3_keys': {
                'products': products_key,
                'customers': customers_key,
                'orders': orders_key,
                'events': events_key
            }
        }
        
        print("")
        print("=" * 60)
        print("DATA GENERATION SUMMARY")
        print("=" * 60)
        print(f"Products: {len(products):,} records")
        print(f"Customers: {len(customers):,} records")
        print(f"Orders: {len(orders):,} records")
        print(f"Events: {len(events):,} records")
        print("=" * 60)
        print("✓ Data generation completed successfully!")
        
        return {
            'statusCode': 200,
            'body': json.dumps(summary, default=str)
        }
        
    except Exception as e:
        print(f"❌ ERROR: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'status': 'error',
                'error': str(e)
            })
        }
