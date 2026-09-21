$ErrorActionPreference = "Stop"

# OBJECTIVE 4: create the GitHub Actions Terraform pipeline.
# This script writes the workflow file and does not store credentials.

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$WorkflowDirectory = Join-Path $RepositoryRoot ".github\workflows"
$WorkflowPath = Join-Path $WorkflowDirectory "04-terraform-deploy.yml"
$WorkflowContent = @'
name: Task 4 - Terraform Apply

on:
  push:
    branches:
      - main
    paths:
      - "04-Automate-Deployment-Using-Terraform-GitHub/terraform-code/**"
      - ".github/workflows/04-terraform-deploy.yml"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  terraform-deploy:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: 04-Automate-Deployment-Using-Terraform-GitHub/terraform-code
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-session-token: ${{ secrets.AWS_SESSION_TOKEN }}
          aws-region: eu-west-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3

      - name: Terraform init
        run: terraform init -input=false

      - name: Terraform validate
        run: terraform validate

      - name: Terraform apply
        run: terraform apply -auto-approve -input=false
'@

New-Item -ItemType Directory -Path $WorkflowDirectory -Force | Out-Null
Set-Content -LiteralPath $WorkflowPath -Value $WorkflowContent -Encoding utf8

Write-Output "Objective 4 complete. Workflow created: $WorkflowPath"
Write-Output "Required GitHub secrets: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN"
