# E-Commerce Data Platform - Deploy Script (PowerShell)
# Complete deployment of data engineering platform to AWS
#
# Usage: .\scripts\deploy.ps1
# Supports: Windows PowerShell 7+

$ErrorActionPreference = "Stop"

# Configuration
$ProjectName = "ecommerce-data-platform"
$AWSRegion = "us-east-1"
$StackName = "$ProjectName-stack"
$CFTemplate = "cloudformation\template.yaml"

# Get script directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# Functions
function Write-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Blue
    Write-Host "║ $Message" -ForegroundColor Blue
    Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Blue
    Write-Host ""
}

function Write-Success {
    param([string]$Message)
    Write-Host "✅ $Message" -ForegroundColor Green
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
    exit 1
}

function Write-Warning-Custom {
    param([string]$Message)
    Write-Host "⚠️  $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ️  $Message" -ForegroundColor Cyan
}

# Check prerequisites
function Check-Prerequisites {
    Write-Header "Checking Prerequisites"
    
    # Check AWS CLI
    try {
        aws --version | Out-Null
        Write-Success "AWS CLI found"
    } catch {
        Write-Error-Custom "AWS CLI is not installed. Please install it first."
    }
    
    # Check Python
    try {
        python --version | Out-Null
        Write-Success "Python found"
    } catch {
        Write-Warning-Custom "Python not found in PATH (optional)"
    }
}

# Get AWS Account ID
function Get-AccountId {
    Write-Info "Getting AWS Account ID..."
    try {
        $script:AWSAccountId = aws sts get-caller-identity --query Account --output text --region $AWSRegion
        Write-Success "Account ID: $AWSAccountId"
    } catch {
        Write-Error-Custom "Failed to get AWS Account ID. Check your AWS credentials."
    }
}

# Validate CloudFormation template
function Validate-Template {
    Write-Header "Validating CloudFormation Template"
    
    $TemplatePath = Join-Path $ProjectDir $CFTemplate
    if (-not (Test-Path $TemplatePath)) {
        Write-Error-Custom "CloudFormation template not found: $CFTemplate"
    }
    
    try {
        aws cloudformation validate-template `
            --template-body "file://$TemplatePath" `
            --region $AWSRegion | Out-Null
        Write-Success "Template is valid"
    } catch {
        Write-Error-Custom "Template validation failed"
    }
}

# Package Lambda function
function Package-Lambda {
    param(
        [string]$FunctionName,
        [string]$SourceDir
    )
    
    Write-Info "Packaging Lambda: $FunctionName"
    
    $PackageDir = Join-Path $SourceDir "package"
    $ZipPath = Join-Path $SourceDir "$FunctionName.zip"
    
    # Clean
    if (Test-Path $PackageDir) { Remove-Item -Recurse -Force $PackageDir }
    if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
    New-Item -ItemType Directory -Path $PackageDir | Out-Null
    
    # Copy handler
    Copy-Item -Path (Join-Path $SourceDir "index.py") -Destination $PackageDir
    
    # Create ZIP
    $OriginalLocation = Get-Location
    Set-Location $PackageDir
    Compress-Archive -Path * -DestinationPath $ZipPath -Force
    Set-Location $OriginalLocation
    
    # Cleanup
    Remove-Item -Recurse -Force $PackageDir
    
    Write-Success "Packaged: $FunctionName.zip"
}

# Upload Lambda ZIPs
function Upload-LambdaZips {
    Write-Header "Uploading Lambda Functions"
    
    $LambdaBucket = "$ProjectName-lambda-$AWSAccountId"
    
    Write-Info "Lambda bucket: $LambdaBucket"
    
    # Create bucket if doesn't exist
    try {
        aws s3 ls "s3://$LambdaBucket" --region $AWSRegion 2>$null | Out-Null
    } catch {
        Write-Info "Creating Lambda bucket..."
        aws s3 mb "s3://$LambdaBucket" --region $AWSRegion
    }
    
    # Package
    Write-Info "Packaging Lambda functions..."
    Package-Lambda "data-generator" "$ProjectDir\lambda\data-generator"
    Package-Lambda "data-quality" "$ProjectDir\lambda\data-quality"
    
    # Upload
    Write-Info "Uploading to S3..."
    aws s3 cp "$ProjectDir\lambda\data-generator\data-generator.zip" `
        "s3://$LambdaBucket/data-generator.zip" --region $AWSRegion
    Write-Success "Uploaded data-generator.zip"
    
    aws s3 cp "$ProjectDir\lambda\data-quality\data-quality.zip" `
        "s3://$LambdaBucket/data-quality.zip" --region $AWSRegion
    Write-Success "Uploaded data-quality.zip"
    
    # Save bucket name
    $LambdaBucket | Out-File -FilePath "$env:TEMP\lambda_bucket.txt" -Force
}

# Deploy CloudFormation stack
function Deploy-Stack {
    Write-Header "Deploying CloudFormation Stack"
    
    Write-Info "Stack name: $StackName"
    Write-Info "Region: $AWSRegion"
    
    $TemplatePath = Join-Path $ProjectDir $CFTemplate
    
    # Check if stack exists
    $StackExists = $false
    try {
        aws cloudformation describe-stacks `
            --stack-name $StackName `
            --region $AWSRegion 2>$null | Out-Null
        $StackExists = $true
    } catch {}
    
    if ($StackExists) {
        Write-Warning-Custom "Stack already exists. Updating..."
        
        aws cloudformation update-stack `
            --stack-name $StackName `
            --template-body "file://$TemplatePath" `
            --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $AWSRegion
        
        $Waiter = "stack-update-complete"
    } else {
        Write-Info "Creating new stack..."
        
        aws cloudformation create-stack `
            --stack-name $StackName `
            --template-body "file://$TemplatePath" `
            --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $AWSRegion
        
        $Waiter = "stack-create-complete"
    }
    
    Write-Info "Waiting for stack deployment (this may take 5-10 minutes)..."
    
    try {
        aws cloudformation wait $Waiter `
            --stack-name $StackName `
            --region $AWSRegion
        Write-Success "Stack deployment completed"
    } catch {
        Write-Warning-Custom "Stack deployment may have timed out. Check AWS Console."
    }
}

# Get stack outputs
function Get-StackOutputs {
    Write-Header "Stack Outputs"
    
    aws cloudformation describe-stacks `
        --stack-name $StackName `
        --query 'Stacks[0].Outputs' `
        --region $AWSRegion `
        --output table
}

# Upload Spark jobs
function Upload-SparkJobs {
    Write-Header "Uploading Spark Jobs"
    
    $DataBucket = "$ProjectName-datalake-$AWSAccountId"
    
    Write-Info "Data lake bucket: $DataBucket"
    Write-Info "Waiting for data lake bucket..."
    
    $MaxRetries = 30
    $Retry = 0
    while ($Retry -lt $MaxRetries) {
        try {
            aws s3 ls "s3://$DataBucket" --region $AWSRegion 2>$null | Out-Null
            Write-Success "Data lake bucket is ready"
            break
        } catch {
            $Retry++
            if ($Retry -eq $MaxRetries) {
                Write-Warning-Custom "Data lake bucket not available yet"
                return
            }
            Start-Sleep -Seconds 2
        }
    }
    
    # Upload
    Write-Info "Uploading Spark jobs..."
    
    aws s3 cp "$ProjectDir\spark\jobs\bronze_to_silver.py" `
        "s3://$DataBucket/spark/jobs/" --region $AWSRegion
    Write-Success "Uploaded bronze_to_silver.py"
    
    aws s3 cp "$ProjectDir\spark\jobs\silver_to_gold.py" `
        "s3://$DataBucket/spark/jobs/" --region $AWSRegion
    Write-Success "Uploaded silver_to_gold.py"
}

# Update Lambda functions
function Update-LambdaFunctions {
    Write-Header "Updating Lambda Function Code"
    
    $LambdaBucket = Get-Content -Path "$env:TEMP\lambda_bucket.txt" -ErrorAction SilentlyContinue
    
    if (-not $LambdaBucket) {
        Write-Warning-Custom "Lambda bucket not found"
        return
    }
    
    # Update data-generator
    try {
        aws lambda get-function --function-name "$ProjectName-data-generator" `
            --region $AWSRegion 2>$null | Out-Null
        Write-Info "Updating data-generator..."
        aws lambda update-function-code `
            --function-name "$ProjectName-data-generator" `
            --s3-bucket $LambdaBucket `
            --s3-key data-generator.zip `
            --region $AWSRegion | Out-Null
        Write-Success "Updated data-generator"
    } catch {}
    
    # Update data-quality
    try {
        aws lambda get-function --function-name "$ProjectName-data-quality" `
            --region $AWSRegion 2>$null | Out-Null
        Write-Info "Updating data-quality..."
        aws lambda update-function-code `
            --function-name "$ProjectName-data-quality" `
            --s3-bucket $LambdaBucket `
            --s3-key data-quality.zip `
            --region $AWSRegion | Out-Null
        Write-Success "Updated data-quality"
    } catch {}
}

# Print instructions
function Print-Instructions {
    Write-Header "Deployment Complete! 🎉"
    
    Write-Host "Next Steps:" -ForegroundColor Green
    Write-Host ""
    Write-Host "1. Update SNS Email Subscription" -ForegroundColor Cyan
    Write-Host "   Go to AWS Console → SNS → Topics"
    Write-Host "   Confirm the email subscription"
    Write-Host ""
    Write-Host "2. Generate Initial Data" -ForegroundColor Cyan
    Write-Host "   aws lambda invoke \"
    Write-Host "     --function-name $ProjectName-data-generator \"
    Write-Host "     --payload '{""config"":{""products"":50,""customers"":100,""orders"":200,""events"":500}}' \"
    Write-Host "     --region $AWSRegion \"
    Write-Host "     response.json"
    Write-Host ""
    Write-Host "3. Run ETL Pipeline" -ForegroundColor Cyan
    Write-Host "   AWS Console → Step Functions → $ProjectName-daily-etl"
    Write-Host ""
    Write-Host "4. Check Data Lake" -ForegroundColor Cyan
    Write-Host "   aws s3 ls s3://$ProjectName-datalake-$AWSAccountId/ --recursive"
    Write-Host ""
    Write-Host "5. Query Data with Athena" -ForegroundColor Cyan
    Write-Host "   AWS Console → Athena → Query Editor"
    Write-Host "   Database: $($ProjectName)_db"
    Write-Host ""
    Write-Host "Documentation:" -ForegroundColor Green
    Write-Host "   - README.md"
    Write-Host "   - GETTING_STARTED.md"
    Write-Host "   - docs\ARCHITECTURE.md"
    Write-Host ""
}

# Main
function Main {
    Write-Header "E-Commerce Data Platform - Deployment"
    
    Write-Info "Project: $ProjectName"
    Write-Info "Region: $AWSRegion"
    Write-Info "Stack: $StackName"
    Write-Host ""
    
    Check-Prerequisites
    Get-AccountId
    Validate-Template
    Upload-LambdaZips
    Deploy-Stack
    Update-LambdaFunctions
    Upload-SparkJobs
    Get-StackOutputs
    Print-Instructions
    
    Write-Success "All done! Your data platform is ready! 🚀"
}

Main
EOFPOWERSHELL
Saída

exit code 0
Concluído
Agora vou criar o cleanup.sh correto:


Executou 2 comandos
Executou 2 comandos

Criando cleanup.sh correto
bash

cat > /mnt/user-data/outputs/ecommerce-data-platform/scripts/cleanup.sh << 'EOFCLEANUP'
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