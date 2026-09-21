[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$CustomIdentifier = "msdta2zd",
    [string]$VpcName = "cmtr-msdta2zd-vpc",
    [string]$LaunchTemplateName = "cmtr-msdta2zd-lt",
    [string]$AutoScalingGroupName = "cmtr-msdta2zd-asg",
    [string]$LoadBalancerName = "cmtr-msdta2zd-alb",
    [string]$TargetGroupName = "cmtr-msdta2zd-tg",
    [string]$CodeDeployServiceRoleName = "cmtr-msdta2zd-codedeploy-role",
    [string]$CodeDeployApplicationName = "cmtr-msdta2zd-app",
    [string]$DeploymentGroupName = "cmtr-msdta2zd-dg"
)

$ErrorActionPreference = "Stop"
$ApplicationPath = $PSScriptRoot
$ApplicationFile = Join-Path $ApplicationPath "application.py"
$RequirementsFile = Join-Path $ApplicationPath "requirements.txt"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$ApplicationContent = @"
from flask import Flask

application = Flask(__name__)


@application.route("/")
def index():
    return "Hello from $CustomIdentifier!"


@application.route("/health")
def health():
    return "OK", 200


if __name__ == "__main__":
    application.run(host="0.0.0.0", port=8000)
"@

[System.IO.File]::WriteAllText($ApplicationFile, $ApplicationContent.Replace("`r`n", "`n"), $Utf8NoBom)
[System.IO.File]::WriteAllText($RequirementsFile, "Flask==3.1.2`n", $Utf8NoBom)

Write-Output "Objective 1 complete. Created:"
Write-Output $ApplicationFile
Write-Output $RequirementsFile
Write-Output "Region: $Region"
Write-Output "VPC: $VpcName"
Write-Output "Launch template: $LaunchTemplateName"
Write-Output "Auto Scaling Group: $AutoScalingGroupName"
Write-Output "ALB: $LoadBalancerName"
Write-Output "Target group: $TargetGroupName"
Write-Output "CodeDeploy service role: $CodeDeployServiceRoleName"
Write-Output "CodeDeploy application: $CodeDeployApplicationName"
Write-Output "Deployment group: $DeploymentGroupName"
Write-Output "Greeting: Hello from $CustomIdentifier!"
Write-Output "Health endpoint: /health"
Write-Output "Port: 8000"
