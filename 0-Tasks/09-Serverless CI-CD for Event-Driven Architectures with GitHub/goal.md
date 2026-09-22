# Task 09: Serverless Event-Driven CI/CD

## Task description
## Architecture
cmtr-msdta2zd-bucket-cicd-tf-20260922065540
(lambdas.zip)
cmtr-msdta2zd-OrdersAPI
POST /order
cmtr-msdta2zd-state-machine
cmtr_msdta2zd_lambda_reserveStock
cmtr_msdta2zd_lambda_sendNotification
cmtr-msdta2zd-Orders-table
triggers workflow
② ReserveStock
③ SendNotification
Update Item (stock)
Serverless CI/CD Pipeline — eu-west-1
Student Creates
Developer
Client / User
Git Repository
(GitHub/GitLab)
CI/CD Pipeline
(GitHub Actions/GitLab CI)
uploads lambdas.zip
pushes code
triggers
update-function-code
POST /order
cmtr_msdta2zd_lambda_createOrder
① CreateOrder
Put Item (order)
Student configures
## The Goal of the Task
To set up a CI/CD pipeline (GitHub Actions / GitLab CI) to automate deployment of AWS Lambda functions and related Step Functions workflows integrated with API Gateway.

## Task Resources
Region-specific resources must be created in the eu-west-1 region. For more details about regional services, see AWS Services by Region.

In this task, you will work with the following resources:

S3 Bucket cmtr-msdta2zd-bucket-cicd-tf-20260922065540 automatically created bucket containing source code for the Lambda functions.
Lambda function cmtr_msdta2zd_lambda_createOrder creates a new order record in the DynamoDB table cmtr-msdta2zd-Orders-table.
Lambda function cmtr_msdta2zd_lambda_reserveStock updates the order status in cmtr-msdta2zd-Orders-table after stock reservation.
Lambda function cmtr_msdta2zd_lambda_sendNotification produces a mock notification confirming order processing.
Step Functions State Machine cmtr-msdta2zd-state-machine currently contains an empty workflow and must be configured to orchestrate the Lambda execution sequence.
API Gateway cmtr-msdta2zd-OrdersAPI exposes POST /order endpoint already integrated with the Step Functions state machine.
DynamoDB Table cmtr-msdta2zd-Orders-table persists order data generated during workflow execution.
Git repository (GitHub or GitLab) stores Lambda functions and CI/CD configuration.
CI/CD pipeline updates Lambda functions on every push to the main branch.
## Objectives
You must complete the following steps:

Open the provided Amazon S3 bucket cmtr-msdta2zd-bucket-cicd-tf-20260922065540 created for this task.
Download the lambdas.zip archive from the bucket.
Extract the archive locally.
Edit the AWS Step Functions state machine cmtr-msdta2zd-state-machine so the Lambda functions execute in the following order:
cmtr_msdta2zd_lambda_createOrder
cmtr_msdta2zd_lambda_reserveStock
cmtr_msdta2zd_lambda_sendNotification
Hint:
When configuring cmtr_msdta2zd_lambda_reserveStock and cmtr_msdta2zd_lambda_sendNotification, make sure to forward the input payload:
"Parameters": {
  "Payload.$": "$"
}

Create a new GitHub or GitLab repository.

Commit and push the extracted Lambda functions code to the main branch.

The structure of your repository should be:
lambdas/
    cmtr_msdta2zd_lambda_createOrder/
        handler.py
    cmtr_msdta2zd_lambda_reserveStock/
        handler.py
    cmtr_msdta2zd_lambda_sendNotification/
        handler.py

Configure a CI/CD pipeline that automatically updates Lambda functions on every push to the main branch.

Configure repository secrets for AWS authentication. GitHub / GitLab variables: - AWS_REGION - AWS_ACCESS_KEY_ID - AWS_SECRET_ACCESS_KEY

Note: To obtain the required credentials, create a new IAM user with appropriate permissions to manage the AWS resources used in this task. Generate an access key for the user and use its credentials as the repository secret values above.

Create a deploy/access token with permission to push changes to the repository

Provide the deploy/access token for task verification.
## Verification
The task is considered successfully completed when every push to the main branch automatically triggers the CI/CD pipeline and deploys the updated Lambda functions.

The pipeline execution must complete successfully without errors.

API Gateway calls execute without errors and correctly trigger the associated Step Functions workflow by calling POST request to https://2m6np709bg.execute-api.eu-west-1.amazonaws.com/dev/order

Attention! After completing the task, delete the GitHub or GitLab access/deploy token that was created for this task.

## Deployment Time
It takes up to 3 minutes to deploy task resources.
