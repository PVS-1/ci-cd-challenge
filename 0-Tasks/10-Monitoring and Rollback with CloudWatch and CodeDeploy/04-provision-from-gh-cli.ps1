[CmdletBinding()]
param(
    [string]$GitHubRepository = "PVS-1/ci-cd-challenge",
    [string]$BranchName = "main",
    [string]$Region = "eu-west-1"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Invoke-CommandChecked {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& $FilePath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }

    return ($output | Out-String).Trim()
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI is not installed. Install gh and run 'gh auth login' first."
}

Invoke-CommandChecked gh @("auth", "status", "--hostname", "github.com") | Out-Host
Invoke-CommandChecked gh @("api", "repos/$GitHubRepository") | Out-Null
Invoke-CommandChecked gh @("api", "repos/$GitHubRepository/hooks") | Out-Null

$githubToken = Invoke-CommandChecked gh @("auth", "token", "--hostname", "github.com")
if ([string]::IsNullOrWhiteSpace($githubToken)) {
    throw "GitHub CLI did not return an authentication token. Run 'gh auth login' again."
}

try {
    & (Join-Path $PSScriptRoot "02-provision-pipeline-monitoring.ps1") `
        -GitHubOAuthToken $githubToken `
        -GitHubRepository $GitHubRepository `
        -BranchName $BranchName `
        -Region $Region
    if ($LASTEXITCODE -ne 0) {
        throw "Goal 10 provisioning failed."
    }
} finally {
    Remove-Variable githubToken -ErrorAction SilentlyContinue
}
