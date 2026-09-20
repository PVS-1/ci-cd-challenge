# PowerShell script for Task 2. The .sh extension is kept for the challenge folder.
# Use fresh sandbox credentials in the current PowerShell session. Do not store them here.

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$Region = "eu-west-1"

if ([string]::IsNullOrWhiteSpace($env:AWS_ACCESS_KEY_ID) -or
    [string]::IsNullOrWhiteSpace($env:AWS_SECRET_ACCESS_KEY) -or
    [string]::IsNullOrWhiteSpace($env:AWS_SESSION_TOKEN)) {
    throw "Set fresh AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN in this PowerShell session first."
}

# Existing resources from the challenge and names for resources created by this task.
$BucketName = "<your-bucket-name>"
$TargetLambdaName = "<your-target-lambda-name>"
$TriggerLambdaName = "<your-trigger-lambda-name>"
$TriggerRoleName = "<your-trigger-role-name>"
$CodeBuildRoleName = "<your-codebuild-role-name>
"
$CodeBuildProjectName = "<your-codebuild-project-name>"
$EventNotificationName = "<your-event-notification-name>"

$AccountId = aws sts get-caller-identity --region $Region --query Account --output text
if ($LASTEXITCODE -ne 0) {
    throw "AWS authentication failed. Refresh the sandbox credentials and run this script again."
}

Write-Output "Using account $AccountId and region $Region"
Write-Output "Available S3 buckets:"
aws s3api list-buckets --query "Buckets[].Name" --output table
Write-Output "Available Lambda functions:"
aws lambda list-functions --region $Region --query "Functions[].FunctionName" --output table

# Confirm the existing bucket and target Lambda before changing anything.
aws s3api head-bucket --bucket $BucketName --region $Region
aws lambda get-function --function-name $TargetLambdaName --region $Region --query "Configuration.FunctionName" --output text

$TaskDir = Join-Path $PSScriptRoot "..\ci-cd-challenge\02-Automatic-Lambda-update-CodeBuild-S3"
$TriggerDir = Join-Path $TaskDir "trigger"
$TriggerZip = Join-Path $TaskDir "trigger.zip"
$BuildZip = Join-Path $TaskDir "build.zip"
$PolicyDir = Join-Path $PSScriptRoot "generated-policies"
New-Item -ItemType Directory -Path $PolicyDir -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Objective 2: allow the trigger Lambda to start the CodeBuild project.
$TriggerPolicyPath = Join-Path $PolicyDir "trigger-start-codebuild.json"
$TriggerPolicy = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid = "StartCodeBuildProject"
            Effect = "Allow"
            Action = "codebuild:StartBuild"
            Resource = "arn:aws:codebuild:${Region}:${AccountId}:project/${CodeBuildProjectName}"
        }
    )
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($TriggerPolicyPath, $TriggerPolicy, $Utf8NoBom)
aws iam put-role-policy --role-name $TriggerRoleName --policy-name "StartCodeBuildProject" --policy-document "file://$TriggerPolicyPath"

# Package and create or update the trigger Lambda. Lambda includes boto3 in its runtime.
Compress-Archive -Path (Join-Path $TriggerDir "index.py") -DestinationPath $TriggerZip -Force
$TriggerRoleArn = "arn:aws:iam::${AccountId}:role/${TriggerRoleName}"
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
aws lambda get-function --function-name $TriggerLambdaName --region $Region 2>$null
$TriggerExists = $LASTEXITCODE -eq 0
$ErrorActionPreference = $PreviousErrorActionPreference
if ($TriggerExists) {
    aws lambda update-function-code --function-name $TriggerLambdaName --region $Region --zip-file "fileb://$TriggerZip"
    aws lambda update-function-configuration --function-name $TriggerLambdaName --region $Region --role $TriggerRoleArn --handler "index.lambda_handler" --runtime python3.12 --timeout 10 --environment "Variables={CODEBUILD_PROJECT_NAME=$CodeBuildProjectName}"
} else {
    aws lambda create-function --function-name $TriggerLambdaName --region $Region --runtime python3.12 --role $TriggerRoleArn --handler "index.lambda_handler" --timeout 10 --environment "Variables={CODEBUILD_PROJECT_NAME=$CodeBuildProjectName}" --zip-file "fileb://$TriggerZip"
}

# Objective 4: create the CodeBuild service role with S3 read and Lambda update permissions.
$CodeBuildTrustPath = Join-Path $PolicyDir "codebuild-trust.json"
$CodeBuildTrust = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Effect = "Allow"
            Principal = @{ Service = "codebuild.amazonaws.com" }
            Action = "sts:AssumeRole"
        }
    )
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($CodeBuildTrustPath, $CodeBuildTrust, $Utf8NoBom)
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
aws iam get-role --role-name $CodeBuildRoleName 2>$null
$CodeBuildRoleExists = $LASTEXITCODE -eq 0
$ErrorActionPreference = $PreviousErrorActionPreference
if (-not $CodeBuildRoleExists) {
    aws iam create-role --role-name $CodeBuildRoleName --assume-role-policy-document "file://$CodeBuildTrustPath"
}
aws iam update-assume-role-policy --role-name $CodeBuildRoleName --policy-document "file://$CodeBuildTrustPath"
if ($LASTEXITCODE -ne 0) {
    throw "Could not configure the CodeBuild role trust policy."
}

$CodeBuildPolicyPath = Join-Path $PolicyDir "codebuild-policy.json"
$CodeBuildPolicy = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid = "ReadBuildSource"
            Effect = "Allow"
            Action = @("s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket")
            Resource = @("arn:aws:s3:::${BucketName}", "arn:aws:s3:::${BucketName}/*")
        },
        @{
            Sid = "UpdateTargetLambda"
            Effect = "Allow"
            Action = @("lambda:GetFunction", "lambda:UpdateFunctionCode")
            Resource = "arn:aws:lambda:${Region}:${AccountId}:function:${TargetLambdaName}"
        },
        @{
            Sid = "WriteCodeBuildLogs"
            Effect = "Allow"
            Action = @("logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents")
            Resource = "*"
        }
    )
} | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($CodeBuildPolicyPath, $CodeBuildPolicy, $Utf8NoBom)
aws iam put-role-policy --role-name $CodeBuildRoleName --policy-name "CodeBuildLambdaDeployment" --policy-document "file://$CodeBuildPolicyPath"
$CodeBuildRoleArn = "arn:aws:iam::${AccountId}:role/${CodeBuildRoleName}"

# Objective 5: create or update CodeBuild. Its source is build.zip in the existing bucket.
$ProjectDefinitionPath = Join-Path $PolicyDir "codebuild-project.json"
$ProjectDefinition = @{
    name = $CodeBuildProjectName
    source = @{
        type = "S3"
        location = "${BucketName}/build.zip"
        buildspec = "buildspec.yaml"
    }
    artifacts = @{ type = "NO_ARTIFACTS" }
    serviceRole = $CodeBuildRoleArn
    environment = @{
        type = "LINUX_CONTAINER"
        image = "aws/codebuild/standard:7.0"
        computeType = "BUILD_GENERAL1_SMALL"
        imagePullCredentialsType = "CODEBUILD"
        environmentVariables = @(
            @{ name = "TARGET_LAMBDA_NAME"; value = $TargetLambdaName; type = "PLAINTEXT" }
        )
    }
} | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($ProjectDefinitionPath, $ProjectDefinition, $Utf8NoBom)
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$ExistingProjectName = aws codebuild batch-get-projects --names $CodeBuildProjectName --region $Region --query "projects[0].name" --output text 2>$null
$CodeBuildProjectExists = $LASTEXITCODE -eq 0 -and $ExistingProjectName -eq $CodeBuildProjectName
$ErrorActionPreference = $PreviousErrorActionPreference
if ($CodeBuildProjectExists) {
    aws codebuild update-project --cli-input-json "file://$ProjectDefinitionPath" --region $Region
} else {
    aws codebuild create-project --cli-input-json "file://$ProjectDefinitionPath" --region $Region
}
if ($LASTEXITCODE -ne 0) {
    throw "CodeBuild project could not be created or updated. Check the service role trust policy and IAM propagation."
}

# Objective 3: allow S3 to invoke the trigger Lambda and configure object-created events.
$TriggerFunctionArn = aws lambda get-function --function-name $TriggerLambdaName --region $Region --query "Configuration.FunctionArn" --output text
$PreviousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
aws lambda add-permission --function-name $TriggerLambdaName --region $Region --statement-id $EventNotificationName --action "lambda:InvokeFunction" --principal s3.amazonaws.com --source-arn "arn:aws:s3:::${BucketName}" --source-account $AccountId 2>$null
$PermissionExitCode = $LASTEXITCODE
$ErrorActionPreference = $PreviousErrorActionPreference
if ($PermissionExitCode -ne 0) {
    $ExistingLambdaPolicy = aws lambda get-policy --function-name $TriggerLambdaName --region $Region --query "Policy" --output text 2>$null
    if ($LASTEXITCODE -ne 0 -or $ExistingLambdaPolicy -notmatch [regex]::Escape($EventNotificationName)) {
        throw "Could not add or verify the S3 invoke permission for the trigger Lambda."
    }
}

$NotificationPath = Join-Path $PolicyDir "s3-notification.json"
$Notification = @{
    LambdaFunctionConfigurations = @(
        @{
            Id = $EventNotificationName
            LambdaFunctionArn = $TriggerFunctionArn
            Events = @("s3:ObjectCreated:*")
            Filter = @{ Key = @{ FilterRules = @(@{ Name = "suffix"; Value = ".zip" }) } }
        }
    )
} | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($NotificationPath, $Notification, $Utf8NoBom)
aws s3api put-bucket-notification-configuration --bucket $BucketName --region $Region --notification-configuration "file://$NotificationPath"
if ($LASTEXITCODE -ne 0) {
    throw "Could not configure the S3 event notification."
}

# Prepare and upload the source artifact. This upload starts the S3 event pipeline.
Compress-Archive -Path @(
    (Join-Path $TaskDir "index.py"),
    (Join-Path $TaskDir "requirements.txt"),
    (Join-Path $TaskDir "buildspec.yaml")
) -DestinationPath $BuildZip -Force
aws s3 cp $BuildZip "s3://${BucketName}/build.zip" --region $Region
if ($LASTEXITCODE -ne 0) {
    throw "Could not upload build.zip to the S3 source bucket."
}

Write-Output "Task 2 resources configured. Check CodeBuild and CloudWatch logs for the build result."
