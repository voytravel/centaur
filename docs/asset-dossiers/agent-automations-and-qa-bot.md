# Agent automations and adaptive QA bot — asset one pager

**Asset class:** Policy-governed software engineering automation and evidence-backed QA infrastructure

**Status:** built (integration and portability partial)

**Owner:** Michael Wu (technical contact inferred from commit history; confirm business and IP owner)

**Lives in:** `voytravel/centaur` (`services/console/app/{models,services,jobs}/automation_*`, `services/{githubbot,linearbot}/`, `services/api-rs/`); `voytravel/voy` (`scripts/qa-bot/`, `.github/workflows/qa-bot.yml`, `docs/qa-bot/`); an operational QA control-plane workflow referenced by Centaur but absent from these two checked-out trees
**Last updated:** 2026-09-28

## 1. Summary

The asset turns verified code-host and issue-tracker events into policy-authorized agent work, bounded pull-request review and repair, and evidence-backed QA runs. Its unusual properties are durable workstreams, explicit role grants, deterministic review budgets, a trusted QA target/profile allowlist, and a structured outcome that distinguishes a passing workflow from verified QA. The policy plane and QA executor are built, but they are split across repositories and rely on a separately deployed workflow and organization-specific configuration. **Planning estimate:** 4–8 engineering weeks for a reusable package and one new-product pilot, excluding legal clearance, credentials, and any new test adapters; this is an estimate, not a measured extraction.

## 2. What it does

- Accepts signed issue and pull-request events, normalizes them, and evaluates operator-controlled policies before starting an agent.
- Keeps one durable workstream per issue or pull request, with a compact audit trail and replay-safe event handling.
- Selects approved repositories, roles, branches, labels, and human reviewers for implementation work; can open a draft pull request and collect preview evidence.
- Reviews pull requests with one model or a bounded group of independent models, then follows up on feedback, failed checks, and conflicts within explicit limits.
- Starts QA when an issue enters a configured state; chooses an allowlisted target, commit/ref, test profile, and trusted runner.
- Runs deterministic checks and bounded exploratory follow-ups; stores command logs, test results, screenshots or traces, and a structured pass/fail/blocked report.
- Publishes a report and source-linked outcome to the issue tracker and code host, subject to configured delivery and permissions.

## 3. Out of scope

- It does not prove every acceptance criterion or guarantee a defect-free release; a pass covers only the selected checks and evidence.
- It does not let webhook text grant permissions, choose arbitrary repositories, or run arbitrary QA commands.
- It does not provide a general target/plugin API today: the QA runner has a two-target trusted manifest and product-specific adapters.
- It does not include the target applications, their test fixtures, production data, model or provider accounts, runner hardware, or historical issue content as transferable software.
- It does not establish legal title or permission to transfer third-party or user data.

## 4. Who would use it

- A payments platform could triage service changes and run API contract suites before release.
- A developer-tool company could review pull requests and run browser acceptance checks against preview builds.
- A healthcare software team could use the policy and audit plane with its own approved test profiles, subject to its security and data rules.

## 5. Interface contract

- **Inputs:** Verified GitHub/Linear webhooks reduced to normalized event metadata; operator policies, execution roles, target/profile manifests, issue and pull-request links, optional explicit QA target/ref, and approved credentials.
- **Outputs:** Policy decisions and workstream records; durable agent sessions and pull-request actions; QA `report.json`, `qa-outcome.json`, artifact links, a GitHub check, and issue-tracker comments/status where configured.
- **Ports the package would expose:** A normalized, authenticated automation-event intake; policy evaluation and workstream query; QA dispatch with an idempotency key; target/profile registry; versioned QA outcome and evidence schema; pluggable issue/code-host delivery adapters. These are **proposed extraction ports**, not a single existing public package API.
- **Called as:** service + worker + CLI; current hosting uses Centaur services/workflows and a GitHub Actions runner.

## 6. Guarantees (if any)

- Verified webhook handling and fail-closed policy lookup: unauthorized or unavailable policy ingress must not start a policy-driven turn. Pinned by `services/{githubbot,linearbot}/test/automation.test.ts`, `services/console/test/controllers/api/internal/automation_events_controller_test.rb`, and `services/console/test/services/automation_event_ingestor_test.rb`.
- One recorded event per provider/deduplication key and stable workstream identity; a duplicate re-evaluates current policy before re-authorization. Pinned by `automation_event_ingestor_test.rb` and DB uniqueness indexes.
- QA dispatch requires an acted `run_qa` event and validated issue/repository fields; its persisted event ID is the workflow idempotency key. Pinned by `services/console/test/jobs/automation_qa_dispatch_job_test.rb`.
- QA profiles and commands come from trusted allowlists; missing evidence, skipped tests, and incomplete runs cannot yield a verified pass. Pinned by `scripts/qa-bot/{targets,adapters,report,workflow-outcome}.test.*` and the QA outcome contract. These are implementation properties under test, not a guarantee that a new deployment is correctly configured.

## 7. Transferability

| Layer | Lives in | Size | Dependencies | Can we reuse it? |
| --- | --- | --- | --- | --- |
| Policy, workstreams, role binding, audit | Centaur Console models/services/jobs and migrations | Large | Rails, Postgres, Centaur principals/roles | Take it, small cleanup needed |
| GitHub/Linear ingress and pull-request lifecycle | Centaur `services/githubbot/`, `services/linearbot/` | Large | Provider APIs, Chat SDK, Centaur sessions | Take it, small cleanup needed |
| Durable agent execution and sandbox | Centaur `services/api-rs/`, `services/sandbox/`, Helm | Very large | Postgres, Kubernetes, proxy, harnesses | Take it as is |
| QA dispatch and outcome bridge | Centaur `AutomationQaDispatch*`; separate control-plane workflow | Medium; workflow inventory incomplete | Centaur workflow API, GitHub Actions, provider tokens | Take it, small cleanup needed |
| QA runner, schemas, evidence, reporting | Voy `scripts/qa-bot/`, `.github/workflows/qa-bot.yml` | Large | Node/pnpm, GitHub Actions, Linear, model APIs | Take it, small cleanup needed |
| Product targets, profiles, runtime setup, fixtures | Voy `scripts/qa-bot/{targets,profiles,runtime-supervisor,travel-frens-runner}.ts`; target test suites | Large | App-specific commands, Maestro/iOS, Playwright, databases, service accounts | Rewrite it for the new product |
| Historical run artifacts and issue content | GitHub Actions, Linear, runner-local memory | Variable | Provider retention and user/data terms | Keep as an example only |

## 8. What has to change to make it general

| Change | Why it's needed | Effort | Issue |
| --- | --- | --- | --- |
| Define a versioned package boundary for normalized events, policy decisions, QA dispatch, outcomes, and evidence | Centaur and the QA runner currently exchange implicit, provider-shaped contracts across repositories | M (3–5 days) | [ENG-1517](https://linear.app/voytravel/issue/ENG-1517/define-versioned-automation-and-qa-transfer-contracts) |
| Extract the trusted target/profile registry and command adapters from Voy defaults | Only two hard-coded targets are supported; profiles embed app paths, bundle IDs, commands, and runner labels | L (1–2 weeks) | [ENG-1518](https://linear.app/voytravel/issue/ENG-1518/extract-trusted-qa-target-and-profile-registry-from-voy-defaults) |
| Separate the QA executor from the Voy workflow and runtime setup | Actions checkout, secrets, ref defaults, and reporting assume one organization and host repo | L (1–2 weeks) | [ENG-1519](https://linear.app/voytravel/issue/ENG-1519/make-adaptive-qa-executor-portable-across-host-repositories) |
| Inventory and package the missing `linear_qa_control_plane` workflow; test dispatch → outcome → report across repos | Centaur names this workflow, but its implementation is not in the checked-out Centaur or Voy trees | M (3–5 days) | [ENG-1520](https://linear.app/voytravel/issue/ENG-1520/inventory-and-package-centaur-qa-dispatch-workflow) |
| Create a clean transfer inventory and sanitized sample data | Ownership, third-party notices, runner artifacts, issue text, screenshots, and credentials need a documented transfer disposition | M (3–5 days, plus counsel review) | [ENG-1521](https://linear.app/voytravel/issue/ENG-1521/prepare-agent-automation-and-qa-bot-ip-transfer-inventory) |

## 9. Licensing and data constraints

- **Code itself:** Centaur declares dual `Apache-2.0 OR MIT`. Voy's root `LICENSE` is an MIT text naming Julius Marminge; that file alone does not establish title to later QA-bot contributions or the right to transfer them. Verify contributor/employment assignments, third-party packages, copied prompts/fixtures, and any separately deployed workflow before an IP transaction. No ownership conclusion is made here.
- **Data feeding it:** GitHub/Linear issue and pull-request metadata, repository contents, test fixtures, screenshots, provider/model responses, and optional database branches. Transfer or reuse depends on each provider agreement, repository permissions, fixture provenance, and applicable customer commitments; review these separately from code.
- **User data:** Issue descriptions/comments, code changes, logs, screenshots, traces, model prompts/reports, and optional runner-local memory can contain personal, customer, or confidential data. Do not include historical artifacts or live credentials in a code transfer by default. Define retention, deletion, redaction, and any consent/legal basis before reusing real run data for a new product.

## 10. Known limitations

- The QA runner's trusted target manifest supports only two repositories and explicitly says it is not a supported extension API.
- QA coverage is selected-profile coverage; skipped checks or missing evidence are inconclusive. The September 2026 run audit sampled 20 run listings and found setup failures, a recurring assertion failure, skipped checks, and a report delivery gap; it was not a full production reliability study.
- iOS checks require a working macOS/Xcode/Maestro runner. Model outage can leave deterministic checks usable while adaptive or visual assessment is incomplete.
- The cross-repository control-plane workflow and its deployment configuration were not available in the two code trees inspected, so its portability and end-to-end behavior require separate verification.
- Current state names, default refs, target profiles, optional Slack notices, and reporting text are installation-specific. GitHub/Linear are the implemented providers.

## 11. Extraction plan

| Phase | Work | Effort |
| --- | --- | --- |
| 0. Inventory and clearance | Confirm technical/IP owner, locate control-plane workflow, enumerate code/dependencies/data and license obligations | 3–5 days plus counsel review |
| 1. Contract and isolation | Version the event/dispatch/outcome schemas, isolate provider adapters and policy ports, preserve fail-closed tests | 1–2 weeks |
| 2. QA portability | Move target/profile definitions to trusted configuration, separate product adapters, make runner/ref/secrets configurable | 1–2 weeks |
| 3. Pilot | Integrate one non-Voy repository with sanitized fixtures; exercise authorized, rejected, duplicate, blocked, failed, and passing flows end to end | 1–2 weeks |

## 12. Open decisions before Phase 1

- Which entity owns each contribution, and who has authority to approve an IP transfer? Michael Wu is the likely technical contact, not a verified rights holder.
- Does the transferee receive Centaur as a dependency, a fork, or a separately versioned automation package? What license and support obligations follow?
- Where is the deployed `linear_qa_control_plane` workflow source, and is it included in scope?
- Which provider integrations, test adapters, and model providers are in the initial product boundary?
- May any historical issues, run artifacts, screenshots, memory, or fixtures be transferred, or must the pilot use synthetic data?

## 13. References

- Centaur: [`docs/pages/operate/repository-automations.mdx`](../pages/operate/repository-automations.mdx), [`services/console/app/models/automation_policy.rb`](../../services/console/app/models/automation_policy.rb), [`services/console/app/services/automation_event_ingestor.rb`](../../services/console/app/services/automation_event_ingestor.rb), [`services/console/app/services/automation_qa_dispatch.rb`](../../services/console/app/services/automation_qa_dispatch.rb), [`services/githubbot/src/pr-manager.ts`](../../services/githubbot/src/pr-manager.ts), [`services/linearbot/src/automation.ts`](../../services/linearbot/src/automation.ts).
- Voy: `scripts/qa-bot/{targets,profiles,adapters,report}.ts`, `scripts/qa-bot/workflow-outcome.mjs`, `.github/workflows/qa-bot.yml`, `docs/qa-bot/README.md`, and `docs/qa-bot/run-audit-2026-09.md` in `voytravel/voy`.
- Licenses: Centaur `LICENSE`; Voy `LICENSE`. Existing Linear work: ENG-900, ENG-911, ENG-1362, ENG-1363, ENG-1365, ENG-1390.
