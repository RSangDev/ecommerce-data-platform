"""
Data Quality Lambda
Validates data quality using Great Expectations-like checks
Stores results in DynamoDB
"""

import json
import boto3
import os
from datetime import datetime
from decimal import Decimal
import uuid

# AWS clients
s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
sns = boto3.client('sns')

# Environment variables
DATA_LAKE_BUCKET = os.environ.get('DATA_LAKE_BUCKET')
DQ_TABLE = os.environ.get('DQ_TABLE')
ALERT_TOPIC = os.environ.get('ALERT_TOPIC', '')


class DataQualityChecker:
    """Data quality validation class"""
    
    def __init__(self, table_name, data_path):
        self.table_name = table_name
        self.data_path = data_path
        self.checks_passed = 0
        self.checks_failed = 0
        self.results = []
    
    def check_not_null(self, data, column_name):
        """Check for null values in column"""
        check_name = f"{self.table_name}.{column_name}.not_null"
        
        try:
            null_count = sum(1 for row in data if row.get(column_name) is None)
            total_count = len(data)
            null_percentage = (null_count / total_count * 100) if total_count > 0 else 0
            
            passed = null_count == 0
            
            result = {
                'check_name': check_name,
                'check_type': 'not_null',
                'column': column_name,
                'passed': passed,
                'null_count': null_count,
                'total_count': total_count,
                'null_percentage': round(null_percentage, 2),
                'threshold': 0
            }
            
            self._record_result(result)
            return passed
            
        except Exception as e:
            self._record_error(check_name, str(e))
            return False
    
    def check_unique(self, data, column_name):
        """Check for unique values"""
        check_name = f"{self.table_name}.{column_name}.unique"
        
        try:
            values = [row.get(column_name) for row in data if row.get(column_name) is not None]
            unique_values = set(values)
            
            duplicate_count = len(values) - len(unique_values)
            passed = duplicate_count == 0
            
            result = {
                'check_name': check_name,
                'check_type': 'unique',
                'column': column_name,
                'passed': passed,
                'total_values': len(values),
                'unique_values': len(unique_values),
                'duplicate_count': duplicate_count
            }
            
            self._record_result(result)
            return passed
            
        except Exception as e:
            self._record_error(check_name, str(e))
            return False
    
    def check_range(self, data, column_name, min_value=None, max_value=None):
        """Check if values are within range"""
        check_name = f"{self.table_name}.{column_name}.range"
        
        try:
            values = [row.get(column_name) for row in data if row.get(column_name) is not None]
            
            if not values:
                return True
            
            out_of_range = []
            for val in values:
                try:
                    numeric_val = float(val)
                    if min_value is not None and numeric_val < min_value:
                        out_of_range.append(val)
                    elif max_value is not None and numeric_val > max_value:
                        out_of_range.append(val)
                except (ValueError, TypeError):
                    continue
            
            passed = len(out_of_range) == 0
            
            result = {
                'check_name': check_name,
                'check_type': 'range',
                'column': column_name,
                'passed': passed,
                'min_value': min_value,
                'max_value': max_value,
                'out_of_range_count': len(out_of_range),
                'total_count': len(values)
            }
            
            self._record_result(result)
            return passed
            
        except Exception as e:
            self._record_error(check_name, str(e))
            return False
    
    def check_row_count(self, data, min_rows=0, max_rows=None):
        """Check table row count"""
        check_name = f"{self.table_name}.row_count"
        
        try:
            row_count = len(data)
            
            passed = row_count >= min_rows
            if max_rows is not None:
                passed = passed and row_count <= max_rows
            
            result = {
                'check_name': check_name,
                'check_type': 'row_count',
                'passed': passed,
                'row_count': row_count,
                'min_rows': min_rows,
                'max_rows': max_rows
            }
            
            self._record_result(result)
            return passed
            
        except Exception as e:
            self._record_error(check_name, str(e))
            return False
    
    def check_value_set(self, data, column_name, valid_values):
        """Check if values are in allowed set"""
        check_name = f"{self.table_name}.{column_name}.value_set"
        
        try:
            values = [row.get(column_name) for row in data if row.get(column_name) is not None]
            
            invalid_values = [v for v in values if v not in valid_values]
            passed = len(invalid_values) == 0
            
            result = {
                'check_name': check_name,
                'check_type': 'value_set',
                'column': column_name,
                'passed': passed,
                'valid_values': list(valid_values),
                'invalid_count': len(invalid_values),
                'total_count': len(values)
            }
            
            self._record_result(result)
            return passed
            
        except Exception as e:
            self._record_error(check_name, str(e))
            return False
    
    def _record_result(self, result):
        """Record check result"""
        if result['passed']:
            self.checks_passed += 1
        else:
            self.checks_failed += 1
        
        self.results.append(result)
    
    def _record_error(self, check_name, error_message):
        """Record check error"""
        self.checks_failed += 1
        self.results.append({
            'check_name': check_name,
            'passed': False,
            'error': error_message
        })
    
    def get_summary(self):
        """Get validation summary"""
        total_checks = self.checks_passed + self.checks_failed
        success_rate = (self.checks_passed / total_checks * 100) if total_checks > 0 else 0
        
        return {
            'table_name': self.table_name,
            'total_checks': total_checks,
            'checks_passed': self.checks_passed,
            'checks_failed': self.checks_failed,
            'success_rate': round(success_rate, 2),
            'all_passed': self.checks_failed == 0
        }


def read_json_from_s3(bucket, key):
    """Read JSON data from S3"""
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        data = json.loads(content)
        return data
    except Exception as e:
        print(f"Error reading {key}: {str(e)}")
        return []


def validate_products(bucket, date_str):
    """Validate products data"""
    print("Validating products...")
    
    key = f"bronze/products/date={date_str}/"
    
    # List files in partition
    try:
        response = s3.list_objects_v2(Bucket=bucket, Prefix=key)
        if 'Contents' not in response or len(response['Contents']) == 0:
            print(f"No products found for {date_str}")
            return None
        
        # Read first file
        file_key = response['Contents'][0]['Key']
        data = read_json_from_s3(bucket, file_key)
        
        if not data:
            return None
        
        # Create checker
        checker = DataQualityChecker('products', f"s3://{bucket}/{key}")
        
        # Run checks
        checker.check_not_null(data, 'id')
        checker.check_not_null(data, 'title')
        checker.check_not_null(data, 'price')
        checker.check_unique(data, 'id')
        checker.check_range(data, 'price', min_value=0, max_value=10000)
        checker.check_row_count(data, min_rows=1, max_rows=1000)
        checker.check_value_set(data, 'category', 
            {'ELECTRONICS', 'CLOTHING', 'BOOKS', 'HOME', 'SPORTS', 'TOYS'})
        
        return checker
        
    except Exception as e:
        print(f"Error validating products: {str(e)}")
        return None


def validate_customers(bucket, date_str):
    """Validate customers data"""
    print("Validating customers...")
    
    key = f"bronze/customers/date={date_str}/"
    
    try:
        response = s3.list_objects_v2(Bucket=bucket, Prefix=key)
        if 'Contents' not in response or len(response['Contents']) == 0:
            print(f"No customers found for {date_str}")
            return None
        
        file_key = response['Contents'][0]['Key']
        data = read_json_from_s3(bucket, file_key)
        
        if not data:
            return None
        
        checker = DataQualityChecker('customers', f"s3://{bucket}/{key}")
        
        checker.check_not_null(data, 'id')
        checker.check_not_null(data, 'email')
        checker.check_unique(data, 'id')
        checker.check_unique(data, 'email')
        checker.check_row_count(data, min_rows=1, max_rows=10000)
        
        return checker
        
    except Exception as e:
        print(f"Error validating customers: {str(e)}")
        return None


def validate_orders(bucket, date_str):
    """Validate orders data"""
    print("Validating orders...")
    
    key = f"bronze/orders/date={date_str}/"
    
    try:
        response = s3.list_objects_v2(Bucket=bucket, Prefix=key)
        if 'Contents' not in response or len(response['Contents']) == 0:
            print(f"No orders found for {date_str}")
            return None
        
        file_key = response['Contents'][0]['Key']
        data = read_json_from_s3(bucket, file_key)
        
        if not data:
            return None
        
        checker = DataQualityChecker('orders', f"s3://{bucket}/{key}")
        
        checker.check_not_null(data, 'id')
        checker.check_not_null(data, 'userId')
        checker.check_not_null(data, 'date')
        checker.check_unique(data, 'id')
        checker.check_row_count(data, min_rows=1)
        
        return checker
        
    except Exception as e:
        print(f"Error validating orders: {str(e)}")
        return None


def save_results_to_dynamodb(checker, run_id):
    """Save DQ results to DynamoDB"""
    if not checker or not DQ_TABLE:
        return
    
    try:
        table = dynamodb.Table(DQ_TABLE)
        
        summary = checker.get_summary()
        timestamp = datetime.now().isoformat()
        
        # Save summary
        table.put_item(
            Item={
                'check_id': f"{checker.table_name}_{run_id}",
                'timestamp': timestamp,
                'table_name': checker.table_name,
                'run_id': run_id,
                'total_checks': summary['total_checks'],
                'checks_passed': summary['checks_passed'],
                'checks_failed': summary['checks_failed'],
                'success_rate': Decimal(str(summary['success_rate'])),
                'all_passed': summary['all_passed'],
                'results': json.dumps(checker.results, default=str)
            }
        )
        
        print(f"✓ Saved DQ results for {checker.table_name}")
        
    except Exception as e:
        print(f"Error saving to DynamoDB: {str(e)}")


def send_alert_if_failed(summaries):
    """Send SNS alert if checks failed"""
    if not ALERT_TOPIC:
        return
    
    failed_tables = [s for s in summaries if not s.get('all_passed')]
    
    if not failed_tables:
        return
    
    try:
        message = "Data Quality Checks Failed!\n\n"
        
        for summary in failed_tables:
            message += f"Table: {summary['table_name']}\n"
            message += f"  Checks Failed: {summary['checks_failed']}/{summary['total_checks']}\n"
            message += f"  Success Rate: {summary['success_rate']}%\n\n"
        
        sns.publish(
            TopicArn=ALERT_TOPIC,
            Subject='Data Quality Alert',
            Message=message
        )
        
        print("✓ Alert sent")
        
    except Exception as e:
        print(f"Error sending alert: {str(e)}")


def lambda_handler(event, context):
    """Main Lambda handler"""
    
    print("=" * 60)
    print("DATA QUALITY CHECKER")
    print("=" * 60)
    print(f"Bucket: {DATA_LAKE_BUCKET}")
    print("")
    
    try:
        # Get date (from event or use today)
        date_str = event.get('date', datetime.now().strftime('%Y-%m-%d'))
        run_id = str(uuid.uuid4())[:8]
        
        print(f"Validating data for: {date_str}")
        print(f"Run ID: {run_id}")
        print("")
        
        # Run validations
        checkers = []
        
        products_checker = validate_products(DATA_LAKE_BUCKET, date_str)
        if products_checker:
            checkers.append(products_checker)
            save_results_to_dynamodb(products_checker, run_id)
        
        customers_checker = validate_customers(DATA_LAKE_BUCKET, date_str)
        if customers_checker:
            checkers.append(customers_checker)
            save_results_to_dynamodb(customers_checker, run_id)
        
        orders_checker = validate_orders(DATA_LAKE_BUCKET, date_str)
        if orders_checker:
            checkers.append(orders_checker)
            save_results_to_dynamodb(orders_checker, run_id)
        
        # Get summaries
        summaries = [c.get_summary() for c in checkers]
        
        # Send alert if any failed
        send_alert_if_failed(summaries)
        
        # Print summary
        print("")
        print("=" * 60)
        print("DATA QUALITY SUMMARY")
        print("=" * 60)
        for summary in summaries:
            status = "✓" if summary['all_passed'] else "❌"
            print(f"{status} {summary['table_name']}: {summary['checks_passed']}/{summary['total_checks']} passed ({summary['success_rate']}%)")
        print("=" * 60)
        
        all_passed = all(s['all_passed'] for s in summaries)
        
        if all_passed:
            print("✓ All data quality checks passed!")
        else:
            print("⚠️ Some data quality checks failed")
        
        return {
            'statusCode': 200 if all_passed else 422,
            'body': json.dumps({
                'run_id': run_id,
                'date': date_str,
                'all_passed': all_passed,
                'summaries': summaries
            }, default=str)
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