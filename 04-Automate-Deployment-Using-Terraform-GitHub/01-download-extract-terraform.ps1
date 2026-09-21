[CmdletBinding()]
param(
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } else { "eu-west-1" }),
    [string]$BucketName = $env:TERRAFORM_ARCHIVE_BUCKET,
    [string]$ArchiveKey = $env:TERRAFORM_ARCHIVE_KEY
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
$TaskRoot = $PSScriptRoot
$DownloadDirectory = Join-Path $TaskRoot "terraform-download"
$ExtractDirectory = Join-Path $TaskRoot "terraform-source"

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    return ($output | Out-String | ConvertFrom-Json)
}

Write-Output "=== 1. Verify AWS identity ==="
Invoke-AwsJson @("sts", "get-caller-identity", "--query", "{Account:Account,Arn:Arn}", "--output", "json") | ConvertTo-Json

Write-Output "=== 2. Find Terraform archive bucket ==="
if ([string]::IsNullOrWhiteSpace($BucketName)) {
    $allBuckets = @(Invoke-AwsJson @("s3api", "list-buckets", "--query", "Buckets[].Name", "--output", "json"))
    $candidates = @()

    foreach ($candidateBucket in $allBuckets) {
        $objects = @(Invoke-AwsJson @(
            "s3api", "list-objects-v2",
            "--bucket", $candidateBucket,
            "--query", "Contents[].Key",
            "--output", "json"
        ))

        $archiveObjects = @($objects | Where-Object { $_ -match '(?i)\.(zip|tar|tar\.gz|tgz)$' })
        if ($archiveObjects.Count -gt 0) {
            $candidates += [pscustomobject]@{
                Bucket = $candidateBucket
                Archives = $archiveObjects -join ", "
            }
        }
    }

    if ($candidates.Count -eq 0) {
        throw "No S3 bucket containing a zip/tar Terraform archive was found. Set -BucketName and -ArchiveKey explicitly if the archive has an unusual name."
    }

    if ($candidates.Count -eq 1) {
        $BucketName = $candidates[0].Bucket
    } else {
        Write-Output "Candidate buckets:"
        for ($index = 0; $index -lt $candidates.Count; $index++) {
            Write-Output ("[{0}] {1} -> {2}" -f ($index + 1), $candidates[$index].Bucket, $candidates[$index].Archives)
        }

        $selection = [int](Read-Host "Select bucket number")
        if ($selection -lt 1 -or $selection -gt $candidates.Count) {
            throw "Invalid bucket selection."
        }

        $BucketName = $candidates[$selection - 1].Bucket
    }
}

Write-Output "Using bucket: $BucketName"

Write-Output "=== 3. Find Terraform archive object ==="
if ([string]::IsNullOrWhiteSpace($ArchiveKey)) {
    $objects = @(Invoke-AwsJson @(
        "s3api", "list-objects-v2",
        "--bucket", $BucketName,
        "--query", "Contents[].Key",
        "--output", "json"
    ))

    $archives = @($objects | Where-Object { $_ -match '(?i)\.(zip|tar|tar\.gz|tgz)$' })
    if ($archives.Count -eq 0) {
        throw "No zip/tar archive found in bucket '$BucketName'. Set -ArchiveKey explicitly if needed."
    }

    if ($archives.Count -eq 1) {
        $ArchiveKey = $archives[0]
    } else {
        Write-Output "Archive objects:"
        for ($index = 0; $index -lt $archives.Count; $index++) {
            Write-Output ("[{0}] {1}" -f ($index + 1), $archives[$index])
        }

        $selection = [int](Read-Host "Select archive number")
        if ($selection -lt 1 -or $selection -gt $archives.Count) {
            throw "Invalid archive selection."
        }

        $ArchiveKey = $archives[$selection - 1]
    }
}

Write-Output "Using archive: $ArchiveKey"

New-Item -ItemType Directory -Path $DownloadDirectory -Force | Out-Null
if (Test-Path -LiteralPath $ExtractDirectory) {
    throw "Extraction directory already exists: $ExtractDirectory. Remove it manually after checking its contents, then rerun."
}
New-Item -ItemType Directory -Path $ExtractDirectory -Force | Out-Null

$archiveName = Split-Path -Leaf $ArchiveKey
$archivePath = Join-Path $DownloadDirectory $archiveName

Write-Output "=== 4. Download archive ==="
& aws s3 cp "s3://$BucketName/$ArchiveKey" $archivePath --region $Region
if ($LASTEXITCODE -ne 0) {
    throw "Terraform archive download failed."
}

Write-Output "=== 5. Extract archive ==="
$lowerName = $archiveName.ToLowerInvariant()
if ($lowerName.EndsWith(".zip")) {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $ExtractDirectory -Force
} elseif ($lowerName.EndsWith(".tar.gz") -or $lowerName.EndsWith(".tgz")) {
    tar -xzf $archivePath -C $ExtractDirectory
} elseif ($lowerName.EndsWith(".tar")) {
    tar -xf $archivePath -C $ExtractDirectory
} else {
    throw "Unsupported archive format: $archiveName"
}

Write-Output "Objective 1 complete. Terraform source extracted to: $ExtractDirectory"
Get-ChildItem -LiteralPath $ExtractDirectory -Recurse -File | Select-Object FullName
