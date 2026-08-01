# AzureDevOps-SQLMI-CICD-AI

Azure DevOps를 활용해 **Azure SQL Managed Instance**의 데이터베이스 소스(스키마 · 메타데이터)를
자동으로 배포하고 버전을 관리하기 위한 프로젝트입니다.

## 빠른 시작

```powershell
pwsh ./eng/Build.ps1
pwsh ./eng/Test-SqlPolicy.ps1
pwsh ./eng/Test-Database.ps1  # Docker Desktop 필요
```

빌드 결과는 `artifacts/dacpac/App.Database.dacpac`에 생성됩니다.

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
- `eng`: 로컬 빌드, 정책 검사, SQL Server 컨테이너 테스트, BACPAC 도구
- `azure-pipelines.yml`: build-once/deploy-many Azure Pipelines
- `ai/database-change-review.md`: AI 리뷰 가드레일과 JSON 출력 계약