# E-Commerce Data Platform - Deploy Script (PowerShell)
# Usage: .\scripts\deploy.ps1

$ErrorActionPreference = "Stop"

# Configuration
$ProjectName = "ecommerce-data-platform"
$AWSRegion = "us-east-1"
$StackName = "$ProjectName-stack"
$CFTemplate = "cloudformation\template.yaml"

# $PSScriptRoot is the folder where this script lives - more reliable than $MyInvocation
$ScriptDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ScriptDir

# ============================================================================
# HELPER FUNCTIONS - must be defined before use in PowerShell
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

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

# ============================================================================
# STEP FUNCTIONS
# ============================================================================

function Check-Prerequisites {
    Write-Header "Step 1 - Checking Prerequisites"

    Write-Info "Script dir : $ScriptDir"
    Write-Info "Project dir: $ProjectDir"

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Fail "AWS CLI not found. Install it from https://aws.amazon.com/cli/"
    }
    Write-Success "AWS CLI found"

    $TemplatePath = Join-Path $ProjectDir $CFTemplate
    if (-not (Test-Path $TemplatePath)) {
        Write-Fail "CloudFormation template not found at: $TemplatePath"
    }
    Write-Success "CloudFormation template found"

    $RequiredFiles = @(
        "lambda\data-generator\index.py",
        "lambda\data-quality\index.py",
        "spark\jobs\bronze_to_silver.py",
        "spark\jobs\silver_to_gold.py"
    )

    foreach ($f in $RequiredFiles) {
        $FullPath = Join-Path $ProjectDir $f
        if (-not (Test-Path $FullPath)) {
            Write-Fail "Required file missing: $FullPath"
        }
        Write-Success "Found: $f"
    }
}

function Get-AccountId {
    Write-Header "Step 2 - Getting AWS Account ID"

    $script:AWSAccountId = aws sts get-caller-identity --query Account --output text --region $AWSRegion
    if (-not $AWSAccountId) {
        Write-Fail "Could not get AWS Account ID. Check your credentials."
    }
    Write-Success "Account ID: $AWSAccountId"
}

function Validate-Template {
    Write-Header "Step 3 - Validating CloudFormation Template"

    $TemplatePath = Join-Path $ProjectDir $CFTemplate

    $Result = aws cloudformation validate-template `
        --template-body "file://$TemplatePath" `
        --region $AWSRegion 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Template validation failed: $Result"
    }

    Write-Success "Template is valid"
}

function Package-Lambda {
    param([string]$FunctionName, [string]$SourceDir)

    Write-Info "Packaging: $FunctionName"

    $IndexFile = Join-Path $SourceDir "index.py"
    if (-not (Test-Path $IndexFile)) {
        Write-Fail "index.py not found at: $IndexFile"
    }

    $PackageDir = Join-Path $SourceDir "package"
    $ZipPath    = Join-Path $SourceDir "$FunctionName.zip"

    if (Test-Path $PackageDir) { Remove-Item -Recurse -Force $PackageDir }
    if (Test-Path $ZipPath)    { Remove-Item -Force $ZipPath }

    New-Item -ItemType Directory -Path $PackageDir | Out-Null
    Copy-Item -Path $IndexFile -Destination $PackageDir

    $Prev = Get-Location
    Set-Location $PackageDir
    Compress-Archive -Path * -DestinationPath $ZipPath -Force
    Set-Location $Prev

    Remove-Item -Recurse -Force $PackageDir

    Write-Success "Packaged: $FunctionName.zip"
}

function Upload-LambdaZips {
    Write-Header "Step 4 - Packaging and Uploading Lambda Functions"

    $LambdaBucket = "$ProjectName-lambda-$AWSAccountId"
    Write-Info "Lambda bucket: $LambdaBucket"

    $BucketExists = $false
    try {
        aws s3 ls "s3://$LambdaBucket" --region $AWSRegion | Out-Null
        $BucketExists = $true
    }
    catch {
        $BucketExists = $false
    }

    if (-not $BucketExists) {
        Write-Info "Creating bucket $LambdaBucket ..."
        aws s3 mb "s3://$LambdaBucket" --region $AWSRegion
    }

    Package-Lambda "data-generator" (Join-Path $ProjectDir "lambda\data-generator")
    Package-Lambda "data-quality"   (Join-Path $ProjectDir "lambda\data-quality")

    aws s3 cp (Join-Path $ProjectDir "lambda\data-generator\data-generator.zip") `
        "s3://$LambdaBucket/data-generator.zip" --region $AWSRegion
    Write-Success "Uploaded data-generator.zip"

    aws s3 cp (Join-Path $ProjectDir "lambda\data-quality\data-quality.zip") `
        "s3://$LambdaBucket/data-quality.zip" --region $AWSRegion
    Write-Success "Uploaded data-quality.zip"

    $LambdaBucket | Out-File -FilePath "$env:TEMP\ecommerce_lambda_bucket.txt" -Force
}

function Deploy-Stack {
    Write-Header "Step 5 - Deploying CloudFormation Stack"

    Write-Info "Stack : $StackName"
    Write-Info "Region: $AWSRegion"

    $TemplatePath = Join-Path $ProjectDir $CFTemplate

    $StackExists = $false
    try {
        aws cloudformation describe-stacks `
            --stack-name $StackName `
            --region $AWSRegion `
            --output table | Out-Null
        $StackExists = $true
    }
    catch {
        $StackExists = $false
    }

    if ($StackExists) {
        Write-Warn "Stack already exists - updating..."
        aws cloudformation update-stack `
            --stack-name $StackName `
            --template-body "file://$TemplatePath" `
            --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $AWSRegion
        $Waiter = "stack-update-complete"
    }
    else {
        Write-Info "Creating new stack..."
        aws cloudformation create-stack `
            --stack-name $StackName `
            --template-body "file://$TemplatePath" `
            --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $AWSRegion
        $Waiter = "stack-create-complete"
    }

    Write-Info "Waiting for stack to be ready (this can take 5-10 minutes)..."
    aws cloudformation wait $Waiter --stack-name $StackName --region $AWSRegion
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Stack deployment failed. Check CloudFormation events in the AWS Console."
    }
    Write-Success "Stack deployed successfully"
}

function Get-StackOutputs {
    Write-Header "Stack Outputs"
    aws cloudformation describe-stacks `
        --stack-name $StackName `
        --query "Stacks[0].Outputs" `
        --region $AWSRegion `
        --output table
}

function Upload-SparkJobs {
    Write-Header "Step 6 - Uploading Spark Jobs"

    $DataBucket = "$ProjectName-datalake-$AWSAccountId"
    Write-Info "Waiting for data lake bucket: $DataBucket"

    $Retries = 0
    $BucketReady = $false
    while ($Retries -lt 20 -and -not $BucketReady) {
        try {
            aws s3 ls "s3://$DataBucket" --region $AWSRegion | Out-Null
            $BucketReady = $true
            Write-Success "Bucket is ready"
        }
        catch {
            $Retries++
            if ($Retries -lt 20) {
                Start-Sleep -Seconds 5
            }
        }
    }

    if (-not $BucketReady) {
        Write-Warn "Data lake bucket not found - skipping Spark upload"
        return
    }

    aws s3 cp (Join-Path $ProjectDir "spark\jobs\bronze_to_silver.py") `
        "s3://$DataBucket/spark/jobs/" --region $AWSRegion
    Write-Success "Uploaded bronze_to_silver.py"

    aws s3 cp (Join-Path $ProjectDir "spark\jobs\silver_to_gold.py") `
        "s3://$DataBucket/spark/jobs/" --region $AWSRegion
    Write-Success "Uploaded silver_to_gold.py"
}

function Update-LambdaFunctions {
    Write-Header "Step 7 - Updating Lambda Function Code"

    $LambdaBucket = Get-Content "$env:TEMP\ecommerce_lambda_bucket.txt" -ErrorAction SilentlyContinue
    if (-not $LambdaBucket) {
        Write-Warn "Lambda bucket name not found - skipping Lambda update"
        return
    }

    $Functions = @("data-generator", "data-quality")
    foreach ($Fn in $Functions) {
        $FnName = "$ProjectName-$Fn"
        $FunctionExists = $false
        
        try {
            aws lambda get-function --function-name $FnName --region $AWSRegion | Out-Null
            $FunctionExists = $true
        }
        catch {
            $FunctionExists = $false
        }
        
        if ($FunctionExists) {
            Write-Info "Updating $FnName ..."
            aws lambda update-function-code `
                --function-name $FnName `
                --s3-bucket $LambdaBucket `
                --s3-key "$Fn.zip" `
                --region $AWSRegion | Out-Null
            Write-Success "Updated $FnName"
        }
        else {
            Write-Warn "$FnName not found yet - skipping"
        }
    }
}

function Print-Instructions {
    Write-Header "Deployment Complete!"

    Write-Host "NEXT STEPS:" -ForegroundColor Green
    Write-Host ""
    Write-Host "1. Confirm SNS email subscription"
    Write-Host "   AWS Console - SNS - Topics - confirm email"
    Write-Host ""
    Write-Host "2. Generate initial data"
    Write-Host "   Copy and paste this command:"
    Write-Host ""
    Write-Host "   `$payload = '{\"config\":{\"products\":50,\"customers\":100,\"orders\":200,\"events\":500}}'"
    Write-Host "   aws lambda invoke --function-name $ProjectName-data-generator --payload `$payload --region $AWSRegion response.json"
    Write-Host ""
    Write-Host "3. Run the ETL pipeline"
    Write-Host "   AWS Console - Step Functions - $ProjectName-daily-etl - Start Execution"
    Write-Host ""
    Write-Host "4. Browse the data lake"
    Write-Host "   aws s3 ls s3://$ProjectName-datalake-$AWSAccountId/ --recursive"
    Write-Host ""
    Write-Host "5. Query with Athena"
    Write-Host "   AWS Console - Athena - Database: $($ProjectName)_db"
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

function Main {
    Write-Header "E-Commerce Data Platform - Deploy"

    Write-Info "Project : $ProjectName"
    Write-Info "Region  : $AWSRegion"
    Write-Info "Stack   : $StackName"

    Check-Prerequisites
    Get-AccountId
    Validate-Template
    Upload-LambdaZips
    Deploy-Stack
    Update-LambdaFunctions
    Upload-SparkJobs
    Get-StackOutputs
    Print-Instructions

    Write-Success "Done! Data platform deployed successfully."
}

Main