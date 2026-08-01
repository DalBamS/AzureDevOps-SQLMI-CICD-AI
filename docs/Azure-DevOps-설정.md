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

1. SQL MI와 통신 가능한 네트워크에 self-hosted Azure Pipelines agent를 배치합니다.
2. 같은 VNet, peered VNet 또는 VPN/ExpressRoute 연결망에서는 기본 VNet-local endpoint와
   1433 포트를 사용합니다. 다른 VNet에 고정 IP를 노출해야 할 때는 선택적 private
   endpoint와 1433 포트를 사용합니다. Demo처럼 public endpoint를 명시적으로 활성화한
   경우에만 public FQDN과 3342 포트를 사용합니다.
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

| Variable group | `sqlServer` | `sqlPort` | `databaseName` | `databaseNames` |
|---|---|---:|---|---|
| `sqlmi-dev` | `<sql-mi-public-fqdn>` | 3342 | `AppDb_CicdDemo_Dev` | 선택: `AppDb_Dev_01,AppDb_Dev_02` |
| `sqlmi-test` | 동일 | 3342 | `AppDb_CicdDemo_Stg` | 선택: 쉼표 구분 목록 |
| `sqlmi-prod` | 동일 | 3342 | `AppDb_CicdDemo_Live` | 선택: 쉼표 구분 목록 |

`databaseNames`가 비어 있거나 정의되지 않으면 기존 `databaseName`을 사용합니다. 목록
첫 항목은 대표 Plan 및 카나리 DB이므로 의도한 대표 샤드를 먼저 둡니다. 중복은 대소문자
구분 없이 제거됩니다. 인스턴스 오브젝트를 활성화할 variable group에는 다음 비밀이 아닌
값도 추가합니다.

| 변수 | 의미 |
|---|---|
| `instanceEntraLoginName` | 생성할 Microsoft Entra login 이름 |
| `instanceAgentJobName` | 생성/갱신할 SQL Agent job 이름 |
| `instanceAgentJobOwner` | 이미 존재하는 job owner login |

서비스 연결 이름은 variable group이 아니라 파이프라인의 compile-time `azureServiceConnection` parameter로 전달합니다. Azure Pipelines가 실행 전에 서비스 연결 권한을 검증하기 때문입니다.

암호는 필요하지 않습니다. `AzureCLI@2`가 서비스 연결으로 로그인하고 Azure SQL access token을 발급합니다. SQL 인증이 불가피한 레거시 환경은 Key Vault-linked variable group을 별도로 사용하십시오.

## 5. Pipeline 생성

1. PR을 생성하면 Azure hosted agent가 빌드, 정책, 컨테이너 통합 테스트를 실행합니다.
   `enableAiReview=true`일 때만 advisory AI 리뷰를 추가합니다.
2. PR 병합 후 Demo SQL MI를 시작합니다.
3. Azure DevOps에서 파이프라인을 수동 실행하고 세 deploy parameter를 모두 `true`로 설정합니다.
4. Dev는 자동 배포와 SQL MI 스모크 테스트를 수행합니다.
5. Test 승인 후 Stg DB를 배포하고 동일 테스트를 실행합니다.
6. Prod 승인 후 Live DB를 배포하고 동일 테스트를 실행합니다.

각 환경은 동일한 `database` DACPAC artifact를 사용합니다. 이전 환경이 실패하거나 승인되지 않으면 후속 환경으로 진행하지 않습니다. 실행 시 `sqlCommandTimeout` parameter를 생략하면 명시된 3600초를 사용합니다. SqlPackage의 60초 기본값에는 의존하지 않습니다. `maxParallel` 기본값은 4이며 카나리 성공 뒤의 DB에만 적용됩니다. `deployInstanceObjects` 기본값은 `false`입니다.

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
- `deployment-script-policy.md`: 결정론적 위험 DDL 검사와 allowlist 결과
- `target-databases.json`: 대표 DB, 전체 대상, 전수 검사와 모든 script gate 완료 여부
- `all-database-reports`: 전수 검사 시 DB별 DacFx 변경 계획
- `all-database-scripts`: 전수 검사 시 DB별 실제 실행 예정 SQL
- `all-database-policy-reports`: 전수 검사 시 DB별 결정론적 정책 결과

각 환경은 `pipelines/profiles/sqlmi-<environment>.publish.xml`을 사용합니다. 세 profile의
내용은 완전히 동일하며 연결 정보는 포함하지 않습니다. `Script`, `DeployReport`,
승인 직전 재생성 `DeployReport`, `Publish`는 같은 환경 profile과 같은 timeout override를
사용해야 하므로 계획과 실행의 옵션 차이를 허용하지 않습니다.

공통 게시 옵션:

```text
BlockOnPossibleDataLoss=True
CommandTimeout=3600
DropObjectsNotInSource=False
ExcludeObjectTypes=Users;Logins;Permissions;RoleMembership;ServerRoleMembership
ScriptDatabaseOptions=False
```

SqlPackage의 `CommandTimeout` 속성 기본값은 60초이므로 장기 실행 MI DDL에서 우발적인
timeout이 발생할 수 있습니다. profile은 3600초를 고정하고 파이프라인 parameter
`sqlCommandTimeout`을 `sqlCommandTimeout` 환경 변수로 전달해 네 작업에 동일하게
override합니다. 연결 정보와 `Connection Timeout=30`은 계속 variable group/실행
연결 문자열에서 관리합니다.

공식 SqlPackage의 유효 오브젝트 명칭을 사용해 사용자, 로그인, 권한, database/server
role membership을 배포 비교에서 제외합니다. 이 보안 오브젝트는 DACPAC이 아니라 별도
승인된 보안 IaC 또는 DBA runbook으로 만들고 회수하며, 변경 티켓과 감사를 남깁니다.
`AllowIncompatiblePlatform`은 설정하지 않습니다.

- [SqlPackage Script properties](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-script)
- [SqlPackage DeployReport properties](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-deploy-drift-report)
- [SqlPackage Publish properties](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-publish)
- [SQL MI endpoint 유형](https://learn.microsoft.com/azure/azure-sql/managed-instance/connectivity-architecture-overview)

`eng/Test-DeploymentScript.ps1`은 `deploy.sql`을 GO batch로 나누고 파괴 DDL,
축소 가능 `ALTER COLUMN`, `sp_rename`, `sp_executesql` 동적 DDL, `SET NOEXEC` 조작을
결정론적으로 검사합니다. 오류는 Plan stage를 즉시 실패시키며 경고는 보고서에 남습니다.
예외는 `eng/policy/deploy-allowlist.json`의 `rule`, `pattern`, `ticket`, `expiresOn`
네 필드가 모두 필요하고 만료된 항목은 자동 무효입니다. AI 검토는 이 게이트 이후의
advisory 단계입니다.

승인자는 대기 중인 `Deploy*` stage를 승인하기 전에 완료된 `Plan*` stage의 artifact를 검토합니다. 초기 도입 기간에는 Dev 자동 배포만 허용하고 Test/Prod에서 `deploy.sql`을 DBA가 승인하도록 운영합니다. `DropObjectsNotInSource=False`로 인해 제거가 자동 반영되지 않으므로, 승인된 제거는 별도 expand/contract 절차와 명시적 스크립트로 처리합니다.

기본 Plan은 대표 DB만 조회하며 비용/MI 부하 경고를 남깁니다.
`validateAllDatabasePlans=true`이면 각 DB의 DeployReport와 Script를 생성하고 모든
Script에 결정론적 정책 gate를 적용합니다. 보고서, script, 정책 결과는 각각
`all-database-reports`, `all-database-scripts`, `all-database-policy-reports`에
보존합니다. 하나의 DB라도 script gate를 통과하지 못하면 drift 정책과 관계없이 Plan이
실패합니다. 보고서 차이는
`databasePlanDriftPolicy=Warn`이면 승인 경고, `Fail`이면 Plan 실패입니다.
따라서 전수 검사는 대상 DB마다 DeployReport 1회와 Script 1회를 실행해 기본 대표 검사보다
SQL MI 부하와 pipeline 시간이 증가합니다.

승인 이후 배포 직전에 각 DB의 DeployReport를 다시 생성합니다. 대표 전용 Plan은 작업
집합을 대표 보고서와 비교하고, 전수 Plan은 각 DB별 승인 보고서와 비교합니다. 대상 DB에
새 드리프트가 생기면 해당 DB를 배포하지 않습니다. 첫 DB는 카나리로 publish 후 smoke
test까지 통과해야 나머지를 최대 `maxParallel`로 배포합니다. 장시간 rollout에서 토큰
만료를 피하도록 각 DB의 DeployReport, Publish, smoke test 직전에
`eng/Get-AzureSqlAccessToken.ps1`로 Azure SQL access token을 새로 가져옵니다.
각 DB 실패는 모두 수집되며 성공/실패 요약과 실패 DB 목록을 Azure DevOps summary에
게시합니다. 이미 목표 상태인 DB는 재시도에서 publish를 생략하고 smoke를 재실행합니다.

Plan도 각 DeployReport와 Script 직전에 같은 token provider를 호출합니다. Azure DevOps의
장시간 Plan과 rollout `AzureCLI@2` 작업은 WIF IdToken 만료 이후 재로그인을 위해
`keepAzSessionActive: true`를 사용합니다. 이 input은 Microsoft의 AzureCLI@2 task
manifest에서 WIF 전용 experimental 기능으로 정의되어 있으므로 private agent의 task
버전이 해당 input을 지원하는지 실제 실행 전에 확인합니다.

- [AzureCLI@2 공식 task manifest](https://github.com/microsoft/azure-pipelines-tasks/blob/master/Tasks/AzureCLIV2/task.json)

실제 SqlPackage 실행 직전 UTC 시각은
`deployment-review-<environment>-pitr-marker/pitr-marker.json`에 게시됩니다. timeout,
부분 성공, smoke 실패, 승인 후 drift와 COPY_ONLY backup 절차는
[SQL MI 배포 롤백 런북](롤백-런북.md)을 따릅니다.

## 7. AI 품질 게이트

`eng/Invoke-AiDatabaseReview.ps1`은 `ai/database-change-review.md`의 가드레일과
JSON Schema를 사용해 Azure OpenAI Responses API를 호출합니다.

- PR 검증: `database/App.Database`와 `tests/integration`의 변경 diff 검토
- 배포 계획: 환경별로 생성된 `deploy.sql` 검토
- 결과: JSON artifact와 Azure Pipelines 실행 요약용 Markdown

입력이 `MaxInputCharacters`(기본 120000)를 넘으면 SQL의 독립 줄 `GO`를 우선 경계로
나누어 순차 호출합니다. 단일 배치가 더 크면 줄 단위 무손실 창을 사용하며, 한 줄도 제한을
넘을 때만 고정 문자 창으로 나눕니다. 어떠한 fallback도 원문을 생략하거나 변경하지
않습니다. 각 요청에는 원본 경로와 원본 시작 줄을 넣고 모델이 반환한 청크 상대 줄을
원본 전역 줄로 변환합니다. Git diff는 파일과 hunk별 새 파일 줄 매핑을 사용합니다.
청크별 결과는 기존 `risk`, `summary`,
`blockingFindings`, `advisories` 계약을 유지해 병합합니다. risk는
`low < medium < high`의 최댓값이고 finding은 모든 필드가
같을 때 최초 등장만 유지합니다. `-ValidateOnlyResponsePath`에는 여러 청크이면 청크
수와 같은 JSON 응답 배열을, 기존 단일 응답 검증이면 객체 하나를 전달해 네트워크 없이
이 동작을 검증할 수 있습니다.

저장소의 `aiDeploymentName` 기본값은 `gpt-5.6-sol`입니다. 이 값은 Azure OpenAI
리소스에 실제로 만든 모델 배포 이름으로 재정의해야 합니다. 사용 가능한 모델, 지역,
버전, 할당량은 실행 시점의 Foundry 리소스에서 확인합니다.

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

- [Azure OpenAI의 Microsoft Entra ID 인증과 역할](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/managed-identity)
- [Foundry Responses API의 Microsoft Entra ID 인증](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/configure-entra-id)

실제 파이프라인 순서:

1. DACPAC build와 deterministic SQL policy
2. PR이면 선택적 advisory AI diff 검토
3. 컨테이너 integration test
4. 환경별 `Script`/`DeployReport` 생성과 deterministic 배포 SQL gate
5. 선택적 advisory AI `deploy.sql` 검토
6. Azure DevOps Environment 사람 승인
7. 대상별 `DeployReport` 재생성과 승인 계획 비교
8. SQL MI publish와 integration smoke test

AI 결과는 기본적으로 advisory로만 게시하며 LLM 호출 실패도 `SucceededWithIssues`로
표시합니다. `-FailOnBlockingFindings` 승격은 다음 조건을 **모두** 만족할 때만 승인합니다.

1. advisory 운영 기간이 연속 30일 이상이고 성공한 리뷰 실행이 100회 이상이다.
2. 사람이 판정한 변경 표본이 200건 이상이며 그중 실제 blocking 사례가 30건 이상이다.
3. blocking recall이 95% 이상이고 전체 변경 기준 blocking false-positive rate가 2% 이하이다.
4. Dev/Test/Prod 각 환경에서 false-positive rate가 5% 이하이고 최근 20회 연속으로
   확인되지 않은 blocking false positive가 없다.

승격 후 실제 고위험 변경 누락 1건, 7일 내 blocking 오탐 2건, 최근 20회 false-positive
rate 5% 초과 중 하나가 발생하면 즉시 advisory로 rollback합니다. 모델, 프롬프트, JSON
schema 또는 청크 알고리즘이 바뀌어도 위 표본을 다시 수집할 때까지 advisory로 되돌립니다.
SQL 본문에 운영 데이터나 connection string을 포함하지 않으며 승인된 Azure OpenAI
리소스만 사용합니다.

## 8. 운영 점검

- `pipelines/drift-report.yml`을 별도 Azure Pipeline으로 등록합니다. cron은 매일
  **02:00 UTC**이며 WIF `AzureCLI@2`, 고정 SqlPackage 170.4.83, 환경별 publish profile,
  `sqlCommandTimeout`, variable group, private agent pool을 배포 파이프라인과 동일하게
  사용합니다.
- 각 환경은 `databaseNames` 첫 항목(없으면 `databaseName`)만 대표 DB로 조회합니다.
  따라서 기본 비용은 환경당 DeployReport 1회입니다. 변경이 있으면 환경별 report
  artifact를 게시하고 `SucceededWithIssues`, 변경이 없으면 성공입니다. 인증/네트워크/
  SqlPackage/XML 오류는 실패하며 drift로 취급하지 않습니다.
- drift 파이프라인은 `/Action:DeployReport`만 실행합니다. `/Action:Script`,
  `/Action:Publish`, `Deploy-Databases.ps1`, `Deploy-InstanceObjects.ps1` 호출은
  `eng/Test-Phase3.ps1` 정적 검사에서 금지합니다.
- Azure DevOps artifact retention을 감사 기간에 맞게 설정합니다.
- SQL MI의 감사 로그와 Azure DevOps deployment record를 동일 변경 티켓으로 연결합니다.
- 운영 DB의 수동 DDL을 금지하고 정기적으로 DACPAC drift report를 생성합니다.
- SQL MI update policy와 `.sqlproj`의 `Sql170` DSP가 SQL Server 2025 기준으로 일치하는지
  확인합니다. Microsoft 문서상 SQL Server 2022 policy가 기존·신규 SQL MI의 기본값이므로
  저장소의 SQL Server 2025 기준선에 맞게 명시적으로 전환합니다. SQL Server 2022 policy는
  SQL Server 2022 mainstream support 종료일인 2028-01-11까지 제공된다고 문서화되어
  있으므로 그 전에 전환 계획을 승인합니다.
- 대상 database collation은 `ModelCollation`과 별개이며 profile의
  `ScriptDatabaseOptions=False`로 변경되지 않으므로 환경 생성 및 배포 전 별도 검사합니다.
- 실패 시 동일 DACPAC 재시도 또는 사전 승인된 롤백 스크립트를 사용합니다. BACPAC import를 일반적인 롤백 수단으로 사용하지 않습니다.

## 9. 빌드 엄격도 도입

파이프라인 `buildStrictness` 기본값은 `Strict`입니다. 레거시 소스 도입 시에만
Lenient로 warning을 수집하고, 연속 10회 CI에서 분류 완료/미분류 0개를 확인합니다.
baseline 변동이 연속 3회 0개이면 검증된 warning 번호만
`validatedSuppressTSqlWarnings`에 쉼표 목록으로 전달해 Balanced로 전환합니다. suppress
0개와 연속 20회 신규 warning 0개를 달성하면 Strict를 강제합니다. 번호는 실제 빌드
근거와 소유 티켓 없이 추가하지 않습니다.
