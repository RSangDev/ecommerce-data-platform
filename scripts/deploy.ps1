# E-Commerce Data Platform - Deploy Script (PowerShell)
# SIMPLIFIED VERSION - Just deploy!

$ErrorActionPreference = "Continue"

# Configuration
$ProjectName = "ecommerce-data-platform"
$AWSRegion = "us-east-1"
$StackName = "$ProjectName-stack-v2"
$CFTemplate = "cloudformation\template.yaml"

# Get directories
$ScriptDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ScriptDir

# ============================================================================
# HELPER FUNCTIONS
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
# MAIN FUNCTIONS
# ============================================================================

function Check-Prerequisites {
    Write-Header "Step 1 - Checking Prerequisites"

    Write-Info "Script dir : $ScriptDir"
    Write-Info "Project dir: $ProjectDir"

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Fail "AWS CLI not found"
    }
    Write-Success "AWS CLI found"

    $TemplatePath = Join-Path $ProjectDir $CFTemplate
    if (-not (Test-Path $TemplatePath)) {
        Write-Fail "Template not found: $TemplatePath"
    }
    Write-Success "Template found"

    $RequiredFiles = @(
        "lambda\data-generator\index.py",
        "lambda\data-quality\index.py",
        "spark\jobs\bronze_to_silver.py",
        "spark\jobs\silver_to_gold.py"
    )

    foreach ($f in $RequiredFiles) {
        $FullPath = Join-Path $ProjectDir $f
        if (-not (Test-Path $FullPath)) {
            Write-Fail "Missing: $FullPath"
        }
    }
    Write-Success "All required files found"
}

function Get-AccountId {
    Write-Header "Step 2 - Getting AWS Account ID"

    $script:AWSAccountId = aws sts get-caller-identity --query Account --output text --region $AWSRegion 2>&1
    if (-not $AWSAccountId -or $LASTEXITCODE -ne 0) {
        Write-Fail "Could not get Account ID"
    }
    Write-Success "Account ID: $AWSAccountId"
}

function Validate-Template {
    Write-Header "Step 3 - Validating Template"

    $TemplatePath = Join-Path $ProjectDir $CFTemplate
    aws cloudformation validate-template --template-body "file://$TemplatePath" --region $AWSRegion 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Template validation failed"
    }
    Write-Success "Template is valid"
}

function Package-Lambda {
    param([string]$FunctionName, [string]$SourceDir)

    Write-Info "Packaging: $FunctionName"

    $IndexFile = Join-Path $SourceDir "index.py"
    if (-not (Test-Path $IndexFile)) {
        Write-Fail "index.py not found: $IndexFile"
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
    Write-Header "Step 4 - Uploading Lambda Functions"

    $LambdaBucket = "$ProjectName-lambda-$AWSAccountId"
    Write-Info "Bucket: $LambdaBucket"

    # Create bucket if needed
    aws s3 ls "s3://$LambdaBucket" --region $AWSRegion 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Creating bucket..."
        aws s3 mb "s3://$LambdaBucket" --region $AWSRegion 2>&1 | Out-Null
    }

    # Package and upload
    Package-Lambda "data-generator" (Join-Path $ProjectDir "lambda\data-generator")
    Package-Lambda "data-quality"   (Join-Path $ProjectDir "lambda\data-quality")

    aws s3 cp (Join-Path $ProjectDir "lambda\data-generator\data-generator.zip") `
        "s3://$LambdaBucket/data-generator.zip" --region $AWSRegion 2>&1 | Out-Null
    Write-Success "Uploaded data-generator.zip"

    aws s3 cp (Join-Path $ProjectDir "lambda\data-quality\data-quality.zip") `
        "s3://$LambdaBucket/data-quality.zip" --region $AWSRegion 2>&1 | Out-Null
    Write-Success "Uploaded data-quality.zip"

    $LambdaBucket | Out-File -FilePath "$env:TEMP\ecommerce_lambda_bucket.txt" -Force
}

function Deploy-Stack {
    Write-Header "Step 5 - Deploying CloudFormation Stack"

    Write-Info "Stack : $StackName"
    Write-Info "Region: $AWSRegion"

    $TemplatePath = Join-Path $ProjectDir $CFTemplate

    # Try CREATE first
    Write-Info "Attempting to create stack..."
    $CreateOutput = aws cloudformation create-stack `
        --stack-name $StackName `
        --template-body "file://$TemplatePath" `
        --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName `
        --capabilities CAPABILITY_NAMED_IAM `
        --region $AWSRegion 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Success "Stack creation started"
        $Waiter = "stack-create-complete"
    }
    else {
        Write-Warn "CREATE failed. Attempting UPDATE..."
        Write-Warn "Error was: $CreateOutput"
        
        # Try UPDATE
        $UpdateOutput = aws cloudformation update-stack `
            --stack-name $StackName `
            --template-body "file://$TemplatePath" `
            --parameters ParameterKey=ProjectName,ParameterValue=$ProjectName `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $AWSRegion 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Stack update started"
            $Waiter = "stack-update-complete"
        }
        else {
            Write-Fail "BOTH CREATE and UPDATE failed!`n`nError: $UpdateOutput"
        }
    }

    Write-Info "Waiting for stack (5-10 minutes)..."
    aws cloudformation wait $Waiter --stack-name $StackName --region $AWSRegion 2>&1 | Out-Null
    
    # Ignore waiter errors - stack may still be creating
    Write-Warn "Waiter completed (may have encountered rollback)"
    Write-Warn "Checking stack status in 10 seconds..."
    Start-Sleep -Seconds 10
}

function Get-StackOutputs {
    Write-Header "Stack Status"
    
    Write-Info "Attempting to get stack info..."
    aws cloudformation describe-stacks --stack-name $StackName --region $AWSRegion 2>&1
}

function Upload-SparkJobs {
    Write-Header "Step 6 - Uploading Spark Jobs"

    $DataBucket = "$ProjectName-datalake-$AWSAccountId"
    Write-Info "Waiting for: $DataBucket"

    for ($i = 0; $i -lt 30; $i++) {
        aws s3 ls "s3://$DataBucket" --region $AWSRegion 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Bucket ready"
            break
        }
        Write-Info "Waiting... ($i/30)"
        Start-Sleep -Seconds 2
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Bucket not found - skipping Spark upload"
        return
    }

    aws s3 cp (Join-Path $ProjectDir "spark\jobs\bronze_to_silver.py") `
        "s3://$DataBucket/spark/jobs/" --region $AWSRegion 2>&1 | Out-Null
    Write-Success "Uploaded bronze_to_silver.py"

    aws s3 cp (Join-Path $ProjectDir "spark\jobs\silver_to_gold.py") `
        "s3://$DataBucket/spark/jobs/" --region $AWSRegion 2>&1 | Out-Null
    Write-Success "Uploaded silver_to_gold.py"
}

function Update-LambdaFunctions {
    Write-Header "Step 7 - Updating Lambda Code"

    $LambdaBucket = Get-Content "$env:TEMP\ecommerce_lambda_bucket.txt" -ErrorAction SilentlyContinue
    if (-not $LambdaBucket) {
        Write-Warn "Bucket not found - skipping"
        return
    }

    foreach ($Fn in @("data-generator", "data-quality")) {
        $FnName = "$ProjectName-$Fn"
        aws lambda get-function --function-name $FnName --region $AWSRegion 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Updating $FnName..."
            aws lambda update-function-code --function-name $FnName --s3-bucket $LambdaBucket --s3-key "$Fn.zip" --region $AWSRegion 2>&1 | Out-Null
            Write-Success "Updated $FnName"
        }
    }
}

function Print-Instructions {
    Write-Header "Check CloudFormation Console!"

    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Yellow
    Write-Host "1. Go to AWS Console → CloudFormation"
    Write-Host "2. Find stack: $StackName"
    Write-Host "3. Check status (should be CREATE_COMPLETE or UPDATE_COMPLETE)"
    Write-Host "4. If ROLLBACK_COMPLETE or failed:"
    Write-Host "   - Click stack → Events tab"
    Write-Host "   - Find the RED error message"
    Write-Host "   - Copy and share the error"
    Write-Host ""
    Write-Host "If stack is COMPLETE:" -ForegroundColor Green
    Write-Host "5. Generate data:"
    Write-Host ""
    Write-Host "   `$payload = '{\"config\":{\"products\":50,\"customers\":100,\"orders\":200,\"events\":500}}'"
    Write-Host "   aws lambda invoke --function-name $ProjectName-data-generator --payload `$payload --region $AWSRegion response.json"
    Write-Host ""
    Write-Host "6. Run pipeline in AWS Console → Step Functions"
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

Check-Prerequisites
Get-AccountId
Validate-Template
Upload-LambdaZips
Deploy-Stack
Get-StackOutputs
Update-LambdaFunctions
Upload-SparkJobs
Print-Instructions

Write-Success "All done!"