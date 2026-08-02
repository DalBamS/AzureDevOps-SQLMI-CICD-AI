# Azure DevOps 설정

## 1. 데모 구성 예시

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

Demo self-hosted agent를 개발 PC에서 실행할 수 있지만, 운영 전에는 SQL MI VNet 내부의
전용 VM 또는 Managed DevOps Pool로 교체하십시오.

## 2. 사전 준비

### 2.1 네트워크 경로 선택

SQL MI는 세 가지 endpoint를 제공하며 포트가 다릅니다. 혼동하기 쉬우므로 먼저 정리합니다.

| Endpoint | 포트 | 용도 |
|---|---|---|
| VNet-local (기본) | 1433 | 같은 VNet, peered VNet, VPN/ExpressRoute 연결망. failover group, MI link 등 1433 외 포트가 필요한 시나리오도 이 경로만 지원 |
| Private endpoint (선택) | 1433 | 다른 VNet에 고정 IP로 노출. Private Link 기반이며 클라이언트 트래픽만 전달 |
| Public endpoint (선택) | 3342 | 명시적으로 활성화한 경우에만 사용. NSG로 원본 IP를 제한 |

Demo는 실습 편의를 위해 public endpoint(3342)를 사용합니다. 운영에서는 VNet-local 또는
private endpoint를 사용하십시오.

- [SQL MI 연결 아키텍처](https://learn.microsoft.com/azure/azure-sql/managed-instance/connectivity-architecture-overview)
- [SQL MI private endpoint](https://learn.microsoft.com/azure/azure-sql/managed-instance/private-endpoint-overview)

### 2.2 Workload Identity Federation 서비스 연결

1. SQL MI와 통신 가능한 네트워크에 self-hosted Azure Pipelines agent를 배치합니다.
2. Azure DevOps의 **Project settings → Service connections → New service connection →
   Azure Resource Manager**를 선택합니다.
3. 인증 방식으로 **Workload Identity federation (automatic)** 을 선택하고 구독과
   리소스 그룹을 지정합니다. 연결 이름은 `sc-sqlmi-wif`로 둡니다.
4. **Manage Service Principal**을 눌러 생성된 Entra 앱의 표시 이름을 확인합니다. 이 이름이
   이후 절차의 `<deployer-principal-name>`입니다.
5. 서비스 연결 이름은 variable group이 아니라 파이프라인의 compile-time
   `azureServiceConnection` parameter로 전달합니다. Azure Pipelines가 실행 전에 서비스
   연결 권한을 검증하기 때문입니다.

암호는 필요하지 않습니다. `AzureCLI@2`가 서비스 연결로 로그인하고 Azure SQL access
token을 발급합니다. SQL 인증이 불가피한 레거시 환경은 Key Vault-linked variable group을
별도로 사용하십시오.

### 2.3 SQL MI의 Entra 주체 조회 권한 — 실습 전 필수

**이 단계를 건너뛰면 다음 절의 `CREATE USER ... FROM EXTERNAL PROVIDER`가 실패하고
실습이 시작되지 않습니다.** SQL MI가 Microsoft Entra 디렉터리에서 주체를 조회하려면 SQL
MI의 시스템 할당 관리 ID에 디렉터리 읽기 권한이 있어야 합니다. 두 가지 경로가 있습니다.

| 경로 | 부여 대상 | 특징 |
|---|---|---|
| A. Directory Readers 역할 | SQL MI 시스템 ID | 설정이 간단하지만 디렉터리 전체 읽기 권한 |
| B. Microsoft Graph application permission | SQL MI 시스템 ID에 `User.Read.All`, `GroupMember.Read.All`, `Application.Read.All` | Microsoft가 안내하는 최소 권한 조합. 테넌트 관리자 동의 필요 |

이 저장소의 데모 환경은 경로 B를 사용했습니다. 조직에 따라 Graph application permission
부여에 별도 승인이 필요할 수 있으므로, 승인이 어려우면 경로 A로 진행해도 기능은
동일합니다. 어느 쪽이든 **테넌트 전역 관리자 또는 Privileged Role Administrator** 권한이
필요합니다.

권한이 없을 때 나타나는 대표 증상입니다. 이 오류를 보면 SQL 권한 문제가 아니라 디렉터리
권한 문제이므로 이 절로 돌아오십시오.

```text
Principal '<deployer-principal-name>' could not be found or this principal type is not supported.
```

```text
Server identity does not have Azure Active Directory Readers permission.
```

### 2.4 배포 주체를 데이터베이스 사용자로 생성

각 대상 데이터베이스에서 실행합니다. 예시 권한은 초기 구축용 기준이며, 조직의 권한 분리
정책에 따라 사용자 지정 database role로 축소하십시오.

```sql
CREATE USER [<deployer-principal-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE [db_ddladmin] ADD MEMBER [<deployer-principal-name>];
ALTER ROLE [db_datareader] ADD MEMBER [<deployer-principal-name>];
ALTER ROLE [db_datawriter] ADD MEMBER [<deployer-principal-name>];
GRANT VIEW DEFINITION TO [<deployer-principal-name>];
```

`eng/Initialize-DemoDatabases.ps1`이 데모 DB 세 개에 대해 이 작업을 대신 수행합니다.
사용법은 §6을 참고하십시오.

## 3. Agent pool

`sqlmi-private-agents`라는 private agent pool을 만들거나, 파이프라인 실행 시
`privateAgentPool` parameter에 실제 이름을 입력합니다.

에이전트 요구사항:

- PowerShell 7
- Azure CLI
- .NET 10 설치 가능 또는 사전 설치
- SqlServer PowerShell module 설치 가능. 버전은 파이프라인 변수
  `sqlServerModuleVersion`이 단일 기준이며 스크립트는 버전을 하드코딩하지 않습니다
- NuGet, PSGallery 및 Microsoft artifact endpoint에 대한 outbound HTTPS
- 대상 SQL MI endpoint/FQDN 접근

폐쇄망에서는 매 실행마다 도구를 내려받는 대신 에이전트 이미지에 .NET SDK, SqlPackage,
SqlServer module을 미리 설치해 두는 편이 안정적입니다.

## 4. Environment와 승인

다음 Azure DevOps Environments를 생성합니다. **Pipelines → Environments → New
environment**에서 이름만 지정하고 리소스는 **None**으로 둡니다.

| Environment | 권장 검사 |
|---|---|
| `sqlmi-dev` | 자동 배포 허용 |
| `sqlmi-test` | QA 또는 DBA 승인 |
| `sqlmi-prod` | DBA + 서비스 책임자 승인, 업무 시간/변경 티켓 검사 |

각 Environment의 **Approvals and checks**에서 다음을 추가합니다.

1. **Approvals** — Test와 Prod에 승인자를 지정합니다. 요청자 본인 승인 허용 여부는 조직
   정책에 맞춥니다.
2. **Exclusive lock** — 동시 배포를 직렬화합니다. 파이프라인의
   `lockBehavior: sequential`과 함께 동작합니다.

승인을 YAML이 아니라 Environment에 두는 이유는, 파이프라인 파일을 수정해 승인을
우회하는 경로를 막기 위해서입니다.

## 5. Variable group

**Pipelines → Library → + Variable group**에서 `sqlmi-dev`, `sqlmi-test`, `sqlmi-prod`
세 개를 만들고, 각 group의 **Pipeline permissions**에서 이 파이프라인의 사용을
허용합니다.

| 변수 | 의미 |
|---|---|
| `sqlServer`, `sqlPort` | SQL MI endpoint와 포트 |
| `databaseName` | 단일 DB 호환 값 |
| `databaseNames` | 쉼표 구분 DB 목록; 첫 항목은 대표/카나리 |
| `instanceEntraLoginName` | 선택적 Entra login 이름 |
| `instanceAgentJobName`, `instanceAgentJobOwner` | 선택적 SQL Agent job 값 |

`databaseNames`가 비어 있거나 정의되지 않으면 `databaseName`을 사용합니다. 인스턴스
오브젝트를 사용하지 않는 환경에서는 `instance*` 변수를 생략해도 됩니다.

파이프라인 변수 `sqlPackageVersion`과 `sqlServerModuleVersion`이 도구 버전의 단일
계약입니다. 스크립트는 module 버전을 하드코딩하지 않고 `SQLSERVER_MODULE_VERSION` 환경
변수를 받습니다.

## 6. Pipeline 생성

### 6.1 배포 파이프라인 등록

1. **Pipelines → New pipeline → GitHub**에서 저장소를 선택하고 기존
   `azure-pipelines.yml`을 사용합니다.
2. GitHub 저장소이므로 GitHub branch protection에서 이 파이프라인의 상태 검사를
   Required로 설정합니다. Azure Repos를 사용하는 경우에는 `main` 브랜치의 **Build
   validation** 정책에 파이프라인을 Required로 연결합니다. YAML의 `pr` 선언만으로는
   검증이 강제되지 않습니다.
3. PR을 생성하면 Azure hosted agent가 빌드, 정책, 컨테이너 통합 테스트를 실행합니다.
   `enableAiReview=true`일 때만 advisory AI 리뷰를 추가합니다.
4. 병합 후 파이프라인을 수동 실행해 환경별 배포를 진행합니다.

주요 실행 parameter입니다. 전체 목록은 `azure-pipelines.yml`의 `parameters` 블록을
확인하십시오.

| Parameter | 기본값 | 의미 |
|---|---|---|
| `deployDev` / `deployTest` / `deployProd` | `false` | 환경별 배포 활성화. 앞 환경이 성공·승인되어야 다음 환경이 실행됨 |
| `deploymentMode` | `Publish` | `Publish` 또는 `ValidatedScript` |
| `sqlCommandTimeout` | `3600` | SqlPackage 실행 제한(초) |
| `maxParallel` | `4` | 카나리 성공 뒤 나머지 DB의 최대 동시 배포 수 |
| `validateAllDatabasePlans` | `false` | `true`이면 모든 대상 DB의 DeployReport 생성 |
| `databasePlanDriftPolicy` | `Warn` | 전수 계획 차이를 경고 또는 `Fail`로 차단 |
| `deployInstanceObjects` | `false` | DB fan-out 성공 후 인스턴스 오브젝트 job 실행 |
| `buildStrictness` | `Strict` | `Lenient` 또는 `Strict` |
| `privateAgentPool` | `sqlmi-private-agents` | 배포용 self-hosted pool 이름 |
| `azureServiceConnection` | `sc-sqlmi-wif` | WIF 서비스 연결 |
| `enableAiReview` | `false` | advisory AI 리뷰 활성화 |

### 6.2 드리프트 리포트 파이프라인 등록

`pipelines/drift-report.yml`을 **두 번째 파이프라인으로 별도 등록**합니다. New pipeline
에서 같은 저장소를 선택한 뒤 **Existing Azure Pipelines YAML file**로 이 경로를
지정하면 됩니다. cron 트리거가 동작하려면 등록이 반드시 필요합니다. 동작은 §12를
참고하십시오.

### 6.3 Demo 데이터베이스 최초 구성

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

SQL MI 시작에는 일반적으로 수 분 이상 걸리며, `az sql mi start`가 완료된 후 초기화
스크립트를 실행합니다. 실습 일정에 이 대기 시간을 반영하십시오.

Demo가 끝나면 비용 절감을 위해 인스턴스를 중지합니다.

```powershell
az sql mi stop -g $resourceGroup --mi $managedInstance
```

## 7. 승인 게이트와 배포 모드

Plan stage는 `deploy-report.xml`, `deploy.sql`, `deployment-script-policy.md`를
게시합니다. 승인자는 세 파일과 대상 DB 목록을 검토합니다.

배포 직전 각 DB의 DeployReport를 같은 profile로 다시 만들고 승인본과 비교합니다.
`Publish`가 기본이며 SqlPackage 원 로그를 그대로 출력합니다.

| 모드 | 승인본 일치 | 로그 | 지원 경계 | 의존성 |
|---|---|---|---|---|
| `Publish` (기본) | DeployReport | SqlPackage 원 로그 | DacFx 공식 Publish; 실행 시 계획 재계산 | SqlPackage |
| `ValidatedScript` (opt-in) | DeployReport + script exact | `Invoke-Sqlcmd -Verbose` PRINT | 다중 DB는 전수 script 승인 필요 | SqlPackage + SqlServer module |

`ValidatedScript`는 `deploymentMode=ValidatedScript`로 명시할 때만 사용합니다.
`validateAllDatabasePlans=false`인 다중 DB rollout은 대상 DB 이름 차이로 exact script
일치를 보장할 수 없으므로 이 조합을 차단합니다.

Plan과 승인 후 재검증의 `Script`, `DeployReport`는 반드시 같은 publish profile을
사용합니다. 계획과 실행의 옵션이 달라지면 승인 검증이 무의미해집니다.

## 8. Fan-out과 token

`databaseNames` 첫 항목을 카나리로 배포하고 smoke test가 성공한 뒤 나머지를
`maxParallel` 제한으로 배포합니다. fan-out 직전에 Azure SQL token을 한 번 발급해 worker
context로 전달하며 worker별 `az` 호출은 없습니다. Azure CLI의 토큰 캐시가 동시 접근에
취약하기 때문입니다.

이 교육 구현은 장기 실행 중 token을 갱신하지 않습니다. Azure SQL access token의 수명은
대략 60~90분이므로, 대상 DB가 많고 DDL이 길면 롤아웃 후반에 인증 오류가 발생할 수
있습니다. token 수명보다 긴 작업은 대상을 나누거나 새 pipeline run으로 재시도하십시오.

## 9. Publish profile

세 환경 profile은 연결 정보를 포함하지 않고 다음 안전 속성을 공유합니다.

```text
BlockOnPossibleDataLoss=True
CommandTimeout=3600
DropObjectsNotInSource=False
ExcludeObjectTypes=Users;Logins;Permissions;RoleMembership;ServerRoleMembership
ScriptDatabaseOptions=False
```

SqlPackage의 `CommandTimeout` 기본값은 60초입니다. 대형 테이블의 인덱스 생성이나 컬럼
변경은 60초를 쉽게 넘기므로 profile에서 3600초를 명시합니다. 실행 제한인
`CommandTimeout`과 연결 수립 제한인 connection string의 `Connection Timeout=30`을
혼동하지 마십시오.

사용자, 로그인, 권한, role membership을 제외하는 이유는 계정 관리가 대개 DACPAC이 아닌
별도 프로세스로 운영되기 때문입니다. 제외하지 않으면 DacFx가 소스에 없는 사용자를
관리하려 시도합니다.

PITR marker artifact 이름에는 `$(System.JobAttempt)`가 들어가 재시도 결과를 구분합니다.

## 10. 경량 정책과 사람 review

GO 분리는 pinned `Microsoft.SqlTools.ManagedBatchParser`에 전적으로 위임합니다. 배포
정책과 instance guard는 정규식 수준이므로 comment/string false positive와 우회 가능성이
있습니다. 저장소는 새 SQL parser를 추가하지 않으며, `deploy.sql`과 `database/instance`
파일은 DBA의 사람 review가 필수입니다.

기본 대표 Plan은 비대표 DB의 DeployReport 작업 집합만 비교합니다. 샤드별 script text
일치는 `validateAllDatabasePlans=true` + `ValidatedScript`에서만 보장합니다. Publish
기본 경로는 DeployReport 승인을 경계로 삼고 실제 실행 시 DacFx가 계획을 다시 계산합니다.

## 11. AI 품질 게이트

`eng/Invoke-AiDatabaseReview.ps1`은 `ai/database-change-review.md`의 가드레일을 사용해
Azure OpenAI Responses API를 호출합니다.

- PR 검증: `database/App.Database`와 `tests/integration`의 변경 diff 검토
- 배포 계획: 환경별로 생성된 `deploy.sql` 검토
- 결과: JSON artifact와 Azure Pipelines 실행 요약용 Markdown

입력이 `MaxInputCharacters`(기본 120000)를 넘으면 여러 청크로 나누어 순차 호출하고,
결과를 병합합니다. risk는 `low < medium < high`의 최댓값을 사용합니다. 응답은
`risk`, `summary`, `blockingFindings`, `advisories` 계약을 만족해야 하며 위반하면
실패합니다. `-ValidateOnlyResponsePath`로 네트워크 없이 파싱·병합 동작을 검증할 수
있습니다.

### 11.1 Azure OpenAI 준비

1. Azure OpenAI(Foundry) 리소스를 만들고 모델 배포를 생성합니다. 저장소의
   `aiDeploymentName` 기본값은 `gpt-5.6-sol`이며, 실제로 만든 배포 이름으로 재정의해야
   합니다.
2. 모델 가용성, 지역, 버전, 할당량은 실행 시점의 Foundry 리소스에서 확인합니다.
   `gpt-5.6` 계열은 구독 등급에 따라 별도 할당량 요청이 필요할 수 있습니다.
3. `sc-sqlmi-wif` 서비스 연결의 Entra 주체에 Azure OpenAI 리소스 범위의
   **Cognitive Services OpenAI User** 역할을 부여합니다. 파이프라인은
   `https://ai.azure.com/.default` scope의 토큰을 사용하므로 API key를 저장할 필요가
   없습니다.
4. PR 코멘트가 필요하면 Azure DevOps의 **GitHub 서비스 연결**을 등록하고
   `publishAiPrComment=true`로 실행합니다. 이 옵션 없이도 JSON artifact와 파이프라인
   실행 요약은 게시됩니다.

| Parameter | 예시 |
|---|---|
| `enableAiReview` | `true` |
| `aiEndpoint` | `https://<azure-openai-resource>.openai.azure.com/openai/v1/` |
| `aiDeploymentName` | `gpt-5.6-sol` |
| `publishAiPrComment` | `true` |
| `githubServiceConnection` | `<github-service-connection>` |

저장소 기본값은 개인 리소스 노출과 잘못된 환경 호출을 막기 위해 비활성화되어 있습니다.

- [Azure OpenAI Responses API](https://learn.microsoft.com/azure/foundry/openai/how-to/responses)
- [Azure OpenAI의 Microsoft Entra ID 인증과 역할](https://learn.microsoft.com/azure/foundry-classic/openai/how-to/managed-identity)

### 11.2 advisory에서 blocking으로 승격하는 기준

AI 결과는 기본적으로 advisory로만 게시하며 LLM 호출 실패도 `SucceededWithIssues`로
표시합니다. `-FailOnBlockingFindings` 승격은 다음 조건을 **모두** 만족할 때만
승인합니다.

1. advisory 운영 기간이 연속 30일 이상이고 성공한 리뷰 실행이 100회 이상이다.
2. 사람이 판정한 변경 표본이 200건 이상이며 그중 실제 blocking 사례가 30건 이상이다.
3. blocking recall이 95% 이상이고 전체 변경 기준 blocking false-positive rate가 2%
   이하이다.
4. Dev/Test/Prod 각 환경에서 false-positive rate가 5% 이하이고 최근 20회 연속으로
   확인되지 않은 blocking false positive가 없다.

승격 후 실제 고위험 변경 누락 1건, 7일 내 blocking 오탐 2건, 최근 20회 false-positive
rate 5% 초과 중 하나가 발생하면 즉시 advisory로 rollback합니다. 모델, 프롬프트 또는
청크 알고리즘이 바뀌어도 위 표본을 다시 수집할 때까지 advisory로 되돌립니다.

SQL 본문에 운영 데이터나 connection string을 포함하지 않으며 승인된 Azure OpenAI
리소스만 사용합니다.

## 12. 운영 점검

- `pipelines/drift-report.yml`은 매일 **02:00 UTC**에 실행됩니다. WIF `AzureCLI@2`,
  고정 SqlPackage 버전, 환경별 publish profile, `sqlCommandTimeout`, variable group,
  private agent pool을 배포 파이프라인과 동일하게 사용합니다.
- 각 환경은 `databaseNames` 첫 항목(없으면 `databaseName`)만 대표 DB로 조회합니다.
  따라서 기본 비용은 환경당 DeployReport 1회입니다. 변경이 있으면 환경별 report
  artifact를 게시하고 `SucceededWithIssues`, 변경이 없으면 성공입니다. 인증, 네트워크,
  SqlPackage, XML 오류는 실패이며 drift로 취급하지 않습니다.
- drift 파이프라인은 `/Action:DeployReport`만 실행합니다. 배포 액션을 호출하지
  않습니다.
- Azure DevOps artifact retention을 감사 기간에 맞게 설정합니다.
- SQL MI의 감사 로그와 Azure DevOps deployment record를 동일 변경 티켓으로 연결합니다.
- 운영 DB의 수동 DDL을 금지하고, 드리프트가 감지되면 원인을 확인한 뒤 소스에 반영합니다.
- SQL MI update policy와 `.sqlproj`의 DSP가 일치하는지 확인합니다. 자세한 내용은
  [개발 환경 구성 및 테스트 — Update policy와 collation](환경-구성-및-테스트.md#5-update-policy와-collation)을
  참고하십시오.
- 대상 database collation은 `ModelCollation`과 별개이며 profile의
  `ScriptDatabaseOptions=False`로 변경되지 않으므로 환경 생성 및 배포 전 별도로
  확인합니다.
- 실패 시 대응은 [SQL MI 배포 롤백 런북](롤백-런북.md)을 따릅니다. BACPAC import를
  일반적인 롤백 수단으로 사용하지 않습니다.

## 13. BuildStrictness 운영

`buildStrictness`는 `Lenient|Strict` 두 단계입니다. SQL 프로젝트만으로 "신규 또는 변경
오브젝트의 warning만 error"를 안정적으로 구분하기 어렵기 때문에 중간 단계를 두지
않았습니다.

기존 데이터베이스를 이 저장소 방식으로 옮길 때는 다음 순서를 권합니다.

1. `Lenient`로 CI를 운영하며 전체 warning 수를 매 실행 기록합니다.
2. 팀이 정한 허용 임계값을 릴리스마다 낮춥니다.
3. 임계값이 0에 도달하고 신규 warning이 발생하지 않으면 `Strict`를 필수화합니다.

warning 번호별 suppress 목록으로 중간 상태를 숨기지 않습니다. 숨긴 항목은 결국 다시
드러납니다.

## 14. 실제 환경 리허설

Azure 작업은 이 저장소 검증에 포함되지 않습니다. 강의 전 다음을 사람이 확인합니다.

- Portal의 SQL MI update policy와 되돌릴 수 없는 database format
- VNet/DNS 및 self-hosted agent 연결
- WIF Azure SQL/Foundry token 권한과 §2.3의 디렉터리 조회 권한
- Test/Prod 승인과 artifact 보존
- SQL MI collation, PITR retention, 장기 DDL 소요 시간
- `database/instance` SQL의 목적, 멱등성, 권한
