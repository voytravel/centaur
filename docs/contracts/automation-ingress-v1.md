# Automation ingress v1

This is the current contract between the verified GitHub/Linear ingress bots
and the Console policy plane. `@centaur/automation-contracts` owns the shared
TypeScript event envelope and HTTP request. `AutomationIngressContractV1` owns
Console's minimum validation. Neither component verifies provider signatures:
the platform ingress must do that before submitting an event.

## Request

`POST /api/internal/automation_events` with the single-purpose ingress bearer
credential and a JSON body of `{ "event": { ... } }`. The event needs a provider
(`github` or `linear`), `event_type`, and a provider-scoped
`deduplication_key`. GitHub events also need `repository` and `subject_number`;
Linear events need `linear_issue_id` and `linear_team_id`. Optional facts such as
branch, status, labels, and issue title remain provider data, never a grant of
repository or role access.

The v1 name describes this existing wire shape. There is no version field on
live requests. Adding or requiring one needs a coordinated rollout across
Console and both bots so old and new deployments can overlap safely.

## Response and failure behavior

Console returns `{ "data": { ... } }` with `decision` (`act`, `observe`, or
`ignored`), `session_key`, `actions`, and provider-specific policy output.
The shared `parseAutomationDecisionV1` checks the common decision and session
fields and keeps the bots' existing fallback for absent reason/actions. Each
bot still interprets its own provider-specific policy fields.
The bots treat missing credentials, an unavailable Console, a non-success HTTP
response, or a malformed decision as no new policy authorization. Console
persists an event for each provider/deduplication key and rechecks current
policy on duplicate delivery before authorizing another attempt.

The requester cannot choose an execution role. Console selects the role from
an operator-reviewed policy and binds it to the matching workstream. QA dispatch
uses the separate, fixed `linear_qa_control_plane` workflow with its own
idempotency key; its GitHub Actions executor remains pinned by the host policy.

## Compatibility gate

The shared package test pins the existing URL, headers, and JSON envelope.
Githubbot and Linearbot automation tests pin normalization and decision
handling. Console's automation event/controller tests pin authorization,
deduplication, and policy behavior. Changes to this contract should run all
three suites and verify that the same event still produces the same decision
and workstream before changing a production adapter.
