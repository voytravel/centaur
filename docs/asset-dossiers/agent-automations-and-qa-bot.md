# Agent automations and QA bot — asset one pager

**Asset class:** Software development automation and quality assurance

**Status:** Built; needs work before it can be used as a standalone product

**Owner:** Michael Wu

**Lives in:** `voytravel/centaur` (automation policies, agent and review bots), `voytravel/centaur-overlay` (`workflows/linear_qa_control_plane.py`, `tools/github-actions-qa/`), and `voytravel/voy` (`scripts/qa-bot/`, `.github/workflows/qa-bot.yml`).

**Last updated:** 2026-09-30

## 1. Summary

This system picks up approved work from an issue tracker or code repository, asks an agent to do the work, and checks the result. It can review and repair pull requests, run selected tests, and give people a report with links to the evidence. Its distinguishing feature is that a human sets the boundaries in advance: which work is eligible, what the agent may access, and when it must stop. The pieces already work together, but making them portable to another company or product is estimated at **4–8 engineering weeks**, plus ownership and data review.

## 2. What it does

- Watches for changes to issues and pull requests, then checks whether a human-approved rule allows action.
- Gives an agent a consistent workspace for each issue or pull request, so later events continue the same work.
- Helps an agent implement an issue, open a pull request, request reviewers, and gather preview evidence.
- Reviews pull requests, responds to feedback, investigates failed checks, and attempts bounded repairs.
- Starts QA when an issue reaches a chosen state, selects approved tests, and runs them against a known version of the code.
- Collects test results, logs, screenshots, and other evidence into a report people can inspect.

## 3. Out of scope

- A passing report does **not** mean every requirement was tested or that a release is defect-free.
- An issue or webhook cannot give the agent new permissions or choose an arbitrary repository or test command.
- This does not include another product's application code, test cases, data, credentials, or runner machines.
- The QA runner is not yet a general plug-in product. It currently knows two approved codebases.

## 4. Who would use it

A payments company could check API changes before release; a developer-tools company could review pull requests and test preview sites; an enterprise software team could run its own approved test suites and keep an audit trail.

## 5. Interface contract

- **Inputs:** Verified events from GitHub and Linear; rules set by an operator; approved repositories, test profiles, and access roles; issue and pull-request links.
- **Outputs:** A record of each decision, agent work and pull-request activity, test artifacts, and a report marked passed, failed, or blocked.
- **Ports the package would expose:** Event intake, rule decisions, QA run requests, test profile selection, and a versioned report format. These are the proposed boundaries for extraction; today they are spread across services.
- **Called as:** Service, worker, and command-line runner.

## 6. Guarantees (if any)

- An invalid or unapproved event must not start policy-driven work. Centaur's webhook and policy tests cover this path.
- Repeated delivery of the same event keeps one recorded event and checks the current rule before allowing more work. Centaur's event-ingestion tests cover this path.
- QA can start only from an approved QA action, using a known issue, repository, and test profile. Centaur dispatch tests and Voy runner tests cover these checks.
- Missing results, skipped tests, or missing required evidence cannot be reported as a verified QA pass. Voy's report and outcome tests cover this rule.

These are behavior checks in the code, not a promise that every deployment is correctly configured.

## 7. Transferability

| Layer | Lives in | Size | Dependencies | Can we reuse it? |
| --- | --- | --- | --- | --- |
| Rules, permissions, work history | Centaur Console | Large | Database and Centaur user/access system | Take it, small cleanup needed |
| Issue and pull-request bots | Centaur GitHubbot and Linearbot | Large | GitHub, Linear, Centaur sessions | Take it, small cleanup needed |
| Agent workspace and durable execution | Centaur API and sandbox | Very large | Database, Kubernetes, agent tools | Take it as is |
| QA coordination between systems | Centaur dispatch and Centaur Overlay's `linear_qa_control_plane.py` | Medium | Centaur workflow API, GitHub Actions | Take it, small cleanup needed |
| QA runner, evidence, and reports | Voy `scripts/qa-bot/` | Large | Node, GitHub Actions, test tools | Take it, small cleanup needed |
| Test profiles and application setup | Voy QA profiles and target test suites | Large | Product-specific code, devices, databases | Rewrite it for the new product |
| Past issues, screenshots, and run data | GitHub, Linear, runner storage | Variable | Provider and user-data rights | Keep as an example only |

## 8. What has to change to make it general

| Change | Why it's needed | Effort | Issue |
| --- | --- | --- | --- |
| Agree on the event, QA request, and report formats | The first contracts and compatibility checks are in place; the complete transfer format still needs a pilot | 3–5 days | [ENG-1517](https://linear.app/voytravel/issue/ENG-1517/define-versioned-automation-and-qa-transfer-contracts) |
| Make approved repositories and test profiles configurable | The runner currently names two codebases and embeds their test commands; defer internal changes until a later phase | 1–2 weeks | [ENG-1518](https://linear.app/voytravel/issue/ENG-1518/extract-trusted-qa-target-and-profile-registry-from-voy-defaults) |
| Make the QA runner installable outside Voy | Its workflow assumes Voy's checkout, secrets, runners, and report destination; defer internal changes until a later phase | 1–2 weeks | [ENG-1519](https://linear.app/voytravel/issue/ENG-1519/make-adaptive-qa-executor-portable-across-host-repositories) |
| Package the QA coordination workflow and its fixed executor adapter | Its source is now located in Centaur Overlay, but it still depends on a reviewed Voy-only route and Actions tool | 3–5 days | [ENG-1520](https://linear.app/voytravel/issue/ENG-1520/inventory-and-package-centaur-qa-dispatch-workflow) |
| Prepare an ownership and data inventory | A buyer needs to know what code and data can actually move | 3–5 days, plus legal review | [ENG-1521](https://linear.app/voytravel/issue/ENG-1521/prepare-agent-automation-and-qa-bot-ip-transfer-inventory) |

## 9. Licensing and data constraints

- **Code itself:** Centaur offers Apache-2.0 or MIT licensing. Voy's root license contains MIT terms but names an earlier copyright holder; it does not, by itself, prove ownership of later QA bot code. Centaur Overlay has no root license file in the inspected checkout. Check contributor agreements, third-party packages, and copied material before a transfer.
- **Data that feeds it:** Issues, pull requests, test fixtures, code, screenshots, and model responses come from different systems. Their terms and the organization's commitments determine what may be reused.
- **User data:** Reports and artifacts may contain customer details, personal information, private code, or secrets in logs. A transfer should use synthetic examples unless retention, redaction, permission, and deletion rules for real data have been settled.

## 10. Known limitations

The QA runner currently supports two named repositories. Some checks need a working macOS/iOS test machine; adaptive analysis also depends on a model provider. A September 2026 review of 20 QA run listings found setup failures, skipped tests, an assertion failure, and a report delivery gap. That sample is useful evidence, but it is not a full reliability study. The production QA coordination workflow is in Centaur Overlay; its destination remains deliberately fixed to Voy.

## 11. Extraction plan

| Phase | Work | Effort |
| --- | --- | --- |
| 0. Inventory | Confirm what is owned across all three repos and decide what data may move | 3–5 days plus legal review |
| 1. Define boundaries | Publish shared formats and isolate rules from GitHub/Linear-specific handling | 1–2 weeks |
| 2. Make QA portable | Package the current runner interface and host boundary first; defer runner internals, target configuration, and test changes to a later phase | 1–2 weeks for later runner work |
| 3. Pilot | Try one new codebase with synthetic data, including approved, rejected, failed, and passing cases | 1–2 weeks |

## 12. Open decisions before Phase 1

- Which entity owns each contribution, and who can approve its transfer?
- Will the recipient use Centaur itself or a separately packaged part of it?
- Is Centaur Overlay's production QA coordination workflow included in the transfer?
- Which code hosts, issue trackers, test tools, and model providers must the first transfer support?
- Can any historical issues, screenshots, reports, or test fixtures move, or should the recipient start with synthetic data?

## 13. References

- Centaur: [`Repository Automations`](../pages/operate/repository-automations.mdx), [`AutomationPolicy`](../../services/console/app/models/automation_policy.rb), [`AutomationEventIngestor`](../../services/console/app/services/automation_event_ingestor.rb), [`AutomationQaDispatch`](../../services/console/app/services/automation_qa_dispatch.rb), [`GitHub PR manager`](../../services/githubbot/src/pr-manager.ts), and [`Linear automation`](../../services/linearbot/src/automation.ts).
- Centaur Overlay: `workflows/linear_qa_control_plane.py`, `workflows/linear_qa_routes.json`, and `tools/github-actions-qa/` in `voytravel/centaur-overlay`.
- Voy: `scripts/qa-bot/`, `.github/workflows/qa-bot.yml`, `docs/qa-bot/README.md`, and `docs/qa-bot/run-audit-2026-09.md` in `voytravel/voy`.
- Existing work: ENG-900, ENG-911, ENG-1362, ENG-1363, ENG-1365, and ENG-1390. See Section 8 for the new extraction issues.
- Transfer review: [`agent-automations-transfer-inventory.md`](agent-automations-transfer-inventory.md) records the scoped code, dependencies, data categories, and unresolved rights checks.
