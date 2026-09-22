
# AWS CLI must already be configured for the sandbox.
# Do not put access keys, secret keys, or session tokens in this file.
$env:AWS_PAGER = ""
# Change these two values before running the commands.
$Region = "eu-central-1"
$BucketName = "cmtr-msdta2zd-bucket-1789851561"
$IamUserName = "github-s3-deployer"
$IamPolicyName = "GitHubDeployToS3"

if ($BucketName -like "CHANGE-ME*") {
	throw "Change `$BucketName to a globally unique S3 bucket name first."
}

# 1. Verify the active sandbox identity.
aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) {
	throw "AWS CLI is not authenticated. Configure the sandbox credentials first."
}

# 2. Create the S3 bucket.
if ($Region -eq "us-east-1") {
	aws s3api create-bucket --bucket $BucketName --region $Region
} else {
	aws s3api create-bucket --bucket $BucketName --region $Region --create-bucket-configuration LocationConstraint=$Region
}
if ($LASTEXITCODE -ne 0) {
	throw "S3 bucket creation failed. Check the AWS identity, region, and bucket name."
}

# 3. Allow public website access at bucket level.
aws s3api put-public-access-block --bucket $BucketName --region $Region --public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

# 4. Enable S3 static website hosting.
aws s3api put-bucket-website --bucket $BucketName --region $Region --website-configuration '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"}}'

# 5. Create and apply the public-read bucket policy.
$BucketPolicyPath = Join-Path $PWD "bucket-policy.json"
$BucketPolicy = @{
	Version = "2012-10-17"
	Statement = @(
		@{
			Sid = "PublicReadForWebsite"
			Effect = "Allow"
			Principal = "*"
			Action = "s3:GetObject"
			Resource = "arn:aws:s3:::$BucketName/*"
		}
	)
} | ConvertTo-Json -Depth 5
Set-Content -Path $BucketPolicyPath -Value $BucketPolicy -Encoding utf8
aws s3api put-bucket-policy --bucket $BucketName --region $Region --policy "file://$BucketPolicyPath"

# 6. Create the IAM user if it does not exist.
aws iam get-user --user-name $IamUserName *> $null
if ($LASTEXITCODE -ne 0) {
	aws iam create-user --user-name $IamUserName
}

# 7. Create and attach the least-privilege policy required by GitHub Actions.
$IamPolicyPath = Join-Path $PWD "github-s3-policy.json"
$IamPolicy = @{
	Version = "2012-10-17"
	Statement = @(
		@{
			Sid = "ListBucket"
			Effect = "Allow"
			Action = @("s3:ListBucket")
			Resource = "arn:aws:s3:::$BucketName"
		},
		@{
			Sid = "ManageWebsiteObjects"
			Effect = "Allow"
			Action = @("s3:GetObject", "s3:PutObject", "s3:DeleteObject")
			Resource = "arn:aws:s3:::$BucketName/*"
		}
	)
} | ConvertTo-Json -Depth 5
Set-Content -Path $IamPolicyPath -Value $IamPolicy -Encoding utf8
aws iam put-user-policy --user-name $IamUserName --policy-name $IamPolicyName --policy-document "file://$IamPolicyPath"

# 8. Create an access key for GitHub Actions.
# Copy AccessKeyId and SecretAccessKey immediately to GitHub repository secrets.
# Never commit or paste this output into chat.
aws iam create-access-key --user-name $IamUserName --output json

# 9. Verify the website configuration and print the endpoint.
aws s3api head-bucket --bucket $BucketName --region $Region
if ($LASTEXITCODE -ne 0) {
	throw "Bucket '$BucketName' was not found in region '$Region'."
}
aws s3api get-bucket-website --bucket $BucketName --region $Region
if ($Region -eq "eu-central-1") {
	$WebsiteEndpoint = "$BucketName.s3-website.$Region.amazonaws.com"
} else {
	$WebsiteEndpoint = "$BucketName.s3-website-$Region.amazonaws.com"
}
Write-Output "Website endpoint: http://$WebsiteEndpoint"
