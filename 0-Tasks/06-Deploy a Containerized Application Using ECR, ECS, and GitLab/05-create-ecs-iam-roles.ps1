[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$ExecutionRoleName = "cmtr-msdta2zd-ecs-task-execution-role",
    [string]$TaskRoleName = "cmtr-msdta2zd-ecs-task-role",
    [string]$LambdaRoleName = "cmtr-msdta2zd-lambda-role",
    [string]$FunctionName = "cmtr-msdta2zd-function",
    [string]$RuleName = "cmtr-msdta2zd-rule"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("ecs-iam-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = @(& aws @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    if ($exitCode -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String)
}

function Test-IamRoleExists {
    param([Parameter(Mandatory = $true)][string]$RoleName)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & aws iam get-role --role-name $RoleName 1>$null 2>$null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference
    return $exitCode -eq 0
}

function New-IamRoleIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$RoleName,
        [Parameter(Mandatory = $true)][string]$TrustPolicyPath
    )

    if (Test-IamRoleExists -RoleName $RoleName) {
        Write-Output "Role exists: $RoleName"
    } else {
        Invoke-Aws @(
            "iam", "create-role",
            "--role-name", $RoleName,
            "--assume-role-policy-document", "file://$TrustPolicyPath"
        ) | Out-Host
        Write-Output "Role created: $RoleName"
    }
}

function Add-IamManagedPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$RoleName,
        [Parameter(Mandatory = $true)][string]$PolicyArn
    )

    $attached = Invoke-Aws @(
        "iam", "list-attached-role-policies",
        "--role-name", $RoleName,
        "--query", "AttachedPolicies[].PolicyArn",
        "--output", "text"
    )

    if ($attached -match [regex]::Escape($PolicyArn)) {
        Write-Output "Policy already attached"
        Write-Output $PolicyArn
    } else {
        Invoke-Aws @(
            "iam", "attach-role-policy",
            "--role-name", $RoleName,
            "--policy-arn", $PolicyArn
        ) | Out-Host
        Write-Output "Policy attached"
        Write-Output $PolicyArn
    }
}

try {
    Write-Output "=== 1. Verify AWS identity ==="
    Invoke-Aws @(
        "sts", "get-caller-identity",
        "--query", "{Account:Account,Arn:Arn}",
        "--output", "json"
    ) | Out-Host

    $TrustPolicyPath = Join-Path $TempDirectory "ecs-tasks-trust.json"
    $TrustPolicy = @'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "ecs-tasks.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
'@
    [System.IO.File]::WriteAllText($TrustPolicyPath, $TrustPolicy, $Utf8NoBom)

    Write-Output "=== 2. ECS task execution role ==="
    New-IamRoleIfMissing -RoleName $ExecutionRoleName -TrustPolicyPath $TrustPolicyPath
    Add-IamManagedPolicy `
        -RoleName $ExecutionRoleName `
        -PolicyArn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

    Write-Output "=== 3. ECS task role ==="
    New-IamRoleIfMissing -RoleName $TaskRoleName -TrustPolicyPath $TrustPolicyPath

    Write-Output "=== 4. Verify Lambda role and EventBridge rule ==="
    Invoke-Aws @(
        "iam", "get-role",
        "--role-name", $LambdaRoleName,
        "--query", "Role.Arn",
        "--output", "text"
    ) | Out-Host
    Invoke-Aws @(
        "lambda", "get-policy",
        "--function-name", $FunctionName,
        "--region", $Region,
        "--query", "Policy",
        "--output", "json"
    ) | Out-Host
    Invoke-Aws @(
        "events", "describe-rule",
        "--name", $RuleName,
        "--region", $Region,
        "--query", "{Name:Name,State:State,Arn:Arn}",
        "--output", "json"
    ) | Out-Host

    Write-Output "Objective 7 complete. ECS roles and event configuration are ready."
}
finally {
    Remove-Item -LiteralPath $TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
