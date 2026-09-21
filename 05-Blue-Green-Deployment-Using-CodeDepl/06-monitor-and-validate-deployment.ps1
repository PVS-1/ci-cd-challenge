[CmdletBinding()]
param(
    [string]$DeploymentId = "d-K2CBIFJKL",
    [string]$Region = "eu-west-1",
    [string]$LoadBalancerName = "cmtr-msdta2zd-alb"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

Write-Output "=== 1. Deployment status ==="
$DeploymentOutput = aws deploy get-deployment `
    --deployment-id $DeploymentId `
    --region $Region `
    --query "deploymentInfo.{Status:status,Application:applicationName,Group:deploymentGroupName,Description:description,CreateTime:createTime,CompleteTime:completeTime,Error:errorInformation}" `
    --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw (($DeploymentOutput | Out-String).Trim())
}
$Deployment = (($DeploymentOutput | Out-String) | ConvertFrom-Json)
$Deployment | ConvertTo-Json | Out-Host

if ($Deployment.Status -ne "Succeeded" -and $Deployment.Status -ne "Failed") {
    Write-Output "Deployment is still $($Deployment.Status). Run this script again after the deployment progresses. ALB validation is skipped."
    exit 0
}

Write-Output "=== 2. Deployment targets and lifecycle events ==="
$TargetIds = @(aws deploy list-deployment-targets `
    --deployment-id $DeploymentId `
    --region $Region `
    --query "targetIds" `
    --output json | ConvertFrom-Json)

if ($TargetIds.Count -gt 0) {
    aws deploy batch-get-deployment-targets `
        --deployment-id $DeploymentId `
        --target-ids $TargetIds `
        --region $Region `
        --query "deploymentTargets[].{TargetId:targetId,Status:status,LifecycleEvents:instanceTarget.lifecycleEvents}" `
        --output json
} else {
    Write-Output "No deployment targets returned yet. Run this script again while deployment is in progress."
}

if ($Deployment.Status -eq "Failed") {
    throw "Deployment failed: $($Deployment.Error | ConvertTo-Json -Compress)"
}

Write-Output "=== 3. Find ALB endpoint ==="
$LoadBalancerDns = ([string](aws elbv2 describe-load-balancers `
    --names $LoadBalancerName `
    --region $Region `
    --query "LoadBalancers[0].DNSName" `
    --output text 2>$null)).Trim()

if ([string]::IsNullOrWhiteSpace($LoadBalancerDns) -or $LoadBalancerDns -eq "None") {
    $LoadBalancers = @(aws elbv2 describe-load-balancers `
        --region $Region `
        --query "LoadBalancers[].{Name:LoadBalancerName,DNSName:DNSName}" `
        --output json | ConvertFrom-Json)
    if ($LoadBalancers.Count -eq 1) {
        $LoadBalancerDns = $LoadBalancers[0].DNSName
        Write-Output "Using discovered ALB: $($LoadBalancers[0].Name)"
    } else {
        throw "ALB '$LoadBalancerName' was not found and automatic selection is ambiguous."
    }
}

Write-Output "ALB DNS: $LoadBalancerDns"

Write-Output "=== 4. Validate application endpoint ==="
$Response = Invoke-WebRequest "http://$LoadBalancerDns/"
Write-Output "HTTP status: $($Response.StatusCode)"
Write-Output $Response.Content

$HealthResponse = Invoke-WebRequest "http://$LoadBalancerDns/health"
Write-Output "Health status: $($HealthResponse.StatusCode)"
Write-Output $HealthResponse.Content

if ($Response.Content -notmatch "msdta2zd") {
    throw "The root endpoint does not contain the required greeting identifier."
}
if ($HealthResponse.StatusCode -ne 200) {
    throw "The /health endpoint did not return HTTP 200."
}

Write-Output "Objective 5 validation complete."
