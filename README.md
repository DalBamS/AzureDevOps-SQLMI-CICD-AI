# AzureDevOps-SQLMI-CICD-AI

Azure DevOps를 활용해 **Azure SQL Managed Instance**의 데이터베이스 소스(스키마 · 메타데이터)를
자동으로 배포하고 버전을 관리하기 위한 프로젝트입니다.

## 빠른 시작

SQL 변경 브랜치를 GitHub에 push하고 `main` 대상 PR을 생성합니다.

```powershell
git push --set-upstream origin <branch-name>
```

GitHub에서 `main` 대상 PR을 생성하면 Azure DevOps가 Microsoft-hosted agent에서
DACPAC 빌드, 소스 정책 검사, AI PR 리뷰, 임시 SQL Server 컨테이너 통합 테스트를
수행합니다. 개발 PC에는 Docker Desktop이 필요하지 않습니다.

PR 병합 후 Azure DevOps에서 파이프라인을 수동 실행해 `deployDev`, `deployTest`,
`deployProd`를 선택하면 동일 DACPAC을 Dev → Stg → Live 데이터베이스로 순차 배포하고
각 환경에서 생성된 배포 SQL의 결정론적 안전 게이트와 스모크 테스트를 실행합니다.
Test와 Prod는 Azure DevOps Environment 승인을 통과해야 합니다.

반복 테스트 후 브랜치, 로컬 생성물, Demo DB를 초기화하는 절차는
[환경 구성 및 테스트 — 반복 테스트와 초기화](docs/환경-구성-및-테스트.md#36-반복-테스트와-초기화)를
참고합니다.

## 문서

- [프로젝트 계획 · 설계 초안](docs/프로젝트-계획-초안.md)
- [개발 환경 구성 및 테스트](docs/환경-구성-및-테스트.md)
- [Azure DevOps 설정](docs/Azure-DevOps-설정.md)

## 핵심 개념

- **SSDT(.sqlproj) → Git → Azure DevOps CI(DACPAC) → 다중 환경 CD → 운영 승인 게이트**
- **SSDT/DACPAC**(상태 기반 스키마 배포) + **BACPAC**(데이터 시딩/복원) 병행
- Redgate · Flyway · Liquibase · DbUp · GitHub Actions 등 대체/보완 도구 검토
- **AI 기반** 코드 리뷰 · 테스트 생성 · 배포 위험 분석으로 파이프라인 고도화

## Skeleton 구성

- `database/App.Database`: Microsoft.Build.Sql 2.2 기반 Azure SQL 프로젝트
- `tests/integration`: 스키마·메타데이터·저장 프로시저 스모크 테스트
- `eng`: 빌드, 정책 검사, hosted container 테스트, SQL MI 검증, BACPAC 도구
- `pipelines/profiles`: 연결 정보 없이 동일 안전 속성을 고정한 Dev/Test/Prod publish profile
- `azure-pipelines.yml`: build-once/deploy-many Azure Pipelines
- `ai/database-change-review.md`: AI 리뷰 가드레일과 JSON 출력 계약
- `eng/Invoke-AiDatabaseReview.ps1`: Azure OpenAI Responses API 기반 SQL 변경 리뷰
- `eng/Test-DeploymentScript.ps1`: 생성된 배포 SQL의 파괴 DDL, 동적 DDL, rename 검사