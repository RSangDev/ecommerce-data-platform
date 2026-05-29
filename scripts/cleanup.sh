#!/bin/bash

################################################################################
# E-Commerce Data Platform - Cleanup Script
# Deletes all AWS resources created by the deployment
#
# CAUTION: This will permanently delete all data!
# Usage: ./scripts/cleanup.sh
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
PROJECT_NAME="ecommerce-data-platform"
AWS_REGION="us-east-1"
STACK_NAME="${PROJECT_NAME}-stack"

# Functions
print_header() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║ $1${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

# Get AWS Account ID
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region ${AWS_REGION} 2>/dev/null) || print_error "Failed to get Account ID"
}

# Confirm deletion
confirm_deletion() {
    print_warning "THIS WILL PERMANENTLY DELETE ALL RESOURCES!"
    print_warning ""
    print_warning "This includes:"
    print_warning "  - CloudFormation stack"
    print_warning "  - S3 data lake and ALL data"
    print_warning "  - DynamoDB tables"
    print_warning "  - Lambda functions"
    print_warning "  - EMR Serverless application"
    print_warning "  - CloudWatch logs"
    print_warning ""
    
    read -p "Type 'DELETE' (uppercase) to confirm: " confirmation
    
    if [ "$confirmation" != "DELETE" ]; then
        print_info "Cleanup cancelled"
        exit 0
    fi
}

# Delete S3 buckets
delete_s3_buckets() {
    print_header "Deleting S3 Buckets"
    
    # Data lake bucket
    local data_bucket="${PROJECT_NAME}-datalake-${AWS_ACCOUNT_ID}"
    if aws s3 ls "s3://${data_bucket}" --region ${AWS_REGION} 2>/dev/null; then
        print_info "Emptying ${data_bucket}..."
        aws s3 rm "s3://${data_bucket}" --recursive --region ${AWS_REGION}
        print_success "Emptied ${data_bucket}"
    fi
    
    # Lambda bucket
    local lambda_bucket="${PROJECT_NAME}-lambda-${AWS_ACCOUNT_ID}"
    if aws s3 ls "s3://${lambda_bucket}" --region ${AWS_REGION} 2>/dev/null; then
        print_info "Emptying ${lambda_bucket}..."
        aws s3 rm "s3://${lambda_bucket}" --recursive --region ${AWS_REGION}
        print_success "Emptied ${lambda_bucket}"
    fi
}

# Delete CloudFormation stack
delete_stack() {
    print_header "Deleting CloudFormation Stack"
    
    if aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} 2>/dev/null; then
        print_info "Deleting stack: ${STACK_NAME}"
        aws cloudformation delete-stack --stack-name ${STACK_NAME} --region ${AWS_REGION}
        
        print_info "Waiting for stack deletion..."
        aws cloudformation wait stack-delete-complete --stack-name ${STACK_NAME} --region ${AWS_REGION}
        
        print_success "Stack deleted"
    else
        print_warning "Stack not found: ${STACK_NAME}"
    fi
}

# Delete CloudWatch logs
delete_logs() {
    print_header "Deleting CloudWatch Log Groups"
    
    local log_groups=$(aws logs describe-log-groups \
        --log-group-name-prefix "/aws/lambda/${PROJECT_NAME}" \
        --query 'logGroups[*].logGroupName' \
        --output text \
        --region ${AWS_REGION} 2>/dev/null || echo "")
    
    if [ ! -z "$log_groups" ]; then
        for log_group in $log_groups; do
            print_info "Deleting log group: $log_group"
            aws logs delete-log-group --log-group-name "$log_group" --region ${AWS_REGION}
        done
        print_success "Deleted log groups"
    else
        print_warning "No log groups found"
    fi
}

# Summary
print_summary() {
    print_header "Cleanup Complete"
    
    echo ""
    echo -e "${GREEN}All resources have been deleted.${NC}"
    echo ""
    echo "To verify deletion, check:"
    echo "  - S3 buckets: aws s3 ls"
    echo "  - CloudFormation: aws cloudformation describe-stacks --region ${AWS_REGION}"
    echo "  - Lambda: aws lambda list-functions --region ${AWS_REGION}"
    echo ""
}

# Main
main() {
    print_header "E-Commerce Data Platform - Cleanup"
    
    get_account_id
    confirm_deletion
    delete_s3_buckets
    delete_stack
    delete_logs
    print_summary
}

main "$@"
EOFCLEANUP
chmod +x /mnt/user-data/outputs/ecommerce-data-platform/scripts/cleanup.sh
print_success "✅ Scripts criados com sucesso!"