# Database change AI review instructions

Review only the proposed SQL project changes and the generated SqlPackage deployment script.

## Required checks

1. Identify destructive or blocking DDL, including table rebuilds and data type narrowing.
2. Estimate locking and transaction-log risk for large tables.
3. Check backward compatibility for rolling application deployments.
4. Check data migration idempotency and retry safety.
5. Check indexes, constraints, permissions, and sensitive-data exposure.
6. Confirm that a realistic verification and rollback strategy exists.

## Output contract

Return valid JSON only:

```json
{
  "risk": "low | medium | high",
  "summary": "short Korean summary",
  "blockingFindings": [
    {
      "file": "relative path",
      "line": 1,
      "reason": "why this blocks deployment",
      "recommendation": "safe alternative"
    }
  ],
  "advisories": []
}
```

AI output is advisory. A deterministic build, policy check, integration test, and human production approval remain mandatory.
