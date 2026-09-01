# githubbot

GitHub ingress for the Centaur agent. Mirrors `linearbot` (session-backed replies) in a
**comment-thread model**: a GitHub PR or issue comment thread maps to one centaur sandbox/context,
and the bot answers *in the thread* with a comment. It's built on the official
[`@chat-adapter/github`](https://www.npmjs.com/package/@chat-adapter/github) chat-SDK adapter, so
the session logic (`session-api.ts`) and rendering are the same as the other bots; the Rust `api-rs`
control plane is unchanged (`github:…` thread keys flow through identically).

The bot acts as a **real GitHub teammate**: it authenticates with either a
personal access token or a fixed GitHub App installation, so it can be
`@`-mentioned, assigned, and **requested as a reviewer** like any other
collaborator.

## Behavior

- **`@`-mentioning the bot in an issue or PR comment** (Conversation tab) or a **PR review comment**
  (Files changed tab) → the bot answers in that thread, keyed `github:{owner}/{repo}:{prNumber}`
  (PR/issue level) or `github:{owner}/{repo}:{prNumber}:rc:{commentId}` (a review-comment thread) —
  one thread === one sandbox/context stack. For a **review-comment thread** the file path, line, and
  diff hunk it's anchored to are injected into the turn so the agent knows exactly what it's looking
  at; for a **PR conversation thread** the agent is pointed at `gh pr view`/`gh pr diff` to fetch the
  PR itself. A 👀 reaction acks the triggering comment while the bot works, settling to 🚀 / 😕. The
  reply begins with a concise acknowledgement, followed by a concise verified outcome. Execution
  reasoning, task commands, and raw tool output stay in Console rather than appearing in GitHub.
  The terminal reply is accepted only from the structured execution result behind a compact
  `GITHUB_SUMMARY:` block; a missing or unsafe summary falls back to a safe status note and emits
  `githubbot_public_summary_unavailable` for operational rate monitoring. A complete five-field
  summary is deterministically rendered as a compact Markdown update, so a model omitting line
  breaks cannot create a wall of public text.
  Mention detection is the adapter's (matches the bot account's `@username`). Only authors
  whose GitHub `author_association` is allowed (default `OWNER` / `MEMBER` / `COLLABORATOR`) can drive
  a turn — the agent runs in a write-capable sandbox and posts a concise result back, so untrusted
  commenters can't steer it. Widen or open it with `GITHUBBOT_ALLOWED_AUTHOR_ASSOCIATIONS` (`*` allows
  everyone, e.g. a fully-private repo). Lifecycle triggers (assignment, review-request) are already
  gated by GitHub permissions, so this applies only to the comment path.
- **`@`-mentioning the bot in the body of a newly-opened issue or PR** (the description, not a
  comment) → the same conversational turn runs, keyed to that issue/PR thread, with the reply posted
  as a comment. Only the `opened` event is handled — an edit that adds a mention later won't
  re-trigger, so re-issue it as a comment. Same author gate as the comment path.
- **Plain comments in a thread the bot is already active in** (no mention) are appended to that
  thread's session as append-only context — no execution, no reply — so a follow-up like "actually,
  hold off" is seen by the next turn. The bot's own comments are skipped (loop guard) and inactive
  threads are ignored.
- **Requesting the bot's review on a PR** (`pull_request` / `review_requested` targeting the bot
  account — or a **team the bot belongs to**, whose membership is checked and briefly cached) → a
  review turn runs on a **dedicated, isolated session thread**
  (`github-review:{owner}/{repo}:{prNumber}`) — kept separate from the PR conversation so reviews
  never share a sandbox with chit-chat, but persistent per PR so a re-request builds on the prior
  review. The chat adapter only surfaces comment threads, so this lifecycle event is handled
  directly: githubbot verifies the webhook signature itself, and the agent reviews the PR in its
  sandbox, posting inline comments + a summary via `gh`. The **review methodology** is a bundled,
  standalone default (`src/review-prompt.ts`) — good and reliable with zero config — that a
  deployment can **fully replace** via `GITHUBBOT_REVIEW_PROMPT` / `GITHUBBOT_REVIEW_PROMPT_FILE`
  (the override is used verbatim, so org conventions supersede ours wholesale; for Splits this is
  where the overlay supplies its review guide). Webhook redeliveries are de-duplicated by delivery id.
- **Assigning an issue to the bot** (`issues` / `assigned` to the bot account) → an autonomous work
  turn runs on a **dedicated, isolated session thread** (`github-issue:{owner}/{repo}:{n}`): the agent
  reads the issue, implements a fix in its sandbox, and opens a PR (self-assigning it so it then
  manages that PR toward merge). Like reviews, this lifecycle event is handled directly (githubbot
  verifies the signature) and de-duplicated by delivery id. The **issue-work methodology** is a
  bundled, standalone default (`src/issue-prompt.ts`) that a deployment can **fully replace** via
  `GITHUBBOT_ISSUE_PROMPT` / `GITHUBBOT_ISSUE_PROMPT_FILE` (used verbatim, like the review prompt).
- **Per-turn context**: every turn prepends a compact header naming the PR/issue so a recycled
  sandbox always knows which subject to act on and where to reply.
- `--claude` / `--codex` / `--model …` / `--opus|--sonnet|--haiku` inline flags pick the
  harness/model, same as the other bots.

## PR self-management (v2)

For PRs the bot **owns** — i.e. **assigned to the bot account** — githubbot drives the PR toward merge
by reacting to lifecycle webhooks. Ownership is purely an assignment mechanism: assign a PR to the bot
to have it take over, and unassign to hand it back. Bot-owned work runs on a dedicated management thread
(`github-manage:{owner}/{repo}:{n}`); the agent does its GitHub writes via `gh`.

- **Take over on assign.** Being assigned a PR is the explicit signal to take it over, so the bot
  immediately evaluates CI (fixing red or merging green) rather than waiting for the next lifecycle
  event.
- **Fix CI.** When **all** checks for a head SHA are settled (not per failing job — interwoven jobs
  make early firing harmful) and red, a fix turn diagnoses and pushes a fix. Bounded to
  `GITHUBBOT_CI_FIX_MAX_ATTEMPTS` consecutive attempts (default 3, reset when CI goes green); on
  exhaustion the bot comments tagging a human and stops. On the steady-state CI path it backs off if
  the failing head commit was authored by a human (it won't step on someone mid-edit) — except right
  after assignment, where being assigned is an explicit hand-off, so it fixes the PR regardless of who
  pushed last.
- **Address review.** A submitted review (`changes_requested` / `commented`) triggers one holistic
  turn that independently validates the feedback, makes only supported changes in a single coherent
  commit, replies on each thread, and resolves what it addressed. It never re-requests an external
  AI reviewer: Centaur-owned cross-model profiles are invoked internally, while a human deliberately
  chooses any separate GitHub review bot. Human reviews remain authoritative. Each external reviewer
  bot gets its own bounded response budget, and an aggregate epoch cap prevents adding bots from
  multiplying the loop. At either cap, Githubbot comments that human validation is required instead
  of continuing automatically.
- **Merge when ready.** Deterministic — no agent. When GitHub reports the PR `mergeable_state == clean`
  the bot merges it (`GITHUBBOT_MERGE_METHOD`, default squash) and deletes the branch. `dirty` →
  conflict-resolution turn; `behind` → branch update; anything else → wait. Enabled by default for
  owned PRs; disable globally with `GITHUBBOT_AUTO_MERGE=false`, or per-PR with the hold label
  (`GITHUBBOT_HOLD_LABEL`, default `do-not-merge`) or by keeping the PR a draft.
- **Owned-PR conversation.** An @-mention in an owned PR's conversation (or a review-comment thread)
  runs in that PR's management session too — so the bot answers with the context of the CI fixes and
  review work it's been doing on the PR — while the rendered reply still posts to the comment thread.
  An @-mention in the conversation of an **issue assigned to the bot** likewise runs in that issue's
  work session (`github-issue:…`), so the bot replies with the context of the work it's doing on it.

## Repository automation policies

When `CENTAUR_AUTOMATION_API_URL` and `CENTAUR_AUTOMATION_INGRESS_TOKEN` are
configured, signature-verified lifecycle events are also reduced to a compact
event summary and sent to Console. Console evaluates the repository's
declarative policy and persists its audit/workstream record. It never receives
the raw webhook body.

An **Act** policy can explicitly extend automation to eligible non-owned PRs:
automatic reviews, review-feedback repair, settled failing-check repair,
conflict resolution, and deterministic auto-merge. Every policy-driven action
continues the PR's existing `github-manage:{owner}/{repo}:{n}` session. The
policy route skips bot-owned PRs because their legacy lifecycle route already
owns that behavior.

Automatic review is organized into review epochs. Each epoch gets one broad or
new-risk-surface review plus two repair-validation rounds by default
(`GITHUBBOT_REVIEW_MAX_ROUNDS_PER_EPOCH=3`). Later rounds inspect only accepted
fixes, newly changed risk surfaces, and regressions—not the whole PR again.
Finding fingerprints persist in GitHub review comments, so line movement cannot
turn an accepted, rejected, or fixed finding into a new one.

A new production file, newly touched auth/data/API/infra boundary, dependency
manifest, or at least `GITHUBBOT_REVIEW_EPOCH_MIN_CHANGED_LINES` non-generated
changed lines (default 50) starts another epoch. Test/docs/generated-only
changes remain in the current epoch. A bot-authored material expansion pauses
for human approval instead of resetting its own budget. After
`GITHUBBOT_REVIEW_MAX_EPOCHS` automatic epochs (default 3), the PR must be split
or explicitly continued by requesting Githubbot as reviewer. A changed
authorization/security surface can still receive a narrowly scoped P0/security
inspection after the normal cap. The bundled methodology requires exact-line
evidence, a reachable failure path, material impact, and high confidence; it
omits speculative hardening, style nits, and unsupported states.

The epoch classifier is deterministic rather than model-decided. It combines
GitHub's head comparison with cumulative production-only PR diff growth, treats
pure rebases and detected whitespace-only changes as validation-round work, and
records its changed-line counts and exact paths as structured trace data. If a
PR exceeds the bounded 250-production-file inventory, automatic classification
pauses explicitly instead of silently forgetting part of the reviewed surface.
Codex, Cursor, Greptile, and other reviewer bots each get an independent bounded
response budget. A second PR/epoch-wide aggregate cap prevents adding reviewers
from multiplying the repair loop without starving the first follow-up from a
different reviewer.

A policy can instead opt into a bounded `review_orchestration` with two or three
independent internal reviewer profiles plus one synthesizer. Reviewers run in
isolated `github-review:` sessions and produce Console-only structured reports;
only the synthesizer may publish the one consolidated GitHub review for a PR
head. The profiles and synthesis run counters are reserved in the durable PR
epoch before work starts, so webhook redelivery cannot reset either budget.
Githubbot accepts a fallback only for provider unavailability or an explicitly
unsupported model capability. Authentication failures, cancellations, and
ambiguous errors remain fail-closed and are visible to operators. Execution
metadata records the requested/resolved harness and model, reviewer ID, epoch,
round, and fallback category without exposing provider error text in GitHub.

This orchestration controls Centaur-owned models only. Cursor, Greptile, Codex,
and other external GitHub reviewers remain independent reviewer identities;
Githubbot never requests or tags them itself. Their comments continue through
the existing per-reviewer repair budgets after a human has deliberately invoked
them.

No policy request is trusted without both a verified GitHub signature and the
single-purpose Console ingress credential. An unavailable or rejecting Console
fails closed, leaving normal requested-review, assigned-issue, and comment
paths unchanged. See [Repository Automations](/operate/repository-automations)
for rollout and operator configuration.

> **Scope.** v2 targets **same-repo PRs on repos you control** (where you own the webhook). The
> fork → upstream contribution flow (e.g. PRs against `paradigmxyz/centaur`) is out of scope: it
> needs the upstream repo to deliver webhooks to this bot, which isn't yours to configure.
>
> **Op requirement:** the agent's sandbox `git`/`gh` identity must be able to push to the managed
> PR branches (ideally authenticated as the bot account, so commits and replies come from it).

## Ingress model

GitHub delivers **HTTP webhooks** to `POST /api/webhooks/github` (content type **must** be
`application/json`). Comment events (`issue_comment`, `pull_request_review_comment`) are handed to the
chat adapter, which verifies the `X-Hub-Signature-256` HMAC and maps them to thread/message events.
Lifecycle events (`pull_request`, `pull_request_review`, `issues`, and the CI events) are handled by
githubbot directly (the adapter ignores them), so githubbot verifies the signature itself before acting. Turns run in the background — webhooks are acknowledged
immediately (cold sandbox spin-up far exceeds GitHub's webhook deadline), with a bounded retry inside
the turn for transient cold-start failures. On `SIGTERM` (a deploy/rollout) the bot stops accepting
webhooks and **drains in-flight turns** for up to `GITHUBBOT_SHUTDOWN_DRAIN_MS` before exiting, so
running work isn't dropped (claims are taken before the work, so a dropped turn would never retry).
It also **serializes turns targeting the same session** so two turns can't interleave git/push in one
sandbox. Both assume the **single replica** the chart runs (`replicaCount: 1`).

## Auth

A personal access token for the bot's GitHub teammate account (`GITHUB_TOKEN`) is supported for
legacy deployments. As a normal user account it is natively mentionable, assignable, and requestable
as a reviewer, and the token inherits that user's permissions. Scopes: **`repo`** (read PRs/issues, post and edit comments,
add reactions) — and, when the agent pushes branches or opens PRs from its sandbox, **`workflow`**.

For new deployments, prefer a fixed GitHub App installation: set `GITHUB_APP_ID`
(the App Client ID), `GITHUB_INSTALLATION_ID`, and either `GITHUB_PRIVATE_KEY`
or `GITHUB_PRIVATE_KEY_FILE`. The adapter mints short-lived installation tokens
itself; the PEM remains local to Githubbot and is never passed to an agent
sandbox. Configure exactly one authentication mode. The chart wires legacy PAT
mode from a separate `GITHUBBOT_TOKEN` secret key to avoid collision. Configure
`GITHUB_BOT_USERNAME` with the complete App actor login (for example,
`centaur-hz[bot]`); Githubbot retains that identity for lifecycle checks and
automatically recognizes the GitHub Markdown mention form `@centaur-hz`.

Webhook events to subscribe: **Issue comments**, **Pull request review comments**, **Issues**, **Pull
requests**, **Pull request reviews**, **Check runs**, **Check suites**, and **Workflow runs**
(**Issues** drives issue-work-on-assignment; the last four drive v2 PR self-management).

## Environment

| Var | Required | Notes |
|-----|----------|-------|
| `GITHUB_TOKEN` | One mode | PAT for the bot's teammate account. |
| `GITHUB_APP_ID`, `GITHUB_INSTALLATION_ID`, `GITHUB_PRIVATE_KEY` or `_FILE` | One mode | Fixed GitHub App installation credentials; preferred over a PAT. |
| `GITHUB_WEBHOOK_SECRET` | ✅ | Webhook signing secret (or `GITHUBBOT_WEBHOOK_SECRET`). |
| `GITHUB_BOT_USERNAME` | ✅ | The bot account's GitHub login — drives `@`-mention and requested-reviewer matching (or `GITHUBBOT_USER_NAME`). |
| `GITHUBBOT_DATABASE_URL` | ✅ | Postgres for chat-SDK state (falls back to `DATABASE_URL` / `POSTGRES_URL`). |
| `CENTAUR_API_URL` | — | api-rs control plane, default `http://127.0.0.1:8080`. |
| `CENTAUR_AUTOMATION_API_URL` | — | Console base URL for verified policy-event evaluation. Both automation variables must be set to enable it. |
| `CENTAUR_AUTOMATION_INGRESS_TOKEN` | — | Single-purpose bearer for Console's normalized automation-event endpoint; not an operator API key. |
| `GITHUBBOT_API_KEY` | — | Dedicated bearer sent to api-rs. |
| `GITHUBBOT_DEFAULT_HARNESS` | — | Harness for new threads without an inline flag, default `codex`. |
| `GITHUBBOT_REVIEW_PROMPT` | — | Full review methodology, inline. Replaces the bundled default verbatim. |
| `GITHUBBOT_REVIEW_PROMPT_FILE` | — | Path to a file holding the review methodology (e.g. an overlay-mounted file). Used when the inline var is unset. |
| `GITHUBBOT_ISSUE_PROMPT` | — | Full issue-work methodology, inline. Replaces the bundled default verbatim. |
| `GITHUBBOT_ISSUE_PROMPT_FILE` | — | Path to a file holding the issue-work methodology (e.g. an overlay-mounted file). Used when the inline var is unset. |
| `GITHUBBOT_MANAGEMENT_PROMPT` | — | Extra guidance prepended to owned-PR management turns (CI-fix / conflict / address-review), inline. The per-action preamble still rides underneath. |
| `GITHUBBOT_MANAGEMENT_PROMPT_FILE` | — | Path to a file holding the management guidance (e.g. an overlay-mounted file). Used when the inline var is unset. |
| `GITHUBBOT_ALLOWED_AUTHOR_ASSOCIATIONS` | — | Comma-separated `author_association` values allowed to drive the comment path. Default `OWNER,MEMBER,COLLABORATOR`; `*` allows everyone. |
| `GITHUB_API_URL` | — | Override the GitHub REST base URL (GitHub Enterprise). |
| `GITHUBBOT_USER_ID` | — | Bot's numeric user id for self-message detection (auto-detected otherwise). |
| `GITHUBBOT_STATE_KEY_PREFIX` | — | Chat-SDK state key prefix, default `centaur-githubbot`. |
| `GITHUBBOT_LOG_LEVEL` | — | `debug`/`info`/`warn`/`error`, default `info`. |
| `GITHUBBOT_AUTO_MERGE` | — | Auto-merge owned PRs when mergeable. Default `true`. |
| `GITHUBBOT_MERGE_METHOD` | — | `merge` / `squash` / `rebase`. Default `squash`. |
| `GITHUBBOT_HOLD_LABEL` | — | Label that pauses auto-merge. Default `do-not-merge`. |
| `GITHUBBOT_CI_FIX_MAX_ATTEMPTS` | — | Consecutive CI-fix attempts before escalating. Default 3. |
| `GITHUBBOT_REVIEW_MAX_ROUNDS_PER_EPOCH` | — | Broad/new-risk review plus repair-validation rounds per epoch. Default 3. |
| `GITHUBBOT_REVIEW_MAX_BOT_FEEDBACK_ROUNDS_PER_REVIEWER` | — | Repair responses allowed for each reviewer bot in an epoch. Default 3. |
| `GITHUBBOT_REVIEW_MAX_BOT_FEEDBACK_ROUNDS_PER_EPOCH` | — | Aggregate repair responses across all reviewer bots in an epoch. Default 6. |
| `GITHUBBOT_REVIEW_MAX_EPOCHS` | — | Material risk-surface epochs created automatically before split/explicit-continuation is required. Default 3. |
| `GITHUBBOT_REVIEW_EPOCH_MIN_CHANGED_LINES` | — | Non-generated diff growth that starts an epoch. New production files and boundary/dependency changes can start one below it. Default 50. |
| `GITHUBBOT_WORKFLOW_EVENTS` | — | Emit settled CI and submitted-review events to durable workflows. Default `false`. |
| `GITHUBBOT_DELETE_BRANCH_ON_MERGE` | — | Delete head branch after merge. Default `true`. |
| `GITHUBBOT_ESCALATION_HANDLE` | — | Fallback @handle (no leading @) tagged when the bot gives up. |
| `SESSION_IDLE_TIMEOUT_MS` / `SESSION_MAX_DURATION_MS` | — | Forwarded to api-rs executes. |
| `GITHUBBOT_SHUTDOWN_DRAIN_MS` | — | How long to let in-flight turns finish on `SIGTERM` before exiting. Default `25000`; the chart derives it from the pod's termination grace period. |

## Tests

`bun test test` — unit tests for the override flag parser, the GitHub thread-key parsing / context
preamble, the review-request trigger gating (incl. team requests), the issue-assignment gating, the
v2 PR-manager decision logic (CI evaluation, assignment-based ownership, merge gating, the CI-fix
counter / escalation, and the merge-claim release-on-failure), the author-association gate, body
mentions, and the per-session serialization queue.
