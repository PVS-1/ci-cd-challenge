[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$RuleName = "cmtr-msdta2zd-rule",
    [string]$FunctionName = "cmtr-msdta2zd-function",
    [string]$RepositoryName = "cmtr-msdta2zd-static"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-AwsCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& aws @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    if ($exitCode -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String)
}

Write-Output "=== 1. Resolve Lambda ARN ==="
$FunctionArn = ([string](Invoke-AwsCli @(
    "lambda", "get-function",
    "--function-name", $FunctionName,
    "--region", $Region,
    "--query", "Configuration.FunctionArn",
    "--output", "text"
))).Trim()

$AccountId = ([string](Invoke-AwsCli @(
    "sts", "get-caller-identity",
    "--query", "Account",
    "--output", "text"
))).Trim()

Write-Output "=== 2. Create or update EventBridge rule ==="
$EventPatternPath = Join-Path $env:TEMP "cmtr-msdta2zd-ecr-event-pattern.json"
$EventPattern = @{
    source = @("aws.ecr")
    "detail-type" = @("ECR Image Action")
    detail = @{
        "action-type" = @("PUSH")
        "repository-name" = @($RepositoryName)
        result = @("SUCCESS")
    }
} | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($EventPatternPath, $EventPattern, $Utf8NoBom)

Invoke-AwsCli @(
    "events", "put-rule",
    "--name", $RuleName,
    "--event-pattern", "file://$EventPatternPath",
    "--state", "ENABLED",
    "--description", "Trigger ECS deployment when a new ECR image is pushed",
    "--region", $Region,
    "--query", "RuleArn",
    "--output", "text"
) | Out-Host

$RuleArn = ([string](Invoke-AwsCli @(
    "events", "describe-rule",
    "--name", $RuleName,
    "--region", $Region,
    "--query", "Arn",
    "--output", "text"
))).Trim()

Write-Output "=== 3. Allow EventBridge to invoke Lambda ==="
$StatementId = "${RuleName}-invoke"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$PermissionOutput = @(& aws lambda add-permission `
    --function-name $FunctionName `
    --statement-id $StatementId `
    --action lambda:InvokeFunction `
    --principal events.amazonaws.com `
    --source-arn $RuleArn `
    --source-account $AccountId `
    --region $Region 2>&1)
$PermissionExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference

if ($PermissionExitCode -ne 0) {
    $PermissionDetails = ($PermissionOutput | Out-String).Trim()
    if ($PermissionDetails -match "ResourceConflictException") {
        Write-Output "Lambda permission already exists: $StatementId"
    } else {
        throw "Could not add Lambda permission.`n$PermissionDetails"
    }
}

Write-Output "=== 4. Attach Lambda target ==="
$Target = "[{`"Id`":`"lambda-target`",`"Arn`":`"$FunctionArn`"}]"
$TargetPath = Join-Path $env:TEMP "cmtr-msdta2zd-event-target.json"
[System.IO.File]::WriteAllText($TargetPath, $Target, $Utf8NoBom)

Invoke-AwsCli @(
    "events", "put-targets",
    "--rule", $RuleName,
    "--targets", "file://$TargetPath",
    "--region", $Region,
    "--output", "json"
) | Out-Host

Write-Output "=== Objective 6 complete ==="
Write-Output "Rule: $RuleName"
Write-Output "State: ENABLED"
Write-Output "Target Lambda: $FunctionName"
Write-Output "ECR repository filter: $RepositoryName"
