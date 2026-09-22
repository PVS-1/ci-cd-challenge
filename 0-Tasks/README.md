# AWS CI/CD Tasks

Колекція навчальних задач з AWS CI/CD, serverless deployment, container delivery,
Terraform, blue/green deployment, DNS failover та monitoring/rollback.

> **Security rule:** ніколи не зберігайте AWS credentials, session tokens, GitHub/GitLab PATs або password-bearing URLs у файлах чи git history. Для виконання задач використовуйте shell environment, GitHub/GitLab secrets або masked pipeline variables. Після lab відкликайте тимчасові tokens.

## Task map

| Task | Topic | Main services | Documentation |
| --- | --- | --- | --- |
| 01 | Static website | S3, GitHub/GitLab CI | `goal`, `STEP-BY-STEP.md` |
| 02 | S3-triggered Lambda update | S3, Lambda, CodeBuild | `README.md`, `goal` |
| 03 | Elastic Beanstalk deployment | Elastic Beanstalk, GitHub | `goal.md` |
| 04 | Terraform CI/CD | S3, Terraform, GitHub/GitLab | `goal.md` |
| 05 | Blue/green EC2 deployment | CodeDeploy, ALB, ASG | `goal.md` |
| 06 | Container deployment | ECR, ECS/Fargate, GitLab CI | `goal.md`, `gitlab-project/README.md` |
| 07 | Private DNS failover | Route 53, CodeCommit, CodeBuild | `README.md`, `goal.md` |
| 08 | Multi-region blue/green | ECR, CodePipeline, CodeDeploy, Route 53 | `README.md`, `goal.md` |
| 09 | Event-driven serverless CI/CD | Lambda, Step Functions, API Gateway, DynamoDB | `README.md`, `goal.md` |
| 10 | Monitoring and rollback | CodePipeline, CodeBuild, CodeDeploy, ALB, CloudWatch | `README.md`, `goal.md` |

## How to use a task folder

1. Read `goal.md` or the task README first.
2. Check the listed pre-created resources and required region.
3. Run scripts in the documented order.
4. Keep credentials outside the repository.
5. Run the verification commands and capture only non-secret evidence.
6. Revoke temporary GitHub/GitLab tokens after verification.

## Documentation conventions

- `goal.md` describes the assignment, resources, objectives and acceptance criteria.
- `README.md` describes implementation details, commands and troubleshooting.
- Scripts are task-specific and should not be treated as reusable production automation without review.
- Placeholders such as `<AWS_ACCOUNT_ID>`, `<OWNER>/<REPOSITORY>` and `<TOKEN>` are documentation values, not credentials.

## Secret cleanup status

The task tree was scanned for high-confidence credential patterns. Exposed credential-bearing URLs and token values were removed from the working files. Remaining occurrences of words such as `token`, `secret`, `password` and `AWS_ACCESS_KEY_ID` are instructional references, environment variable names, secret references, or safe placeholders.
