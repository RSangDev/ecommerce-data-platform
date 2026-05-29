# E-Commerce Data Platform - Deploy Script (PowerShell)
# Complete deployment of data engineering platform to AWS

$ErrorActionPreference = "Stop"

# Configuration
$ProjectName = "ecommerce-data-platform"
$AWSRegion = "us-east-1"
$StackName = "$ProjectName-stack"
$CFTemplate = "cloudformation\template.yaml"

# Get directories
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir

# ============================================================================
# FUNCTIONS - Define these FIRST before using them
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Blue
    Write-Host $Message -ForegroundColor Blue
    Write-Host "============================================" -ForegroundColor Blue
    Write-Host ""
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Write-Warning-Custom {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

# ============================================================================
# MAIN FUNCTIONS
# ============================================================================

function Check-Prerequisites {
    Write-Header "Checking Prerequisites"
    
    try {
        aws --version | Out-Null
        Write-Success "AWS CLI found"
    }
    catch {
        Write-Error-Custom "AWS CLI is not installed"
    }
}

function Get-AccountId {
    Write-Header "Getting AWS Account ID"
    
    try {
        $script:AWSAccountId = aws sts get-caller-identity --query Account --output text --region $AWSRegion
        Write-Success "Account ID: $AWSAccountId"
    }
    catch {
        Write-Error-Custom "Failed to get AWS Account ID"
    }
}

function Validate-Template {
    Write-Header "Validating CloudFormation Template"
    
    $TemplatePath = Join-Path $ProjectDir $CFTemplate
    if (-not (Test-Path $TemplatePath)) {
        Write-Error-Custom "Template not found: $CFTemplate"
    }
    
    try {
        aws cloudformation validate-template --template-body "file://$TemplatePath" --region $AWSRegion | Out-Null
        Write-Success "Template is valid"
    }
    catch {
        Write-Error-Custom "Template validation failed"
    }
}

function Package-Lambda {
    param([string]$FunctionName, [string]$SourceDir)
    
    Write-Info "Packaging Lambda: $FunctionName"
    
    $PackageDir = Join-Path $SourceDir "package"
    $ZipPath = Join-Path $SourceDir "$FunctionName.zip"
    
    if (Test-Path $PackageDir) {
        Remove-Item -Recurse -Force $PackageDir
    }
    if (Test-Path $ZipPath) {
        Remove-Item -Force $ZipPath
    }
    
    New-Item -ItemType Directory -Path $PackageDir | Out-Null
    Copy-Item -Path (Join-Path $SourceDir "index.py") -Destination $PackageDir
    
    $OriginalLocation = Get-Location
    Set-Location $PackageDir
    Compress-Archive -Path * -DestinationPath $ZipPath -Force
    Set-Location $OriginalLocation
    
    Remove-Item -Recurse -Force $PackageDir
    
    Write-Success "Packaged: $FunctionName.zip"
}

function Upload-LambdaZips {
    Write-Header "Uploading Lambda Functions"
    
    $LambdaBucket = "$ProjectName-lambda-$AWSAccountId"
    Write-Info "Lambda bucket: $LambdaBucket"
    
    try {
        aws s3 ls "s3://$LambdaBucket" --region $AWSRegion 2>$null | Out-Null
    }
    catch {
        Write-Info "Creating Lambda bucket..."
        aws s3 mb "s3://$LambdaBucket" --region $AWSRegion
    }
    
    Write-Info "Packaging Lambda functions..."
    Package-Lambda "data-generator" "$ProjectDir\lambda\data-generator"
    Package-Lambda "data-quality" "$ProjectDir\lambda\data-quality"
    
    Write-Info "Uploading to S3..."
    aws s3 cp "$ProjectDir\lambda\data-generator\data-generator.zip" "s3://$LambdaBucket/data-generator.zip" --region $AWSRegion
    Write-Success "Uploaded data-generator.zip"
    
    aws s3 cp "$ProjectDir\lambda\data-quality\data-quality.zip" "s3://$LambdaBucket/data-quality.zip" --region $AWSRegion
    Write-Success "Uploaded data-quality.zip"
    
    $LambdaBucket | Out-File -FilePath "$env:TEMP\lambda_bucket.txt" -Force
}

function Deploy-Stack {
    Write-Header "Deploying CloudFormation Stack"
    
    Write-Info "Stack name: $StackName"
    Write-Info "Region: $AWSRegion"
    
    $TemplatePath = Join-Path $ProjectDir $CFTemplate
    
    $StackExists = $false
    try {
        aws cloudformation describe-stacks --stack-name $StackName --region $AWSRegion 2>$null | Out-Null
        $StackExists = $true
    }
    catch {
    }
    
    if ($StackExists) {
        Write-Warning-Custom "Stack already exists. Updating..."
        aws cloudformation update-stack --stack-name $StackName --template-body "file://$TemplatePath" --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName --capabilities CAPABILITY_NAMED_IAM --region $AWSRegion
        $Waiter = "stack-update-complete"
    }
    else {
        Write-Info "Creating new stack..."
        aws cloudformation create-stack --stack-name $StackName --template-body "file://$TemplatePath" --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName --capabilities CAPABILITY_NAMED_IAM --region $AWSRegion
        $Waiter = "stack-create-complete"
    }
    
    Write-Info "Waiting for stack deployment (5-10 minutes)..."
    
    try {
        aws cloudformation wait $Waiter --stack-name $StackName --region $AWSRegion
        Write-Success "Stack deployment completed"
    }
    catch {
        Write-Warning-Custom "Stack deployment timed out. Check AWS Console."
    }
}

function Get-StackOutputs {
    Write-Header "Stack Outputs"
    aws cloudformation describe-stacks --stack-name $StackName --query "Stacks[0].Outputs" --region $AWSRegion --output table
}

function Upload-SparkJobs {
    Write-Header "Uploading Spark Jobs"
    
    $DataBucket = "$ProjectName-datalake-$AWSAccountId"
    Write-Info "Data lake bucket: $DataBucket"
    Write-Info "Waiting for bucket..."
    
    $MaxRetries = 30
    $Retry = 0
    while ($Retry -lt $MaxRetries) {
        try {
            aws s3 ls "s3://$DataBucket" --region $AWSRegion 2>$null | Out-Null
            Write-Success "Data lake bucket is ready"
            break
        }
        catch {
            $Retry++
            if ($Retry -eq $MaxRetries) {
                Write-Warning-Custom "Data lake bucket not available yet"
                return
            }
            Start-Sleep -Seconds 2
        }
    }
    
    Write-Info "Uploading Spark jobs..."
    aws s3 cp "$ProjectDir\spark\jobs\bronze_to_silver.py" "s3://$DataBucket/spark/jobs/" --region $AWSRegion
    Write-Success "Uploaded bronze_to_silver.py"
    
    aws s3 cp "$ProjectDir\spark\jobs\silver_to_gold.py" "s3://$DataBucket/spark/jobs/" --region $AWSRegion
    Write-Success "Uploaded silver_to_gold.py"
}

function Update-LambdaFunctions {
    Write-Header "Updating Lambda Function Code"
    
    $LambdaBucket = Get-Content -Path "$env:TEMP\lambda_bucket.txt" -ErrorAction SilentlyContinue
    
    if (-not $LambdaBucket) {
        Write-Warning-Custom "Lambda bucket not found"
        return
    }
    
    try {
        aws lambda get-function --function-name "$ProjectName-data-generator" --region $AWSRegion 2>$null | Out-Null
        Write-Info "Updating data-generator..."
        aws lambda update-function-code --function-name "$ProjectName-data-generator" --s3-bucket $LambdaBucket --s3-key data-generator.zip --region $AWSRegion | Out-Null
        Write-Success "Updated data-generator"
    }
    catch {
    }
    
    try {
        aws lambda get-function --function-name "$ProjectName-data-quality" --region $AWSRegion 2>$null | Out-Null
        Write-Info "Updating data-quality..."
        aws lambda update-function-code --function-name "$ProjectName-data-quality" --s3-bucket $LambdaBucket --s3-key data-quality.zip --region $AWSRegion | Out-Null
        Write-Success "Updated data-quality"
    }
    catch {
    }
}

function Print-Instructions {
    Write-Header "Deployment Complete!"
    
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Green
    Write-Host ""
    Write-Host "1. Update SNS Email Subscription"
    Write-Host "   Go to AWS Console and confirm email subscription"
    Write-Host ""
    Write-Host "2. Generate Initial Data"
    Write-Host "   aws lambda invoke --function-name $ProjectName-data-generator --payload '{""config"":{""products"":50,""customers"":100,""orders"":200,""events"":500}}' --region $AWSRegion response.json"
    Write-Host ""
    Write-Host "3. Run ETL Pipeline"
    Write-Host "   AWS Console - Step Functions - Start Execution"
    Write-Host ""
    Write-Host "4. Check Data Lake"
    Write-Host "   aws s3 ls s3://$ProjectName-datalake-$AWSAccountId/ --recursive"
    Write-Host ""
    Write-Host "Documentation: README.md, GETTING_STARTED.md, docs/ARCHITECTURE.md"
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

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
    
    Write-Success "All done! Your data platform is ready!"
}

# Execute
Main