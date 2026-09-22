[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$StateMachineName = "cmtr-msdta2zd-state-machine"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$tempFiles = [System.Collections.Generic.List[string]]::new()

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String).Trim()
}

function Get-LambdaArn {
    param([string]$FunctionName)

    return (Invoke-Aws @(
        "lambda", "get-function", "--function-name", $FunctionName,
        "--region", $Region, "--query", "Configuration.FunctionArn", "--output", "text"
    )).Trim()
}

try {
    Invoke-Aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text") | Out-Null
    $stateMachineArn = (Invoke-Aws @(
        "stepfunctions", "list-state-machines", "--region", $Region,
        "--query", "stateMachines[?name=='$StateMachineName'].stateMachineArn | [0]", "--output", "text"
    )).Trim()
    if ([string]::IsNullOrWhiteSpace($stateMachineArn) -or $stateMachineArn -eq "None") {
        throw "State machine $StateMachineName was not found in $Region."
    }

    $definition = @{
        Comment = "Order processing workflow"
        StartAt = "CreateOrder"
        States = @{
            CreateOrder = @{
                Type = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Parameters = @{
                    FunctionName = Get-LambdaArn "cmtr_msdta2zd_lambda_createOrder"
                    "Payload.$" = "$"
                }
                OutputPath = "$.Payload"
                Next = "ReserveStock"
            }
            ReserveStock = @{
                Type = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Parameters = @{
                    FunctionName = Get-LambdaArn "cmtr_msdta2zd_lambda_reserveStock"
                    "Payload.$" = "$"
                }
                OutputPath = "$.Payload"
                Next = "SendNotification"
            }
            SendNotification = @{
                Type = "Task"
                Resource = "arn:aws:states:::lambda:invoke"
                Parameters = @{
                    FunctionName = Get-LambdaArn "cmtr_msdta2zd_lambda_sendNotification"
                    "Payload.$" = "$"
                }
                OutputPath = "$.Payload"
                End = $true
            }
        }
    }
    $definitionPath = Join-Path $env:TEMP ("cmtr-msdta2zd-state-machine-" + [guid]::NewGuid().ToString("N") + ".json")
    $definition | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $definitionPath -Encoding ascii
    $tempFiles.Add($definitionPath)

    Invoke-Aws @(
        "stepfunctions", "update-state-machine", "--state-machine-arn", $stateMachineArn,
        "--definition", "file://$definitionPath", "--region", $Region, "--output", "json"
    ) | Out-Host
    Write-Output "State machine updated: $stateMachineArn"
} finally {
    foreach ($file in $tempFiles) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
