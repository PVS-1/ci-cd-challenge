# Task 2: S3 -> Lambda -> CodeBuild -> Lambda

Регіон Task 2: `eu-west-1`

Готові ресурси з CloudFormation:

- S3 bucket: `cmtr-msdta2zd-bucket-1789917057`
- Target Lambda: `cmtr-msdta2zd-lambda`
- Lambda execution role: `cmtr-msdta2zd-lambda-cf`

Ресурси, які створює `creds.ps1`:

- Trigger Lambda: `cmtr-msdta2zd-lambda-trigger`
- CodeBuild role: `cmtr-msdta2zd-cb`
- CodeBuild project: `cmtr-msdta2zd-cb-project`
- S3 event notification: `cmtr-msdta2zd-event-trigger`

## 1. Підготувати credentials

Не зберігай AWS credentials у файлах. Sandbox credentials тимчасові, тому перед роботою встанови свіжі значення у поточному PowerShell:

```powershell
$env:AWS_REGION = "eu-west-1"
$env:AWS_ACCESS_KEY_ID = "FRESH_ACCESS_KEY_ID"
$env:AWS_SECRET_ACCESS_KEY = "FRESH_SECRET_ACCESS_KEY"
$env:AWS_SESSION_TOKEN = "FRESH_SESSION_TOKEN"
```

Перевір авторизацію:

```powershell
aws sts get-caller-identity --query "{Account:Account,Arn:Arn}" --output json
```

Якщо бачиш `ExpiredToken`, отримай нові credentials у sandbox. Не запускай наступні кроки зі старим token.

## 2. Запустити конфігурацію ресурсів

Запусти PowerShell script із цієї папки:

```powershell
Set-Location "C:\Users\helper\OneDrive - Lizard Soft\AZURE\!!Devops_Repos\AWS Chalenges\AWS CI-CD\02 Automatic Lambda Functi02 on update with CodeBuild from S3"
powershell -ExecutionPolicy Bypass -File .\creds.ps1
```

Скрипт:

- пакує trigger Lambda;
- додає `codebuild:StartBuild` до Lambda role;
- створює або оновлює trigger Lambda з timeout 10 секунд;
- створює CodeBuild role з trust policy для `codebuild.amazonaws.com`;
- додає CodeBuild доступ до S3, CloudWatch Logs і target Lambda;
- створює або оновлює CodeBuild project;
- налаштовує S3 Event Notification для `.zip`;
- створює та завантажує `build.zip`.

## 3. Перевірити objectives 2-5

### Trigger Lambda

```powershell
aws lambda get-function `
  --function-name cmtr-msdta2zd-lambda-trigger `
  --region eu-west-1 `
  --query "Configuration.{Name:FunctionName,Timeout:Timeout,Role:Role,Handler:Handler,Runtime:Runtime}" `
  --output json
```

Очікується timeout `10` і runtime `python3.12`.

### CodeBuild project

```powershell
aws codebuild batch-get-projects `
  --names cmtr-msdta2zd-cb-project `
  --region eu-west-1 `
  --query "projects[].{Name:name,Role:serviceRole,Source:source.location,Status:status}" `
  --output json
```

Очікується source:

```text
cmtr-msdta2zd-bucket-1789917057/build.zip
```

### S3 Event Notification

```powershell
aws s3api get-bucket-notification-configuration `
  --bucket cmtr-msdta2zd-bucket-1789917057 `
  --region eu-west-1 `
  --output json
```

Очікується Lambda destination `cmtr-msdta2zd-lambda-trigger` та event `s3:ObjectCreated:*`.

### CodeBuild history

```powershell
aws codebuild list-builds-for-project `
  --project-name cmtr-msdta2zd-cb-project `
  --region eu-west-1 `
  --query "ids" `
  --output json
```

## 4. Запустити тестовий pipeline

Після успішної перевірки завантаж `build.zip` у S3:

```powershell
aws s3 cp `
  "..\ci-cd-challenge\02-Automatic-Lambda-update-CodeBuild-S3\build.zip" `
  "s3://cmtr-msdta2zd-bucket-1789917057/build.zip" `
  --region eu-west-1
```

Це запускає ланцюжок:

```text
S3 upload -> S3 Event Notification -> Trigger Lambda -> CodeBuild -> Target Lambda update
```

## 5. Перевірити результат build

Отримай останній build ID:

```powershell
$BuildId = aws codebuild list-builds-for-project `
  --project-name cmtr-msdta2zd-cb-project `
  --region eu-west-1 `
  --query "ids[0]" `
  --output text
```

Перевір статус:

```powershell
aws codebuild batch-get-builds `
  --ids $BuildId `
  --region eu-west-1 `
  --query "builds[0].{Status:buildStatus,Phase:currentPhase,Logs:logs.deepLink}" `
  --output json
```

Успішний результат:

```text
SUCCEEDED
```

Фактичний результат перевірки Task 2:

```json
{
  "Status": "SUCCEEDED",
  "Phase": "COMPLETED"
}
```

Перевір target Lambda:

```powershell
aws lambda get-function `
  --function-name cmtr-msdta2zd-lambda `
  --region eu-west-1 `
  --query "Configuration.{Name:FunctionName,LastModified:LastModified,CodeSize:CodeSize}" `
  --output json
```

Для функціональної перевірки виконай:

```powershell
aws lambda invoke `
  --function-name cmtr-msdta2zd-lambda `
  --region eu-west-1 `
  --payload '{}' `
  --cli-binary-format raw-in-base64-out `
  .\lambda-response.json

Get-Content .\lambda-response.json
```

Очікуваний результат:

```json
{"statusCode": 200, "body": "Hello from Lambda, updated version!"}
```

## Типові помилки

- `ExpiredToken`: sandbox credentials протерміновані; отримай нові всі три значення, включно з `AWS_SESSION_TOKEN`.
- `MalformedPolicyDocument`: policy-файл має бути UTF-8 без BOM; актуальний `creds.ps1` це враховує.
- `CodeBuild is not authorized to perform sts:AssumeRole`: перевір trust policy ролі `cmtr-msdta2zd-cb`; Principal має бути `codebuild.amazonaws.com`.
- `ResourceNotFoundException` на `list-builds-for-project`: CodeBuild project ще не створений. Спочатку онови sandbox credentials і повторно запусти `creds.ps1`, після успішного створення project повтори upload `build.zip`.
- `NoSuchBucket`: перевір назву bucket і регіон `eu-west-1`.
- `ResourceNotFoundException` для trigger Lambda: перевір, що objective 2 завершився і Lambda має назву `cmtr-msdta2zd-lambda-trigger`.
- Build не запускається: перевір S3 Event Notification і permission `lambda:InvokeFunction` для S3.
