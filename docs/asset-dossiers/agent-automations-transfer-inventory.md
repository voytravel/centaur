# Agent automations and QA bot — transfer inventory (working copy)

**Technical owner:** Michael Wu

**Scope checked:** Centaur `main`, Centaur Overlay `main`, and Voy's local
`develop` branch as inspected on 2026-09-30. This inventory identifies what
must be reviewed; it is not a statement that every item can be transferred.

## Code and operation map

| Asset | Source | Transfer treatment |
| --- | --- | --- |
| Policy decisions, workstreams, role grants, event audit | Centaur `services/console/app/{models,services,jobs}/automation_*` and migrations | Reusable core; keep the same fail-closed rules and DB migration history |
| Verified provider ingress and pull-request lifecycle | Centaur `services/githubbot/`, `services/linearbot/` | Provider adapters; carry their signature, deduplication, and authorization tests |
| Durable agent execution and sandbox | Centaur `services/api-rs/`, `services/sandbox/`, `services/iron-proxy/` | Runtime dependency; include if the recipient runs the complete system |
| QA dispatch policy and fixed GitHub Actions client | Centaur Overlay `workflows/linear_qa_control_plane.py`, `workflows/linear_qa_routes.json`, `tools/github-actions-qa/` | Reviewed installation adapter; current production route remains Voy-only |
| Host policy and credentials wiring | Infra `centaur/hz/scripts/lib.sh`, `bootstrap-secrets.sh`, `configure-policy.sh`, and release manifests | Deployment example, with identifiers, host names, and credentials removed or replaced |
| QA runner and reports | Voy `scripts/qa-bot/`, `.github/workflows/qa-bot.yml` | Existing executor; its internals are deferred in this phase |
| Product test profiles, fixtures, and app setup | Voy `scripts/qa-bot/{targets,profiles,adapters,runtime-supervisor}.ts` and target test suites | Product-specific material to replace for a new customer |

## Rights and dependency checks

- Centaur declares `Apache-2.0 OR MIT` in its root `LICENSE`.
- Voy's root MIT license names Julius Marminge. Verify the provenance and
  assignments of later QA runner contributions independently of that file.
- Centaur Overlay has no root license file in the inspected checkout. Its README
  describes it as Voytravel-owned. Confirm title, contributor assignments, and
  transfer terms before including its workflow or tools.
- Commit history identifies Michael Wu as the main technical contributor to
  the scoped paths. Commit authorship alone does not establish IP title.
- Produce a dependency bill of materials from Centaur's Cargo, pnpm, Python,
  and Ruby locks, Voy's pnpm lock, and the overlay's Python packages. The
  inspected lockfiles are `pnpm-lock.yaml`, `services/console/Gemfile.lock`,
  `services/api-rs/Cargo.lock`, and `crates/harness-server/Cargo.lock` in
  Centaur, plus `pnpm-lock.yaml` in Voy. The overlay QA client declares its
  Python package in `tools/github-actions-qa/pyproject.toml`; it has no checked-in
  dependency lock. Review license texts and notices for the packages actually
  distributed with an install.
- Review model prompts, generated sample code, test images, and any imported
  third-party fixtures for separate rights or attribution requirements.

## Data disposition

| Data | Where it appears | Default transfer treatment |
| --- | --- | --- |
| Issue and pull-request text, comments, links | Linear/GitHub and Console audit | Exclude historical records; use synthetic examples |
| Source code and test fixtures | Target repositories and runner checkout | Include only code/fixtures with confirmed rights |
| QA logs, screenshots, traces, reports, model context | GitHub Actions artifacts, checks, issue comments, optional runner-local storage | Exclude historical artifacts; create sanitized demonstration runs |
| Customer or account data used by tests | Optional databases and API services | Exclude; create synthetic fixtures and scoped test accounts |
| Credentials and installation identities | Console/host secret stores, GitHub/Linear Apps, Actions secrets | Never transfer values; document required scopes and provision new identities |
| Runner hardware and cloud resources | GitHub Actions and host deployment | Document prerequisites; provision independently |

Voy's Actions workflow has artifact retention settings of 1, 14, and 30 days
for different outputs. Confirm the provider-side retention and deletion state
before relying on those settings as proof that old data is gone.

Use [the synthetic example set](examples/automation-transfer-sample.json) for
contract walkthroughs. Its names, IDs, decisions, and QA outcome are invented;
it is not an enabled route or proof of a customer pilot. Before a transfer,
export no historical issue records, source snapshots, QA artifacts, model
context, or credentials by default. An operator must inventory each selected
data store, confirm its retention and deletion controls with the provider, and
record the approved disposition and evidence of deletion or exclusion. Fresh
customer credentials, accounts, and test data must be provisioned separately.

## Release gate for a reusable package

1. Confirm the rights holder and commercial distribution terms for each repo.
2. Inventory the exact files and dependency versions in a pinned release.
3. Ship an installable package, reviewed customer configuration, synthetic
   examples, required notices, and a repeatable test report.
4. Prove one non-Voy installation against authorized, denied, duplicate,
   blocked, failed, and passing cases while Voy's own behavior remains the
   same.

**Open:** legal/title determination, full third-party dependency inventory,
data retention approvals, and permission to generalize the QA dispatch
destination. Track these in [ENG-1521](https://linear.app/voytravel/issue/ENG-1521/prepare-agent-automation-and-qa-bot-ip-transfer-inventory).
