# Task 04: Terraform Infrastructure CI/CD

## Task Resources
Region-specific resources must be created in the eu-west-1 region. For more details about regional services, see AWS Services by Region.

In this task, you will work with the following resources:

S3 Bucket cmtr-msdta2zd-bucket-cicd-tf-20260921080119 automatically created bucket containing the Terraform archive.
Terraform configuration infrastructure definition managed via code.
Git repository (GitHub or GitLab) stores Terraform configuration and pipeline definition.
CI/CD pipeline executes Terraform commands on every push to the main branch.
## Objectives
You must complete the following steps:

Open the provided Amazon S3 bucket cmtr-msdta2zd-bucket-cicd-tf-20260921080119 created for this task.
Download the Terraform archive from the bucket.
Extract the archive locally.

## Create a new GitHub or GitLab repository.
Commit and push the extracted Terraform code to the main branch.

## Configure a CI/CD pipeline that automatically executes terraform init and terraform apply on every push to the main branch.

## Create a deploy/access token with permission to push changes to the repository
Provide the deploy/access token for task verification.
## Verification
The task is considered successfully completed if every push to the main branch automatically triggers the CI/CD pipeline and applies infrastructure changes using Terraform.

The pipeline must run without errors and ensure that the deployed infrastructure matches the Terraform configuration.

Attention! After completing the task, delete the GitHub or GitLab access/deploy token that was created for this task.

## Deployment Time
It takes up to 2 minutes to deploy task resources.
