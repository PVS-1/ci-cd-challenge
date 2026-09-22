[CmdletBinding()]
param(
    [string]$Region = "eu-west-1",
    [string]$BucketName = "cmtr-msdta2zd-bucket-cicd-tf-20260922065540",
    [string]$ArchiveKey
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$sourceRoot = Join-Path $PSScriptRoot "lambdas"
$temporaryDownload = Join-Path $env:TEMP ("cmtr-msdta2zd-lambda-source-" + [guid]::NewGuid().ToString("N"))
$temporaryExtract = Join-Path $env:TEMP ("cmtr-msdta2zd-lambdas-" + [guid]::NewGuid().ToString("N"))

function Invoke-Aws {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = @(& aws @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed: aws $($Arguments -join ' ')`n$(($output | Out-String).Trim())"
    }
}

try {
    Invoke-Aws @("sts", "get-caller-identity", "--query", "Account", "--output", "text") | Out-Null
    New-Item -ItemType Directory -Path $temporaryDownload -Force | Out-Null
    Invoke-Aws @("s3", "sync", "s3://$BucketName", $temporaryDownload, "--region", $Region) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($ArchiveKey)) {
        $archivePath = Join-Path $temporaryDownload $ArchiveKey
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            throw "Archive key $ArchiveKey was not downloaded from bucket $BucketName."
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $temporaryExtract -Force
    }
    else {
        $archives = @(Get-ChildItem -LiteralPath $temporaryDownload -Recurse -File | Where-Object { $_.Extension -ieq ".zip" })
        if ($archives.Count -eq 1) {
            Write-Output "Extracting source archive: $($archives[0].FullName)"
            Expand-Archive -LiteralPath $archives[0].FullName -DestinationPath $temporaryExtract -Force
        } elseif ($archives.Count -eq 0) {
            Write-Output "No ZIP archive found; using downloaded source files directly."
            $temporaryExtract = $temporaryDownload
        } else {
            $archiveNames = $archives.FullName -join ", "
            throw "More than one ZIP archive was found in bucket ${BucketName}: $archiveNames"
        }
    }
    New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

    foreach ($functionName in @(
        "cmtr_msdta2zd_lambda_createOrder",
        "cmtr_msdta2zd_lambda_reserveStock",
        "cmtr_msdta2zd_lambda_sendNotification"
    )) {
        $handler = Get-ChildItem -LiteralPath $temporaryExtract -Recurse -File -Filter "handler.py" |
            Where-Object { $_.Directory.Name -eq $functionName } |
            Select-Object -First 1
        if (-not $handler) {
            throw "handler.py for $functionName was not found in $ArchiveKey."
        }

        $destination = Join-Path $sourceRoot $functionName
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -LiteralPath $handler.FullName -Destination (Join-Path $destination "handler.py") -Force
    }

    Write-Output "Lambda source extracted to $sourceRoot"
} finally {
    Remove-Item -LiteralPath $temporaryDownload -Recurse -Force -ErrorAction SilentlyContinue
    if ($temporaryExtract -ne $temporaryDownload) {
        Remove-Item -LiteralPath $temporaryExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}
