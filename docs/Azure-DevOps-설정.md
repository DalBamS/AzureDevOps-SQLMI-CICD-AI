# Azure DevOps 설정 가이드

## 1. 사전 준비

1. SQL MI와 통신 가능한 서브넷에 self-hosted Azure Pipelines agent를 배치합니다.
2. 에이전트에서 SQL MI의 FQDN과 포트로 DNS/네트워크 연결을 확인합니다.
3. Azure Resource Manager 서비스 연결을 Workload Identity Federation 방식으로 생성합니다.
4. 서비스 연결의 Entra 주체를 각 대상 데이터베이스에 사용자로 생성하고 최소 권한을 부여합니다.

예시 권한은 초기 구축용 기준입니다. 조직의 권한 분리 정책에 따라 사용자 지정 database role로 축소하십시오.

```sql
CREATE USER [ado-sqlmi-deployer] FROM EXTERNAL PROVIDER;
ALTER ROLE [db_ddladmin] ADD MEMBER [ado-sqlmi-deployer];
ALTER ROLE [db_datareader] ADD MEMBER [ado-sqlmi-deployer];
ALTER ROLE [db_datawriter] ADD MEMBER [ado-sqlmi-deployer];
GRANT VIEW DEFINITION TO [ado-sqlmi-deployer];
```

## 2. Agent pool

`sqlmi-private-agents`라는 private agent pool을 만들거나 파이프라인 실행 시 `privateAgentPool` parameter에 실제 이름을 입력합니다.

에이전트 요구사항:

- PowerShell 7
- Azure CLI
- .NET 10 설치 가능 또는 사전 설치
- NuGet 및 Microsoft artifact endpoint에 대한 outbound HTTPS
- SQL MI private endpoint/FQDN 접근

## 3. Environment와 승인

다음 Azure DevOps Environments를 생성합니다.

| Environment | 권장 검사 |
|---|---|
| `sqlmi-dev` | 자동 배포 허용 |
| `sqlmi-test` | QA 또는 DBA 승인 |
| `sqlmi-prod` | DBA + 서비스 책임자 승인, 업무 시간/변경 티켓 검사 |

승인은 YAML에 두지 않고 Environment의 **Approvals and checks**에서 관리해야 파이프라인 변경으로 우회하기 어렵습니다.
각 Environment에 **Exclusive lock** 검사도 추가합니다. YAML의 `lockBehavior: sequential`과 함께 동시 배포를 직렬화합니다.

## 4. Variable group

Library에 `sqlmi-dev`, `sqlmi-test`, `sqlmi-prod` variable group을 생성합니다.

| 변수 | 예시 | 비밀 여부 |
|---|---|---|
| `sqlServer` | `my-mi.xxxxx.database.windows.net` | 아니요 |
| `sqlPort` | `1433` | 아니요 |
| `databaseName` | `AppDb` | 아니요 |

서비스 연결 이름은 variable group이 아니라 파이프라인의 compile-time `azureServiceConnection` parameter로 전달합니다. Azure Pipelines가 실행 전에 서비스 연결 권한을 검증하기 때문입니다.

암호는 필요하지 않습니다. `AzureCLI@2`가 서비스 연결으로 로그인하고 Azure SQL access token을 발급합니다. SQL 인증이 불가피한 레거시 환경은 Key Vault-linked variable group을 별도로 사용하십시오.

## 5. Pipeline 생성

1. Pipelines에서 저장소 루트의 `azure-pipelines.yml`을 선택합니다.
2. 첫 실행은 모든 deploy parameter를 `false`로 두고 CI만 확인합니다.
3. Dev 배포는 `deployDev=true`로 수동 실행합니다.
4. Test 승격은 `deployDev=true`, `deployTest=true`로 실행합니다.
5. Prod 승격은 세 deploy parameter를 모두 `true`로 설정합니다.

각 환경은 동일한 `database` DACPAC artifact를 사용합니다. 이전 환경이 실패하거나 승인되지 않으면 후속 환경으로 진행하지 않습니다.

Azure Repos의 PR 검증은 YAML의 `pr` 선언만으로 강제되지 않으므로, `main` 브랜치의 **Build validation** 정책에 이 파이프라인을 Required로 연결합니다.

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

## 7. AI 품질 게이트

`ai/database-change-review.md`는 PR diff와 `deploy.sql`을 AI 리뷰에 전달할 때 사용하는 출력 계약입니다.

권장 순서:

1. deterministic SQL policy
2. DACPAC build
3. 컨테이너 integration test
4. AI 위험 분석
5. 사람 승인
6. SQL MI publish

AI 결과는 초기에는 advisory comment로만 게시합니다. 충분한 정밀도와 오탐 기준을 확보한 후 `blockingFindings`가 있을 때만 배포를 차단합니다. SQL 본문에 운영 데이터나 connection string을 포함하지 않으며, 승인된 Azure OpenAI 또는 조직이 허용한 Copilot 서비스만 사용합니다.

## 8. 운영 점검

- Azure DevOps artifact retention을 감사 기간에 맞게 설정합니다.
- SQL MI의 감사 로그와 Azure DevOps deployment record를 동일 변경 티켓으로 연결합니다.
- 운영 DB의 수동 DDL을 금지하고 정기적으로 DACPAC drift report를 생성합니다.
- 실패 시 동일 DACPAC 재시도 또는 사전 승인된 롤백 스크립트를 사용합니다. BACPAC import를 일반적인 롤백 수단으로 사용하지 않습니다.
