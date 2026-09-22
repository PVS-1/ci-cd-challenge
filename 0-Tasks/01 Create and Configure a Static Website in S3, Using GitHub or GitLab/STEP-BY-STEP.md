# GitHub налаштування

Репозиторій: https://github.com/PVS-1/ci-cd-challenge

## 1. Створити S3 bucket через AWS Console

1. Відкрий AWS Console -> **S3** -> **Create bucket**.
2. У **AWS Region** вибери `eu-central-1`.
3. У **Bucket name** введи:

   `cmtr-msdta2zd-bucket-1789851561`

4. У **Object Ownership** залиш `ACLs disabled`.
5. У **Block Public Access settings** зніми прапорець **Block all public access**.
6. Підтвердь попередження про відкритий доступ.
7. Інші параметри залиш типовими.
8. Натисни **Create bucket**.

Якщо AWS покаже помилку `explicit deny in a service control policy` для `s3:CreateBucket`, створення заборонене політикою sandbox на рівні AWS Organization. Через UI це не виправляється: попроси адміністратора sandbox дозволити S3 або надати готовий bucket.

## 2. Увімкнути Static website hosting

1. Відкрий створений bucket -> вкладка **Properties**.
2. Знайди **Static website hosting** -> **Edit**.
3. Увімкни **Static website hosting**.
4. Вибери **Host a static website**.
5. У **Index document** введи `index.html`.
6. У **Error document** введи `error.html`.
7. Натисни **Save changes**.
8. Скопіюй **Bucket website endpoint** для фінальної перевірки.

## 3. Додати public-read bucket policy

У bucket відкрий **Permissions** -> **Bucket policy** -> **Edit** і встав JSON. Заміни `YOUR_BUCKET_NAME` на `cmtr-msdta2zd-bucket-1789851561`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadForWebsite",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::cmtr-msdta2zd-bucket-1789851561/*"
    }
  ]
}
```

Натисни **Save changes**.

Якщо bucket не створився, не переходь до цих кроків: помилки `NoSuchBucket` означають, що bucket відсутній.

## 4. Створити IAM user для GitHub Actions

1. В AWS Console відкрий **IAM** -> **Users** -> **Create user**.
2. У **User name** введи `github-s3-deployer`.
3. Console access не вмикай.
4. Створи user без додавання AWS managed policies.
5. Відкрий створений user -> **Permissions** -> **Add permissions** -> **Create inline policy**.
6. Вибери вкладку **JSON** і встав:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListWebsiteBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::cmtr-msdta2zd-bucket-1789851561"
    },
    {
      "Sid": "ManageWebsiteFiles",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::cmtr-msdta2zd-bucket-1789851561/*"
    }
  ]
}
```

7. Натисни **Next** -> **Create policy**.
8. Назви policy `GitHubDeployToS3`.
9. Відкрий user -> **Security credentials** -> **Access keys** -> **Create access key**.
10. Вибери сценарій для application running outside AWS і створи access key.
11. Збережи `Access key ID` і `Secret access key` у password manager. Secret key показується лише один раз.

Не вставляй ці ключі у файли, Git commits або чат. Вони будуть додані до GitHub Secrets на наступному кроці.

## 5. Клонувати репозиторій

У PowerShell виконай:

```powershell
git clone https://github.com/PVS-1/ci-cd-challenge.git
Set-Location .\ci-cd-challenge
git remote -v
```

Перевір, що `origin` вказує на `https://github.com/PVS-1/ci-cd-challenge.git`.

## 6. Створити GitHub token

1. Відкрий GitHub -> Profile -> Settings.
2. Відкрий Developer settings -> Personal access tokens -> Fine-grained tokens.
3. Натисни Generate new token.
4. Назва: `s3-static-website-task`.
5. Встанови термін дії 7 або 30 днів.
6. Repository access: Only selected repositories -> `ci-cd-challenge`.
7. Repository permissions: `Contents` -> `Read and write`.
8. Натисни Generate token і збережи token у password manager.

Не записуй token у файли, workflow або чат. GitHub покаже його лише один раз.

## 7. Додати файли сайту

У корені репозиторію створи `index.html` та `error.html`.

Мінімальний `index.html`:

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Static website</title>
</head>
<body>
  <h1>Hello from GitHub Actions</h1>
</body>
</html>
```

Потім виконай:

```powershell
git add index.html error.html
git commit -m "Add static website"
git push origin main
```

Якщо Git попросить пароль, введи GitHub token замість пароля від облікового запису.

## 8. Додати secrets у репозиторії

У GitHub відкрий:

`Settings -> Secrets and variables -> Actions -> New repository secret`

Створи secrets:

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | Готовий AWS access key ID |
| `AWS_SECRET_ACCESS_KEY` | Готовий AWS secret access key |
| `AWS_REGION` | Регіон, наприклад `eu-central-1` |
| `S3_BUCKET_NAME` | Назва bucket |

## 9. Додати GitHub Actions workflow

У локальному репозиторії створи файл `.github/workflows/deploy.yml`:

```yaml
name: Deploy static website

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Deploy files
        run: aws s3 sync . s3://${{ secrets.S3_BUCKET_NAME }} --delete --exclude ".git/*" --exclude ".github/*"
```

Відправ workflow у GitHub:

```powershell
git add .github/workflows/deploy.yml
git commit -m "Add GitHub Actions workflow"
git push origin main
```

## 10. Перевірити GitHub Actions

1. Відкрий https://github.com/PVS-1/ci-cd-challenge.
2. Відкрий **Settings** -> **Secrets and variables** -> **Actions**.
3. Переконайся, що створені secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` і `S3_BUCKET_NAME`.
4. Відкрий вкладку **Actions**.
5. Вибери workflow **Deploy static website**.
6. Для ручного запуску натисни **Run workflow** -> branch `main` -> **Run workflow**.
7. Відкрий новий запуск і перевір job `deploy`.
8. Переконайся, що всі кроки завершилися зеленим статусом.

Workflow також запускається автоматично після кожного `git push origin main`.

Якщо workflow не запускається, перевір:

- файл має шлях `.github/workflows/deploy.yml`;
- push виконаний у гілку `main`;
- усі чотири secrets створені без помилок у назвах.

## 11. Виправити помилку недійсного AWS token

Якщо job падає на `configure-aws-credentials` з помилкою `The security token included in the request is invalid`:

1. В AWS IAM відкрий user `github-s3-deployer` -> **Security credentials**.
2. Створи новий access key. Якщо досягнуто ліміту у 2 ключі, видали старий недійсний ключ.
3. У GitHub відкрий **Settings** -> **Secrets and variables** -> **Actions**.
4. Онови `AWS_ACCESS_KEY_ID` новим Access key ID.
5. Онови `AWS_SECRET_ACCESS_KEY` новим Secret access key.
6. Перевір, що у значеннях немає пробілів, лапок або переносів рядка.
7. Не використовуй у GitHub Secrets тимчасові credentials sandbox (`ASIA...`) без окремого `AWS_SESSION_TOKEN`. Для pipeline використовуй access key IAM user (`AKIA...`).
8. У GitHub відкрий невдалий запуск -> **Re-run jobs**.

Warning про Node 20 не є причиною цієї помилки. Не додавай `ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION=true`.

## 12. Видалити token після завершення

GitHub -> Settings -> Developer settings -> Personal access tokens -> видали `s3-static-website-task`.
