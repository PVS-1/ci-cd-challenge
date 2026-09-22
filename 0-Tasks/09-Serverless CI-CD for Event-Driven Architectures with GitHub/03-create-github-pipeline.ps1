[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,
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

  function Invoke-CommandOptional {
    param([Parameter(Mandatory = $true)][string]$FilePath, [Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& $FilePath @Arguments 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
  }

$workflowDirectory = Join-Path $PSScriptRoot ".github\workflows"
$workflowPath = Join-Path $workflowDirectory "deploy-lambdas.yml"
  $deployUserName = "cmtr-msdta2zd-github-deployer"
  $functionNames = @("cmtr_msdta2zd_lambda_createOrder", "cmtr_msdta2zd_lambda_reserveStock", "cmtr_msdta2zd_lambda_sendNotification")

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required. Install it, run 'gh auth login', then rerun this script."
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "lambdas") -PathType Container)) {
    throw "Run 01-bootstrap-source.ps1 before creating the GitHub repository."
}

$workflow = @'
name: Deploy Lambda functions

on:
  push:
    branches: [main]
    paths:
      - 'lambdas/**'
      - '.github/workflows/deploy-lambdas.yml'
  workflow_dispatch:

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ secrets.AWS_REGION }}
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      - name: Package and deploy Lambda functions
        shell: bash
        run: |
          set -euo pipefail
          for function_name in \
            cmtr_msdta2zd_lambda_createOrder \
            cmtr_msdta2zd_lambda_reserveStock \
            cmtr_msdta2zd_lambda_sendNotification; do
            cd "lambdas/$function_name"
            zip -q -r "../../$function_name.zip" .
            cd ../..
            aws lambda update-function-code \
              --function-name "$function_name" \
              --zip-file "fileb://$function_name.zip" \
              --publish
          done
'@

New-Item -ItemType Directory -Path $workflowDirectory -Force | Out-Null
Set-Content -LiteralPath $workflowPath -Value $workflow -Encoding ascii

if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot ".git"))) {
    Invoke-CommandChecked git @("init", "--initial-branch=main") | Out-Null
}
Invoke-CommandChecked git @("add", "lambdas", ".github/workflows/deploy-lambdas.yml") | Out-Null
& git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    Invoke-CommandChecked git @("commit", "-m", "Add Lambda deployment workflow") | Out-Null
}

$repositoryLookup = Invoke-CommandOptional gh @("repo", "view", $Repository, "--json", "url", "--jq", ".url")
if ($repositoryLookup.ExitCode -eq 0) {
  $repositoryUrl = $repositoryLookup.Output
} else {
  Invoke-CommandChecked gh @("repo", "create", $Repository, "--private", "--description", "Serverless Lambda CI/CD lab") | Out-Null
  $repositoryUrl = Invoke-CommandChecked gh @("repo", "view", $Repository, "--json", "url", "--jq", ".url")
}

$remotes = & git remote
if ($remotes -contains "origin") {
    Invoke-CommandChecked git @("remote", "set-url", "origin", "$repositoryUrl.git") | Out-Null
} else {
    Invoke-CommandChecked git @("remote", "add", "origin", "$repositoryUrl.git") | Out-Null
}

$accountId = (Invoke-CommandChecked aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text")).Trim()
$userLookup = Invoke-CommandOptional aws @("iam", "get-user", "--user-name", $deployUserName)
if ($userLookup.ExitCode -ne 0) {
  Invoke-CommandChecked aws @("iam", "create-user", "--user-name", $deployUserName) | Out-Null
}

$policy = @{
  Version = "2012-10-17"
  Statement = @(@{
    Effect = "Allow"
    Action = @("lambda:GetFunction", "lambda:UpdateFunctionCode")
    Resource = @($functionNames | ForEach-Object { "arn:aws:lambda:${Region}:${accountId}:function:$_" })
  })
}
$policyPath = Join-Path $env:TEMP ("cmtr-msdta2zd-github-deployer-" + [guid]::NewGuid().ToString("N") + ".json")
try {
  $policy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $policyPath -Encoding ascii
  Invoke-CommandChecked aws @("iam", "put-user-policy", "--user-name", $deployUserName, "--policy-name", "cmtr-msdta2zd-lambda-deploy", "--policy-document", "file://$policyPath") | Out-Null
  $oldAccessKeys = (Invoke-CommandChecked aws @("iam", "list-access-keys", "--user-name", $deployUserName, "--query", "AccessKeyMetadata[].AccessKeyId", "--output", "text")) -split "\s+"
  foreach ($oldAccessKey in $oldAccessKeys | Where-Object { $_ }) {
    Invoke-CommandChecked aws @("iam", "delete-access-key", "--user-name", $deployUserName, "--access-key-id", $oldAccessKey) | Out-Null
  }
  $accessKey = Invoke-CommandChecked aws @("iam", "create-access-key", "--user-name", $deployUserName, "--output", "json") | ConvertFrom-Json
} finally {
  Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
}

Invoke-CommandChecked gh @("secret", "set", "AWS_REGION", "--repo", $Repository, "--body", $Region) | Out-Null
Invoke-CommandChecked gh @("secret", "set", "AWS_ACCESS_KEY_ID", "--repo", $Repository, "--body", $accessKey.AccessKey.AccessKeyId) | Out-Null
Invoke-CommandChecked gh @("secret", "set", "AWS_SECRET_ACCESS_KEY", "--repo", $Repository, "--body", $accessKey.AccessKey.SecretAccessKey) | Out-Null
Invoke-CommandChecked git @("push", "-u", "origin", "main") | Out-Null
Write-Output "GitHub workflow pushed and least-privilege AWS deploy secrets configured for $Repository."
