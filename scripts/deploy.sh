#!/bin/bash

################################################################################
# E-Commerce Data Platform - Deploy Script (Bash)
# Complete deployment of data engineering platform to AWS
#
# Usage: ./scripts/deploy.sh
# Supports: Linux, macOS, WSL (Windows Subsystem for Linux)
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
CF_TEMPLATE="cloudformation/template.yaml"

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

# Output functions
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
    exit 1
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
    fi
    print_success "AWS CLI found"
    
    # Check Python
    if ! command -v python3 &> /dev/null; then
        print_error "Python 3 is not installed"
    fi
    print_success "Python 3 found"
    
    # Check zip
    if ! command -v zip &> /dev/null; then
        print_error "zip command not found"
    fi
    print_success "zip found"
}

# Get AWS Account ID
get_account_id() {
    print_info "Getting AWS Account ID..."
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region ${AWS_REGION} 2>/dev/null) || print_error "Failed to get AWS Account ID. Check your AWS credentials."
    print_success "Account ID: ${AWS_ACCOUNT_ID}"
}

# Validate CloudFormation template
validate_template() {
    print_header "Validating CloudFormation Template"
    
    if [ ! -f "${PROJECT_DIR}/${CF_TEMPLATE}" ]; then
        print_error "CloudFormation template not found: ${CF_TEMPLATE}"
    fi
    
    aws cloudformation validate-template \
        --template-body "file://${PROJECT_DIR}/${CF_TEMPLATE}" \
        --region ${AWS_REGION} > /dev/null 2>&1 || print_error "Template validation failed"
    
    print_success "Template is valid"
}

# Package Lambda function
package_lambda() {
    local func_name=$1
    local source_dir=$2
    
    print_info "Packaging Lambda: ${func_name}"
    
    local package_dir="${source_dir}/package"
    
    # Clean
    rm -rf "${package_dir}" "${source_dir}/${func_name}.zip" 2>/dev/null || true
    mkdir -p "${package_dir}"
    
    # Copy handler
    cp "${source_dir}/index.py" "${package_dir}/"
    
    # Create ZIP
    cd "${package_dir}"
    zip -r "../${func_name}.zip" . -q
    cd - > /dev/null
    
    # Cleanup
    rm -rf "${package_dir}"
    
    print_success "Packaged: ${func_name}.zip"
}

# Upload Lambda ZIPs to S3
upload_lambda_zips() {
    print_header "Uploading Lambda Functions"
    
    local lambda_bucket="${PROJECT_NAME}-lambda-${AWS_ACCOUNT_ID}"
    
    print_info "Lambda bucket: ${lambda_bucket}"
    
    # Create bucket if doesn't exist
    if ! aws s3 ls "s3://${lambda_bucket}" --region ${AWS_REGION} 2>/dev/null; then
        print_info "Creating Lambda bucket..."
        aws s3 mb "s3://${lambda_bucket}" --region ${AWS_REGION}
    fi
    
    # Package Lambda functions
    print_info "Packaging Lambda functions..."
    package_lambda "data-generator" "${PROJECT_DIR}/lambda/data-generator"
    package_lambda "data-quality" "${PROJECT_DIR}/lambda/data-quality"
    
    # Upload to S3
    print_info "Uploading to S3..."
    aws s3 cp "${PROJECT_DIR}/lambda/data-generator/data-generator.zip" \
        "s3://${lambda_bucket}/data-generator.zip" --region ${AWS_REGION}
    print_success "Uploaded data-generator.zip"
    
    aws s3 cp "${PROJECT_DIR}/lambda/data-quality/data-quality.zip" \
        "s3://${lambda_bucket}/data-quality.zip" --region ${AWS_REGION}
    print_success "Uploaded data-quality.zip"
    
    # Save bucket name
    echo "${lambda_bucket}" > /tmp/lambda_bucket.txt
}

# Deploy CloudFormation stack
deploy_stack() {
    print_header "Deploying CloudFormation Stack"
    
    print_info "Stack name: ${STACK_NAME}"
    print_info "Region: ${AWS_REGION}"
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name ${STACK_NAME} --region ${AWS_REGION} 2>/dev/null; then
        print_warning "Stack already exists. Updating..."
        
        aws cloudformation update-stack \
            --stack-name ${STACK_NAME} \
            --template-body "file://${PROJECT_DIR}/${CF_TEMPLATE}" \
            --parameters ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME} \
            --capabilities CAPABILITY_NAMED_IAM \
            --region ${AWS_REGION}
        
        WAITER="stack-update-complete"
    else
        print_info "Creating new stack..."
        
        aws cloudformation create-stack \
            --stack-name ${STACK_NAME} \
            --template-body "file://${PROJECT_DIR}/${CF_TEMPLATE}" \
            --parameters ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME} \
            --capabilities CAPABILITY_NAMED_IAM \
            --region ${AWS_REGION}
        
        WAITER="stack-create-complete"
    fi
    
    print_info "Waiting for stack deployment (this may take 5-10 minutes)..."
    
    if aws cloudformation wait ${WAITER} \
        --stack-name ${STACK_NAME} \
        --region ${AWS_REGION} 2>/dev/null; then
        print_success "Stack deployment completed"
    else
        print_warning "Stack deployment timed out or failed. Check AWS Console for details."
    fi
}

# Get stack outputs
get_stack_outputs() {
    print_header "Stack Outputs"
    
    aws cloudformation describe-stacks \
        --stack-name ${STACK_NAME} \
        --query 'Stacks[0].Outputs' \
        --region ${AWS_REGION} \
        --output table
}

# Upload Spark jobs to S3
upload_spark_jobs() {
    print_header "Uploading Spark Jobs"
    
    local data_bucket="${PROJECT_NAME}-datalake-${AWS_ACCOUNT_ID}"
    
    print_info "Data lake bucket: ${data_bucket}"
    
    # Wait for bucket to exist
    print_info "Waiting for data lake bucket..."
    for i in {1..30}; do
        if aws s3 ls "s3://${data_bucket}" --region ${AWS_REGION} 2>/dev/null; then
            print_success "Data lake bucket is ready"
            break
        fi
        if [ $i -eq 30 ]; then
            print_warning "Data lake bucket not available yet"
            return
        fi
        sleep 2
    done
    
    # Upload Spark jobs
    print_info "Uploading Spark jobs..."
    
    aws s3 cp "${PROJECT_DIR}/spark/jobs/bronze_to_silver.py" \
        "s3://${data_bucket}/spark/jobs/" --region ${AWS_REGION}
    print_success "Uploaded bronze_to_silver.py"
    
    aws s3 cp "${PROJECT_DIR}/spark/jobs/silver_to_gold.py" \
        "s3://${data_bucket}/spark/jobs/" --region ${AWS_REGION}
    print_success "Uploaded silver_to_gold.py"
}

# Update Lambda function code
update_lambda_functions() {
    print_header "Updating Lambda Function Code"
    
    local lambda_bucket=$(cat /tmp/lambda_bucket.txt 2>/dev/null || echo "")
    
    if [ -z "${lambda_bucket}" ]; then
        print_warning "Lambda bucket not found"
        return
    fi
    
    # Update data-generator
    if aws lambda get-function --function-name ${PROJECT_NAME}-data-generator --region ${AWS_REGION} 2>/dev/null; then
        print_info "Updating data-generator function..."
        aws lambda update-function-code \
            --function-name ${PROJECT_NAME}-data-generator \
            --s3-bucket ${lambda_bucket} \
            --s3-key data-generator.zip \
            --region ${AWS_REGION} > /dev/null
        print_success "Updated data-generator"
    fi
    
    # Update data-quality
    if aws lambda get-function --function-name ${PROJECT_NAME}-data-quality --region ${AWS_REGION} 2>/dev/null; then
        print_info "Updating data-quality function..."
        aws lambda update-function-code \
            --function-name ${PROJECT_NAME}-data-quality \
            --s3-bucket ${lambda_bucket} \
            --s3-key data-quality.zip \
            --region ${AWS_REGION} > /dev/null
        print_success "Updated data-quality"
    fi
}

# Print final instructions
print_instructions() {
    print_header "Deployment Complete! 🎉"
    
    echo -e "${GREEN}Next Steps:${NC}"
    echo ""
    echo "1. ${CYAN}Update SNS Email Subscription${NC}"
    echo "   Go to AWS Console → SNS → Topics"
    echo "   Confirm the email subscription for alerts"
    echo ""
    echo "2. ${CYAN}Generate Initial Data${NC}"
    echo "   aws lambda invoke \\"
    echo "     --function-name ${PROJECT_NAME}-data-generator \\"
    echo "     --payload '{\"config\":{\"products\":50,\"customers\":100,\"orders\":200,\"events\":500}}' \\"
    echo "     --region ${AWS_REGION} \\"
    echo "     response.json"
    echo ""
    echo "3. ${CYAN}Run ETL Pipeline${NC}"
    echo "   AWS Console → Step Functions → ${PROJECT_NAME}-daily-etl"
    echo "   Click 'Start Execution'"
    echo ""
    echo "4. ${CYAN}Check Data Lake${NC}"
    echo "   aws s3 ls s3://${PROJECT_NAME}-datalake-${AWS_ACCOUNT_ID}/ --recursive"
    echo ""
    echo "5. ${CYAN}Query Data with Athena${NC}"
    echo "   AWS Console → Athena → Query Editor"
    echo "   Database: ${PROJECT_NAME}_db"
    echo ""
    echo "6. ${CYAN}Create QuickSight Dashboards${NC}"
    echo "   AWS Console → QuickSight"
    echo "   Connect to Athena data source"
    echo ""
    echo -e "${GREEN}Documentation:${NC}"
    echo "   - README.md - Project overview"
    echo "   - GETTING_STARTED.md - Detailed setup guide"
    echo "   - docs/ARCHITECTURE.md - Technical details"
    echo ""
}

# Main execution
main() {
    print_header "E-Commerce Data Platform - Deployment"
    
    print_info "Project: ${PROJECT_NAME}"
    print_info "Region: ${AWS_REGION}"
    print_info "Stack: ${STACK_NAME}"
    echo ""
    
    check_prerequisites
    get_account_id
    validate_template
    upload_lambda_zips
    deploy_stack
    update_lambda_functions
    upload_spark_jobs
    get_stack_outputs
    print_instructions
    
    print_success "All done! Your data platform is ready to use! 🚀"
}

# Run main
main "$@"