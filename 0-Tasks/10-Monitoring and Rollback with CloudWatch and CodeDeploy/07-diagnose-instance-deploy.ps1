[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DeploymentId,
    [string]$Region = "eu-west-1",
    [string]$Prefix = "cmtr-msdta2zd"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"
$tempFiles = [System.Collections.Generic.List[string]]::new()

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String).Trim()
}

function Wait-Command {
    param([string]$CommandId, [string]$InstanceId)

    $deadline = (Get-Date).AddMinutes(2)
    do {
        $result = Invoke-Aws @("ssm", "get-command-invocation", "--command-id", $CommandId, "--instance-id", $InstanceId, "--region", $Region, "--output", "json") | ConvertFrom-Json
        if ($result.Status -in @("Success", "Failed", "TimedOut", "Cancelled")) { return $result }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "SSM command $CommandId did not complete for $InstanceId."
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)]$Value)

    $path = Join-Path $env:TEMP ("cmtr-msdta2zd-" + [guid]::NewGuid().ToString("N") + ".json")
    ConvertTo-Json -InputObject $Value -Depth 5 | Set-Content -LiteralPath $path -Encoding ascii
    $tempFiles.Add($path)
    return $path
}

try {
    $targetIds = (Invoke-Aws @("deploy", "list-deployment-targets", "--deployment-id", $DeploymentId, "--region", $Region, "--query", "targetIds", "--output", "text")).Trim() -split "\s+"
    foreach ($instanceId in $targetIds | Where-Object { $_ }) {
        Write-Output "=== Instance ${instanceId} ==="
        $commands = @(
            "echo '--- CodeDeploy agent ---'",
            "sudo systemctl status codedeploy-agent --no-pager || true",
            "echo '--- Application service ---'",
            "sudo systemctl status cmtr-msdta2zd-app.service --no-pager || true",
            "echo '--- CodeDeploy log ---'",
            "sudo tail -n 80 /var/log/aws/codedeploy-agent/codedeploy-agent.log || true",
            "echo '--- Deployment logs ---'",
            "sudo find /opt/codedeploy-agent/deployment-root -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 5 | cut -d' ' -f2- | xargs -r -n1 sudo tail -n 40 || true",
            "echo '--- Application log ---'",
            "sudo journalctl -u cmtr-msdta2zd-app.service -n 80 --no-pager || true"
        )
        $parametersFile = Write-JsonFile @{ commands = $commands }
        $commandId = (Invoke-Aws @("ssm", "send-command", "--instance-ids", $instanceId, "--document-name", "AWS-RunShellScript", "--parameters", "file://$parametersFile", "--region", $Region, "--query", "Command.CommandId", "--output", "text")).Trim()
        $result = Wait-Command -CommandId $commandId -InstanceId $instanceId
        $result.StandardOutputContent | Out-Host
        if ($result.Status -ne "Success") {
            Write-Warning "SSM diagnostics failed on ${instanceId}: $($result.StandardErrorContent)"
        }
    }
} finally {
    foreach ($file in $tempFiles) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
