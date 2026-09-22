[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Prefix = "cmtr-msdta2zd",
    [string]$PrimaryRegion = "us-east-1",
    [string]$SecondaryRegion = "eu-west-1"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String).Trim()
}

function Get-ApplicationAutoScalingGroups {
    param([string]$Region, [string]$TargetGroupName)

    $targetGroupArn = (Invoke-Aws @(
        "elbv2", "describe-target-groups", "--names", $TargetGroupName,
        "--region", $Region, "--query", "TargetGroups[0].TargetGroupArn", "--output", "text"
    )).Trim()
    $groups = (Invoke-Aws @("autoscaling", "describe-auto-scaling-groups", "--region", $Region, "--output", "json") | ConvertFrom-Json).AutoScalingGroups
    $attachedGroups = @($groups | Where-Object { $_.TargetGroupARNs -contains $targetGroupArn })
    if ($attachedGroups.Count -eq 0) {
        throw "No Auto Scaling Group is attached to target group $TargetGroupName in $Region."
    }

    return $attachedGroups
}

function Remove-StaleApplicationAutoScalingGroups {
    param([string]$Region, [string]$Suffix)

    $targetGroupName = "$Prefix-app-$Suffix"
    $attachedGroups = Get-ApplicationAutoScalingGroups -Region $Region -TargetGroupName $targetGroupName
    $activeGroup = $attachedGroups | Sort-Object CreatedTime -Descending | Select-Object -First 1
    $staleGroups = @($attachedGroups | Where-Object { $_.AutoScalingGroupName -ne $activeGroup.AutoScalingGroupName })

    Write-Output "Keeping active ASG in ${Region}: $($activeGroup.AutoScalingGroupName)"
    foreach ($staleGroup in $staleGroups) {
        $name = $staleGroup.AutoScalingGroupName
        Write-Output "Deleting stale ASG in ${Region}: $name"
        Invoke-Aws @("autoscaling", "delete-auto-scaling-group", "--auto-scaling-group-name", $name, "--force-delete", "--region", $Region) | Out-Null
    }

    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 10
        $remainingGroups = Get-ApplicationAutoScalingGroups -Region $Region -TargetGroupName $targetGroupName
    } while ($remainingGroups.Count -ne 1 -and (Get-Date) -lt $deadline)

    if ($remainingGroups.Count -ne 1) {
        $remainingNames = $remainingGroups.AutoScalingGroupName -join ", "
        throw "Expected one ASG in $Region after cleanup; found: $remainingNames"
    }

    Write-Output "PASS: exactly one application ASG remains in ${Region}: $($remainingGroups[0].AutoScalingGroupName)"
}

Write-Output "=== Confirm AWS identity ==="
Invoke-Aws @("sts", "get-caller-identity", "--query", "{Account:Account,Arn:Arn}", "--output", "table") | Out-Host

Remove-StaleApplicationAutoScalingGroups -Region $PrimaryRegion -Suffix "us-east-1"
Remove-StaleApplicationAutoScalingGroups -Region $SecondaryRegion -Suffix "eu-west-1"

Write-Output "ASG cleanup complete. Run the lab verifier again."
