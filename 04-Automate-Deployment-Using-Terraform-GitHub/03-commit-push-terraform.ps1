[CmdletBinding()]
param(
    [string]$CommitMessage = "Add Terraform infrastructure code"
)

$ErrorActionPreference = "Stop"
$TaskRoot = $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $TaskRoot
$TerraformSource = Join-Path $TaskRoot "terraform-source"
$TerraformCode = Join-Path $TaskRoot "terraform-code"

if (-not (Test-Path -LiteralPath $TerraformSource -PathType Container)) {
    throw "Terraform source directory was not found: $TerraformSource. Run Objective 1 first."
}

$TerraformFiles = @(Get-ChildItem -LiteralPath $TerraformSource -Recurse -File | Where-Object {
    $_.Extension -in @(".tf", ".tfvars", ".json")
})

if ($TerraformFiles.Count -eq 0) {
    throw "No Terraform files were found in $TerraformSource."
}

Write-Output "=== 1. Copy Terraform source ==="
New-Item -ItemType Directory -Path $TerraformCode -Force | Out-Null
Copy-Item -Path (Join-Path $TerraformSource "*") -Destination $TerraformCode -Recurse -Force

Write-Output "Terraform files:"
Get-ChildItem -LiteralPath $TerraformCode -Recurse -File | Where-Object {
    $_.Extension -in @(".tf", ".tfvars", ".json")
} | Select-Object -ExpandProperty FullName

Write-Output "=== 2. Verify Git main branch ==="
$currentBranch = (git -C $RepositoryRoot branch --show-current).Trim()
if ($currentBranch -ne "main") {
    throw "Current branch is '$currentBranch'. Switch to main before pushing."
}

git -C $RepositoryRoot status --short

Write-Output "=== 3. Stage Terraform code ==="
git -C $RepositoryRoot add `
    "04-Automate-Deployment-Using-Terraform-GitHub/terraform-code" `
    "04-Automate-Deployment-Using-Terraform-GitHub/03-commit-push-terraform.ps1"

git -C $RepositoryRoot diff --cached --check

git -C $RepositoryRoot diff --cached --stat

$stagedChanges = git -C $RepositoryRoot diff --cached --name-only
if ([string]::IsNullOrWhiteSpace(($stagedChanges | Out-String))) {
    Write-Output "No new Terraform changes to commit."
} else {
    Write-Output "=== 4. Commit and push ==="
    git -C $RepositoryRoot commit -m $CommitMessage
    git -C $RepositoryRoot push origin main
}

Write-Output "Objective 3 complete. Terraform code is pushed to origin/main."
