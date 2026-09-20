# Task 3: GitHub -> Flask -> Elastic Beanstalk

Усі команди нижче призначені для **Bash / Git Bash / WSL / Linux shell**, не для PowerShell.

Регіон: `eu-west-1`

Ресурси challenge:

- Elastic Beanstalk application: `cmtr-msdta2zd-app`
- Elastic Beanstalk environment: `cmtr-msdta2zd-env`
- VPC: `cmtr-msdta2zd-vpc`

## 1. Підготувати AWS CLI credentials

Встав свіжі sandbox credentials прямо у Bash-термінал. Не записуй їх у цей файл:

```bash
export AWS_REGION="eu-west-1"
export AWS_ACCESS_KEY_ID="FRESH_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="FRESH_SECRET_ACCESS_KEY"
export AWS_SESSION_TOKEN="FRESH_SESSION_TOKEN"
```

Перевір авторизацію:

```bash
aws sts get-caller-identity \
  --query '{Account:Account,Arn:Arn}' \
  --output json
```

Якщо бачиш `ExpiredToken`, отримай нові sandbox credentials. Тимчасові credentials потребують усі три значення: access key, secret key і session token.

## Objective 1. Створити Elastic Beanstalk environment

У цьому account application і environment ще не існували. Скрипт сам знайде актуальну Python platform і створить усі залежності objective 1.

Запусти один файл:

```bash
bash ./01-create-environment.sh
```

Важливо: скопіюй у CloudShell **весь файл від першого рядка `#!/usr/bin/env bash` до останнього рядка**. Не запускай окремий фрагмент із середини. Змінні `SERVICE_ROLE_NAME`, `INSTANCE_PROFILE_NAME` і `TEMP_DIR` оголошуються на початку файла.

Наприклад, у CloudShell:

```bash
nano 01-create-environment.sh
```

Встав увесь вміст файла, збережи `Ctrl+O`, натисни Enter, вийди `Ctrl+X`, потім виконай:

```bash
chmod +x 01-create-environment.sh
bash ./01-create-environment.sh
```

Скрипт idempotent: roles, application і environment створюються тільки якщо їх ще немає.

Успішний результат environment матиме статус `Launching`, `Updating` або після завершення `Ready`.

Для локального Windows PowerShell використовуй один файл:

```powershell
Set-Location "C:\Users\helper\OneDrive - Lizard Soft\AZURE\!!Devops_Repos\AWS Chalenges\AWS CI-CD\ci-cd-challenge\03-Deploy-Application-with-Elastic-Beanstalk-GitHub"
powershell -ExecutionPolicy Bypass -File .\01-create-environment.ps1
```

Цей PowerShell-файл самодостатній і не викликає Bash або інші локальні скрипти.

## 2. Перевірити Elastic Beanstalk resources

Після завершення objective 1 виконай запити окремо:

```bash
aws elasticbeanstalk describe-applications \
  --application-names cmtr-msdta2zd-app \
  --region eu-west-1 \
  --query 'Applications[].{Name:ApplicationName,DateCreated:DateCreated,DateUpdated:DateUpdated}' \
  --output json
```

```bash
aws elasticbeanstalk describe-environments \
  --application-name cmtr-msdta2zd-app \
  --environment-names cmtr-msdta2zd-env \
  --region eu-west-1 \
  --query 'Environments[].{Name:EnvironmentName,Status:Status,Health:Health,CNAME:CNAME,Version:VersionLabel}' \
  --output json
```

Очікується environment `cmtr-msdta2zd-env` зі статусом `Ready`.

Отримати endpoint:

```bash
CNAME="$(aws elasticbeanstalk describe-environments \
  --application-name cmtr-msdta2zd-app \
  --environment-names cmtr-msdta2zd-env \
  --region eu-west-1 \
  --query 'Environments[0].CNAME' \
  --output text)"

echo "http://$CNAME"
```

## 3. Flask application

Структура репозиторію для Elastic Beanstalk:

```text
ci-cd-challenge/
├── application.py
├── requirements.txt
└── .github/workflows/03-deploy-elastic-beanstalk.yml
```

Документація і Objective 1 script залишаються в `03-Deploy-Application-with-Elastic-Beanstalk-GitHub/`.

`application.py` повертає:

```text
Hello from msdta2zd Elastic Beanstalk CI-CD
```

Якщо challenge покаже інший `custom_identifier`, зміни рядок у `application.py` перед push.

## 4. Локально перевірити Flask

```bash
cd "/c/Users/helper/OneDrive - Lizard Soft/AZURE/!!Devops_Repos/AWS Chalenges/AWS CI-CD/ci-cd-challenge/03-Deploy-Application-with-Elastic-Beanstalk-GitHub"
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r requirements.txt
export FLASK_APP="application:application"
flask run
```

В іншому Bash-терміналі:

```bash
curl http://127.0.0.1:5000
```

Очікується:

```text
Hello from msdta2zd Elastic Beanstalk CI-CD
```

## 5. GitHub token і push

GitHub fine-grained token повинен мати:

```text
Repository access: ci-cd-challenge
Contents: Read and write
```

Із кореня repository:

```bash
cd "/c/Users/helper/OneDrive - Lizard Soft/AZURE/!!Devops_Repos/AWS Chalenges/AWS CI-CD/ci-cd-challenge"
git add 03-Deploy-Application-with-Elastic-Beanstalk-GitHub .github/workflows/03-deploy-elastic-beanstalk.yml
git commit -m "Add Elastic Beanstalk Flask deployment"
git push origin main
```

Не додавай GitHub token у URL, файли або workflow.

## 6. GitHub Actions secrets

У GitHub відкрий:

`Settings -> Secrets and variables -> Actions -> New repository secret`

Додай:

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | AWS access key для pipeline |
| `AWS_SECRET_ACCESS_KEY` | AWS secret access key для pipeline |

Workflow використовує:

- application: `cmtr-msdta2zd-app`;
- environment: `cmtr-msdta2zd-env`;
- region: `eu-west-1`.

Для тимчасових sandbox credentials GitHub Actions також потребує session token. Надійніший варіант для pipeline - AWS credentials, які не протермінуються під час job і дозволені політикою challenge.

## 7. Запустити deployment

Після push:

1. GitHub repository -> **Actions**.
2. Відкрий **Deploy Flask to Elastic Beanstalk**.
3. Відкрий job `deploy`.
4. Перевір, що всі кроки зелені.

Workflow також можна запустити через **Run workflow**.

## 8. Перевірити deployed endpoint

```bash
CNAME="$(aws elasticbeanstalk describe-environments \
  --application-name cmtr-msdta2zd-app \
  --environment-names cmtr-msdta2zd-env \
  --region eu-west-1 \
  --query 'Environments[0].CNAME' \
  --output text)"

curl --fail --show-error "http://$CNAME"
```

Очікується HTTP `200` і текст:

```text
Hello from msdta2zd Elastic Beanstalk CI-CD
```

## Типові помилки

- `ExpiredToken`: онови `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` і `AWS_SESSION_TOKEN` у поточному Bash.
- `Environment does not exist`: перевір `cmtr-msdta2zd-env` і регіон `eu-west-1`.
- `AccessDenied`: credentials не мають дозволів для Elastic Beanstalk deployment.
- HTTP `5xx`: перевір Elastic Beanstalk logs і startup Flask application.

Після завершення challenge відклич GitHub token у GitHub Settings -> Developer settings -> Personal access tokens.
