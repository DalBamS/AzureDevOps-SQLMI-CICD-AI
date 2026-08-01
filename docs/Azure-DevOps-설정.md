# Azure DevOps 설정 가이드

## 데모 구성 예시

| 항목 | 구성 값 |
|---|---|
| Azure DevOps | `https://dev.azure.com/<organization>/<project>` |
| GitHub | `<owner>/<repository>` |
| Pipeline | `Azure SQL MI CI-CD` |
| Azure 연결 | `sc-sqlmi-wif` (Microsoft Entra issuer 기반 Workload Identity Federation) |
| 배포 주체 | `<deployer-principal-name>` |
| Demo SQL MI | `<sql-mi-name>`, public endpoint `3342` |
| Dev DB | `AppDb_CicdDemo_Dev` |
| Stg DB | `AppDb_CicdDemo_Stg` |
| Live DB | `AppDb_CicdDemo_Live` |
| Foundry | `<azure-openai-resource>`, `gpt-5.6-sol` |
| Agent pool | `sqlmi-private-agents` |

Demo는 한 SQL MI 안에서 데이터베이스를 분리해 Dev → Stg → Live 승격을 보여줍니다.
DBA 한 명이 Azure DevOps Environment 승인을 통해 순차 배포하는 전제입니다. 실제
운영에서는 장애 및 권한 경계를 위해 Live를 별도 SQL MI로 분리합니다.

Demo self-hosted agent를 개발 PC에서 실행할 수 있지만, 운영 전에는 SQL MI VNet 내부의 전용 VM 또는 Managed DevOps Pool로 교체하십시오.

SQL MI 시스템 ID에는 Entra principal 조회를 위해 Microsoft Graph의 `User.Read.All`, `GroupMember.Read.All`, `Application.Read.All` application permission을 부여했습니다. 이는 광범위한 `Directory Readers` 역할 대신 Microsoft가 안내하는 lower-level permission 조합을 사용한 것입니다.

## 1. 사전 준비

1. SQL MI와 통신 가능한 서브넷에 self-hosted Azure Pipelines agent를 배치합니다.
2. 에이전트에서 SQL MI의 FQDN과 포트로 DNS/네트워크 연결을 확인합니다.
3. Azure Resource Manager 서비스 연결을 Workload Identity Federation 방식으로 생성합니다.
4. 서비스 연결의 Entra 주체를 각 대상 데이터베이스에 사용자로 생성하고 최소 권한을 부여합니다.

예시 권한은 초기 구축용 기준입니다. 조직의 권한 분리 정책에 따라 사용자 지정 database role로 축소하십시오. `<deployer-principal-name>`은 Azure DevOps 서비스 연결이 사용하는 Entra 주체 이름으로 바꿉니다.

```sql
CREATE USER [<deployer-principal-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE [db_ddladmin] ADD MEMBER [<deployer-principal-name>];
ALTER ROLE [db_datareader] ADD MEMBER [<deployer-principal-name>];
ALTER ROLE [db_datawriter] ADD MEMBER [<deployer-principal-name>];
GRANT VIEW DEFINITION TO [<deployer-principal-name>];
```

## 2. Agent pool

`sqlmi-private-agents`라는 private agent pool을 만들거나 파이프라인 실행 시 `privateAgentPool` parameter에 실제 이름을 입력합니다.

에이전트 요구사항:

- PowerShell 7
- Azure CLI
- .NET 10 설치 가능 또는 사전 설치
- SqlServer PowerShell module 22.4.5.1 설치 가능
- NuGet 및 Microsoft artifact endpoint에 대한 outbound HTTPS
- 대상 SQL MI endpoint/FQDN 접근

## 3. Environment와 승인

다음 Azure DevOps Environments를 생성합니다.

| Environment | 권장 검사 |
|---|---|
| `sqlmi-dev` | 자동 배포 허용 |
| `sqlmi-test` | QA 또는 DBA 승인 |
| `sqlmi-prod` | DBA + 서비스 책임자 승인, 업무 시간/변경 티켓 검사 |

승인은 YAML에 두지 않고 Environment의 **Approvals and checks**에서 관리해야 파이프라인 변경으로 우회하기 어렵습니다.
Test와 Prod에는 수동 Approval check가 구성되어 있습니다. 운영 전 각 Environment에 **Exclusive lock** 검사도 추가합니다. YAML의 `lockBehavior: sequential`과 함께 동시 배포를 직렬화합니다.

## 4. Variable group

Library의 variable group은 다음 Demo 대상으로 구성합니다.

| Variable group | `sqlServer` | `sqlPort` | `databaseName` |
|---|---|---:|---|
| `sqlmi-dev` | `<sql-mi-public-fqdn>` | 3342 | `AppDb_CicdDemo_Dev` |
| `sqlmi-test` | 동일 | 3342 | `AppDb_CicdDemo_Stg` |
| `sqlmi-prod` | 동일 | 3342 | `AppDb_CicdDemo_Live` |

서비스 연결 이름은 variable group이 아니라 파이프라인의 compile-time `azureServiceConnection` parameter로 전달합니다. Azure Pipelines가 실행 전에 서비스 연결 권한을 검증하기 때문입니다.

암호는 필요하지 않습니다. `AzureCLI@2`가 서비스 연결으로 로그인하고 Azure SQL access token을 발급합니다. SQL 인증이 불가피한 레거시 환경은 Key Vault-linked variable group을 별도로 사용하십시오.

## 5. Pipeline 생성

1. PR을 생성하면 Azure hosted agent가 빌드, 정책, AI 리뷰, 컨테이너 통합 테스트를 실행합니다.
2. PR 병합 후 Demo SQL MI를 시작합니다.
3. Azure DevOps에서 파이프라인을 수동 실행하고 세 deploy parameter를 모두 `true`로 설정합니다.
4. Dev는 자동 배포와 SQL MI 스모크 테스트를 수행합니다.
5. Test 승인 후 Stg DB를 배포하고 동일 테스트를 실행합니다.
6. Prod 승인 후 Live DB를 배포하고 동일 테스트를 실행합니다.

각 환경은 동일한 `database` DACPAC artifact를 사용합니다. 이전 환경이 실패하거나 승인되지 않으면 후속 환경으로 진행하지 않습니다.

Demo 데이터베이스 최초 구성:

```powershell
$resourceGroup = '<sql-mi-resource-group>'
$managedInstance = '<sql-mi-name>'
$sqlServer = '<sql-mi-public-fqdn>'
$deployerPrincipal = '<deployer-principal-name>'

az sql mi start -g $resourceGroup --mi $managedInstance
$token = az account get-access-token `
  --resource 'https://database.windows.net/' `
  --query accessToken `
  --output tsv

& ./eng/Initialize-DemoDatabases.ps1 `
  -ServerName $sqlServer `
  -Port 3342 `
  -DatabaseName @('AppDb_CicdDemo_Dev', 'AppDb_CicdDemo_Stg', 'AppDb_CicdDemo_Live') `
  -DeployerPrincipalName $deployerPrincipal `
  -AccessToken $token
```

SQL MI 시작에는 일반적으로 수 분 이상 걸리며 `az sql mi start`가 완료된 후 초기화
스크립트를 실행합니다.

Demo가 끝나면 비용 절감을 위해 인스턴스를 중지합니다.

```powershell
az sql mi stop -g $resourceGroup --mi $managedInstance
```

Azure Repos를 사용하는 경우 YAML의 `pr` 선언만으로 검증이 강제되지 않으므로 `main` 브랜치의 **Build validation** 정책에 이 파이프라인을 Required로 연결합니다. 현재 구성은 GitHub 저장소를 사용하므로 GitHub branch protection에서 Azure Pipelines 상태 검사를 Required로 설정합니다.

## 6. 배포 안전장치

각 환경의 `Plan*` stage는 승인 전에 다음 artifact를 생성합니다.

- `deploy.sql`: 실제 실행 예정 SQL
- `deploy-report.xml`: DacFx 변경 계획

공통 게시 옵션:

```text
BlockOnPossibleDataLoss=True
DropObjectsNotInSource=False
ScriptDatabaseOptions=False
```

승인자는 대기 중인 `Deploy*` stage를 승인하기 전에 완료된 `Plan*` stage의 artifact를 검토합니다. 초기 도입 기간에는 Dev 자동 배포만 허용하고 Test/Prod에서 `deploy.sql`을 DBA가 승인하도록 운영합니다. `DropObjectsNotInSource=False`로 인해 제거가 자동 반영되지 않으므로, 승인된 제거는 별도 expand/contract 절차와 명시적 스크립트로 처리합니다.

승인 이후 배포 직전에 DeployReport를 다시 생성해 승인된 보고서와 비교합니다. 대상 DB에 드리프트가 생기면 배포를 중단하고 새 계획과 승인을 요구합니다.
배포가 완료되면 `Test-DeployedDatabase.ps1`이 실제 대상 DB에서 스키마, 메타데이터,
seed data, 저장 프로시저 동작을 검증합니다.

## 7. AI 품질 게이트

`eng/Invoke-AiDatabaseReview.ps1`은 `ai/database-change-review.md`의 가드레일과
JSON Schema를 사용해 Azure OpenAI Responses API를 호출합니다.

- PR 검증: `database/App.Database`와 `tests/integration`의 변경 diff 검토
- 배포 계획: 환경별로 생성된 `deploy.sql` 검토
- 결과: JSON artifact와 Azure Pipelines 실행 요약용 Markdown

2026년 8월 기준 기본 권장 모델은 `gpt-5.6-sol`입니다. 비용을 낮춘 PR 대량 검토에는
`gpt-5.4-mini`를 사용할 수 있습니다. 모델 제공 지역과 할당량은 Foundry에서 확인하고,
모델 배포 이름은 예를 들어 `sql-review`로 지정합니다.

- [Azure OpenAI Responses API와 지원 모델](https://learn.microsoft.com/azure/foundry/openai/how-to/responses)
- [Foundry에서 Azure가 제공하는 모델](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure)

AI 리뷰를 사용할 때 파이프라인 실행 parameter에 환경별 값을 전달합니다. 저장소의 기본값은 개인 리소스 노출과 잘못된 환경 호출을 막기 위해 비활성화되어 있습니다.

| Parameter | 예시 |
|---|---|
| `enableAiReview` | `true` |
| `aiEndpoint` | `https://<azure-openai-resource>.openai.azure.com/openai/v1/` |
| `aiDeploymentName` | `gpt-5.6-sol` |
| `publishAiPrComment` | `true` |
| `githubServiceConnection` | `<github-service-connection>` |

`sc-sqlmi-wif` 서비스 연결의 Entra 주체에 Azure OpenAI 리소스 범위의
**Cognitive Services OpenAI User** 역할을 부여합니다. 파이프라인은
`https://ai.azure.com/.default` scope의 토큰을 사용하므로 API key를 저장할 필요가 없습니다.
PR 코멘트가 필요하면 Azure DevOps의 GitHub 서비스 연결을 지정하고
`publishAiPrComment=true`로 실행합니다. 이 옵션을 사용하지 않아도 JSON artifact와
파이프라인 실행 요약은 게시됩니다.

권장 순서:

1. deterministic SQL policy
2. DACPAC build
3. 컨테이너 integration test
4. AI 위험 분석
5. 사람 승인
6. SQL MI publish

AI 결과는 초기에는 advisory로만 게시하며 LLM 호출 실패도 `SucceededWithIssues`로 표시합니다.
충분한 정밀도와 오탐 기준을 확보한 후 `-FailOnBlockingFindings`를 사용해
`blockingFindings`가 있을 때만 배포를 차단합니다. SQL 본문에 운영 데이터나 connection
string을 포함하지 않으며, 승인된 Azure OpenAI 리소스만 사용합니다.

## 8. 운영 점검

- Azure DevOps artifact retention을 감사 기간에 맞게 설정합니다.
- SQL MI의 감사 로그와 Azure DevOps deployment record를 동일 변경 티켓으로 연결합니다.
- 운영 DB의 수동 DDL을 금지하고 정기적으로 DACPAC drift report를 생성합니다.
- 실패 시 동일 DACPAC 재시도 또는 사전 승인된 롤백 스크립트를 사용합니다. BACPAC import를 일반적인 롤백 수단으로 사용하지 않습니다.
