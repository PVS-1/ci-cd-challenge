# Serverless CI/CD for Event-Driven Architectures

## Що виконує рішення

- Завантажує `lambdas.zip` з pre-created S3 bucket і формує required repository layout.
- Налаштовує Step Functions workflow: `createOrder` -> `reserveStock` -> `sendNotification`.
- Передає поточний payload між Lambda tasks через `"Payload.$": "$"`.
- Створює GitHub repository за потреби.
- Створює GitHub Actions workflow, який на кожен push у `main` пакує та оновлює усі три Lambda functions.
- Створює окремий IAM user `cmtr-msdta2zd-github-deployer` з правами лише на оновлення трьох Lambda functions, ротує його access key та записує key/secret/region у GitHub Secrets.

## Запуск

У PowerShell із валідними AWS credentials для lab виконай:

```powershell
Set-Location "C:\Users\helper\OneDrive - Lizard Soft\AZURE\!!Devops_Repos\AWS Chalenges\AWS CI-CD\09-Serverless CI-CD for Event-Driven Architectures with GitHub"

.\01-bootstrap-source.ps1
.\02-configure-state-machine.ps1
```

Увійди до GitHub CLI лише один раз:

```powershell
gh auth login
```

Потім створи repo, workflow, IAM deploy credentials та перший push. Замінити `<owner>/<repository>` на GitHub repository path:

```powershell
.\03-create-github-pipeline.ps1 -Repository "<owner>/cmtr-msdta2zd-serverless-cicd"
```

Перший push запускає GitHub Actions workflow. Його статус можна перевірити так:

```powershell
gh run list --repo "<owner>/cmtr-msdta2zd-serverless-cicd"
```

## Для lab verifier

Task вимагає окремий GitHub deploy/access token. Створи fine-grained personal access token із доступом до створеного repository та передай його verifier, але не записуй token у файл, git history або GitHub Actions secrets. Після успішної верифікації видали цей token.

## Перевірка API

```powershell
curl.exe -X POST "https://2m6np709bg.execute-api.eu-west-1.amazonaws.com/dev/order" `
  -H "Content-Type: application/json" `
  -d "{\"orderId\":\"order-001\",\"productId\":\"product-001\",\"quantity\":1}"
```

AWS credentials і GitHub tokens не зберігаються в цьому repository.
