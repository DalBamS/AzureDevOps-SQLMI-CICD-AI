# Azure DevOps 설정

## 1. 연결과 변수

SQL MI에 도달할 수 있는 self-hosted agent와 Workload Identity Federation 서비스 연결을
준비합니다. Dev/Test/Prod variable group에는 다음 값을 둡니다.

| 변수 | 의미 |
|---|---|
| `sqlServer`, `sqlPort` | SQL MI endpoint와 포트 |
| `databaseName` | 단일 DB 호환 값 |
| `databaseNames` | 쉼표 구분 DB 목록; 첫 항목은 대표/카나리 |
| `instanceEntraLoginName` | 선택적 Entra login 이름 |
| `instanceAgentJobName`, `instanceAgentJobOwner` | 선택적 SQL Agent job 값 |

파이프라인 변수 `sqlPackageVersion`과 `sqlServerModuleVersion`이 도구 버전의 단일
계약입니다. 스크립트는 module 버전을 하드코딩하지 않고
`SQLSERVER_MODULE_VERSION` 환경 변수를 받습니다.

## 2. 승인 흐름

`sqlmi-dev`, `sqlmi-test`, `sqlmi-prod` Environment를 만들고 Test/Prod에 사람 승인과
exclusive lock을 설정합니다. Plan stage는 `deploy-report.xml`, `deploy.sql`,
`deployment-script-policy.md`를 게시합니다. 승인자는 세 파일과 대상 DB 목록을
검토합니다.

배포 직전 각 DB의 DeployReport를 같은 profile로 다시 만들고 승인본과 비교합니다.
`Publish`가 기본이며, SqlPackage 원 로그를 그대로 출력합니다.

| 모드 | 승인본 일치 | 로그 | 지원 경계 | 의존성 |
|---|---|---|---|---|
| `Publish` (기본) | DeployReport | SqlPackage 원 로그 | DacFx 공식 Publish; 실행 시 계획 재계산 | SqlPackage |
| `ValidatedScript` (opt-in) | DeployReport + script exact | `Invoke-Sqlcmd -Verbose` PRINT | 다중 DB는 전수 script 승인 필요 | SqlPackage + SqlServer module |

`ValidatedScript`는 `deploymentMode=ValidatedScript`로 명시할 때만 사용합니다.
`validateAllDatabasePlans=false`인 다중 DB rollout은 대상 DB 이름 차이로 exact script
일치를 보장할 수 없으므로 이 조합을 차단합니다.

## 3. Fan-out과 token

`databaseNames` 첫 항목을 카나리로 Publish하고 smoke test가 성공한 뒤 나머지를
`maxParallel` 제한으로 배포합니다. fan-out 직전에 Azure SQL token을 한 번 발급해 worker
context로 전달하며 worker별 `az` 호출은 없습니다.

이 교육 구현은 장기 실행 중 token을 갱신하지 않습니다. token 수명보다 긴 DDL은 작업을
분할하거나 새 pipeline run으로 재시도하십시오. 방어 코드를 추가해 token을 자동 교체하지
않습니다.

## 4. Publish profile

세 환경 profile은 연결 정보를 포함하지 않고 다음 안전 속성을 공유합니다.

```text
BlockOnPossibleDataLoss=True
CommandTimeout=3600
DropObjectsNotInSource=False
ExcludeObjectTypes=Users;Logins;Permissions;RoleMembership;ServerRoleMembership
ScriptDatabaseOptions=False
```

`sqlCommandTimeout`은 실행 제한이며 connection string의 `Connection Timeout=30`과
다릅니다. PITR marker artifact 이름에는 `$(System.JobAttempt)`가 들어가 재시도 결과를
구분합니다.

## 5. 경량 정책과 사람 review

GO는 pinned `Microsoft.SqlTools.ManagedBatchParser`에 전적으로 위임합니다. 배포 정책과
instance guard는 정규식 수준이므로 comment/string false positive와 우회 가능성이
있습니다. 새 parser를 추가하지 않으며, `deploy.sql`과 `database/instance` 파일은 DBA의
사람 review가 필수입니다.

기본 대표 Plan은 비대표 DB의 DeployReport 작업 집합만 비교합니다. 샤드별 script text
일치는 `validateAllDatabasePlans=true` + `ValidatedScript`에서만 보장합니다. Publish
기본 경로는 DeployReport 승인을 경계로 삼고 실제 실행 시 DacFx가 계획을 다시 계산합니다.

## 6. BuildStrictness 운영

`buildStrictness`는 `Lenient|Strict`입니다. sqlproj만으로 신규/변경 object warning만
error로 바꾸기 어렵습니다. Lenient의 전체 warning count를 대시보드에 기록하고 릴리스마다
허용 임계값을 낮춘 뒤 0에서 Strict로 전환하십시오.

## 7. 실제 환경 리허설

Azure 작업은 이 저장소 검증에 포함되지 않습니다. 강의 전 다음을 사람이 확인합니다.

- Portal의 SQL MI update policy와 되돌릴 수 없는 database format
- VNet/DNS 및 self-hosted agent 연결
- WIF Azure SQL/Foundry token 권한
- Test/Prod 승인과 artifact 보존
- SQL MI collation, PITR retention, 장기 DDL 소요 시간
- `database/instance` SQL의 목적/멱등성/권한
