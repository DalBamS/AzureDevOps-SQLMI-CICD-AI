# AzureDevOps-SQLMI-CICD-AI

Azure DevOps를 활용해 **Azure SQL Managed Instance**의 데이터베이스 소스(스키마 · 메타데이터)를
자동으로 배포하고 버전을 관리하기 위한 프로젝트입니다.

## 빠른 시작

SQL 변경 브랜치를 GitHub에 push하고 `main` 대상 PR을 생성합니다.

```powershell
git push --set-upstream origin <branch-name>
```

GitHub에서 `main` 대상 PR을 생성하면 Azure DevOps가 Microsoft-hosted agent에서
DACPAC 빌드, 소스 정책 검사, 임시 SQL Server 컨테이너 통합 테스트를 수행합니다.
`enableAiReview=true`일 때만 청크 단위 AI PR 리뷰를 추가합니다. 개발 PC에는 Docker
Desktop이 필요하지 않습니다.

PR 병합 후 Azure DevOps에서 파이프라인을 수동 실행해 `deployDev`, `deployTest`,
`deployProd`를 선택하면 동일 DACPAC을 Dev → Stg → Live 환경으로 순차 승격합니다.
각 환경은 `databaseNames`의 첫 DB를 카나리로 배포·검증한 뒤 나머지 DB를 제한 병렬
배포하며, 기존 단일 `databaseName` 구성도 그대로 지원합니다.
Test와 Prod는 Azure DevOps Environment 승인을 통과해야 합니다.

반복 테스트 후 브랜치, 로컬 생성물, Demo DB를 초기화하는 절차는
[환경 구성 및 테스트 — 반복 테스트와 초기화](docs/환경-구성-및-테스트.md#37-반복-테스트와-초기화)를
참고합니다.

## 문서

- [프로젝트 계획 · 설계 초안](docs/프로젝트-계획-초안.md)
- [개발 환경 구성 및 테스트](docs/환경-구성-및-테스트.md)
- [SQL 통합 테스트 규약](tests/README.md)
- [Phase 4 의도적 실패 실습 랩](docs/실습-랩.md)
- [Azure DevOps 설정](docs/Azure-DevOps-설정.md)
- [SQL MI 배포 롤백 런북](docs/롤백-런북.md)

## 핵심 개념

- **SSDT(.sqlproj) → Git → Azure DevOps CI(DACPAC) → 다중 환경 CD → 운영 승인 게이트**
- **SSDT/DACPAC**(상태 기반 스키마 배포) + **BACPAC**(논리적 데이터 이동/시딩) 병행
- Redgate · Flyway · Liquibase · DbUp · GitHub Actions 등 대체/보완 도구 검토
- **AI 기반** PR 코드 리뷰 · 배포 스크립트 위험 분석으로 파이프라인 보강

## Skeleton 구성

- `database/App.Database`: Microsoft.Build.Sql 2.2 기반 Azure SQL 프로젝트
- `database/instance`: DACPAC 밖에서 파일명 순서로 실행하는 멱등 SQL MI 인스턴스 오브젝트
- `tests/integration`: 스키마·메타데이터·저장 프로시저 스모크 테스트
- `labs`: Phase 4 의도적 실패 SQL, report, allowlist, AI 응답 fixture
- `eng`: 빌드, 정책 검사, hosted container 테스트, SQL MI 검증, BACPAC 도구
- `pipelines/profiles`: 연결 정보 없이 동일 안전 속성을 고정한 Dev/Test/Prod publish profile
- `azure-pipelines.yml`: build-once/deploy-many Azure Pipelines
- `ai/database-change-review.md`: AI 리뷰 가드레일과 JSON 출력 계약
- `eng/Invoke-AiDatabaseReview.ps1`: Azure OpenAI Responses API 기반 SQL 변경 리뷰
- `eng/Test-AiDatabaseReview.ps1`: 네트워크 없는 AI 청크·병합·비밀 탐지 회귀
- `eng/Test-DeploymentScript.ps1`: 생성된 배포 SQL의 파괴 DDL, 동적 DDL, rename 검사
- `eng/SqlCmd.Common.psm1`: SQLCMD 변환, lexical GO 분리, SQL token·instance guard 공용 parser
- `eng/Test-FailureLabs.ps1`: Lab B~D 오프라인 차단과 선택적 Lab A Docker 회귀
- `eng/Deploy-Databases.ps1`: 카나리, 제한 병렬 fan-out, 실패 집계와 재시도 안전 배포
- `eng/Invoke-ValidatedDeploymentScript.ps1`: 검증한 sanitized SQL을 2차 SQLCMD 해석 없이 exact 실행
- `eng/Deploy-InstanceObjects.ps1`: Entra token/SQLCMD 변수 기반 인스턴스 오브젝트 배포
- `pipelines/drift-report.yml`: 매일 02:00 UTC 대표 DB에 읽기 전용 DeployReport 실행