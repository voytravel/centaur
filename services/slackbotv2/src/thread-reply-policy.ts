import type { SlackbotV2Options } from './types'

/**
 * Controls which unmentioned replies in a Slack thread that Centaur has
 * previously subscribed to may start a new execution.
 *
 * `mentions_only` is the fail-closed default. `actionable` accepts only an
 * explicit request addressed to the agent; ordinary discussion remains
 * thread context for the next mention. `all` is legacy compatibility mode.
 */
export type SlackThreadReplyMode = 'mentions_only' | 'actionable' | 'all'

export type SlackThreadReplyDecision =
  | { kind: 'ignore'; reason: 'not_explicitly_addressed' }
  | { kind: 'investigate'; reason: 'explicit_read_only_request' }
  | { kind: 'act'; reason: 'explicit_action_request' }
  | { kind: 'continue'; reason: 'legacy_all_mode' }

const ACTION_VERB_SOURCE = [
  'fix',
  'implement',
  'change',
  'update',
  'create',
  'open',
  'merge',
  'deploy',
  'commit',
  'push',
  'retry',
  'rerun',
  'run',
  'write',
  'edit',
  'delete',
  'close',
  'assign',
  'post',
  'send',
  'test',
  'validate',
  'verify',
  'build',
  'make'
].join('|')

const READ_ONLY_VERB_SOURCE = [
  'investigate',
  'look\\s+into',
  'check',
  'debug',
  'diagnos(?:e|is)',
  'trace',
  'analy[sz]e',
  'assess',
  'review',
  'explain',
  'inspect',
  'confirm',
  'compare',
  'find',
  'identify'
].join('|')

const ACTION_VERB_PATTERN = new RegExp(`^(?:${ACTION_VERB_SOURCE})$`, 'i')
const READ_ONLY_VERB_PATTERN = new RegExp(`^(?:${READ_ONLY_VERB_SOURCE})$`, 'i')
const DIRECTIVE_VERB_SOURCE = `(?:${ACTION_VERB_SOURCE}|${READ_ONLY_VERB_SOURCE})`

// Each pattern captures only the directive verb. Classification must never
// scan the rest of a request: "Please investigate why the failed run..." is
// read-only even though its object happens to contain an action verb.
const DIRECTIVE_PATTERNS = [
  new RegExp(
    String.raw`\b(?:can|could|would|will)\s+(?:you|centaur)\s+(?:please\s+)?(${DIRECTIVE_VERB_SOURCE})\b`,
    'i'
  ),
  new RegExp(
    String.raw`\b(?:i\s+(?:need|want)\s+(?:you|centaur)\s+to)\s+(?:please\s+)?(${DIRECTIVE_VERB_SOURCE})\b`,
    'i'
  ),
  // A polite direct request. Restrict this to a command verb so a casual
  // "please see above" cannot start a sandbox.
  new RegExp(String.raw`\b(?:please|pls|kindly)\s+(${DIRECTIVE_VERB_SOURCE})\b`, 'i'),
  // Imperative requests addressed to the beginning of the message. This
  // intentionally does not match "I think we should fix it" discussion.
  new RegExp(
    String.raw`^\s*(?:@(?:centaur|[A-Z0-9]+)[,:]?\s*)?(${DIRECTIVE_VERB_SOURCE})\b`,
    'i'
  )
]

/**
 * Resolves the new explicit setting first. The boolean remains for existing
 * deployments: true preserves their historical "all" behavior until they
 * opt in to the safer actionable mode.
 */
export function slackThreadReplyMode(options: SlackbotV2Options): SlackThreadReplyMode {
  if (options.threadReplyMode) return options.threadReplyMode
  return options.continueThreadReplies === true ? 'all' : 'mentions_only'
}

/**
 * Does not use an LLM deliberately. This is an execution gate, so uncertain
 * conversational text must fail closed and remain available as Slack context
 * on a later explicit mention.
 */
export function classifySlackThreadReply(text: string): SlackThreadReplyDecision {
  const normalized = text.replace(/\s+/g, ' ').trim()
  const directiveVerb = normalized ? matchedDirectiveVerb(normalized) : undefined
  if (!directiveVerb) {
    return { kind: 'ignore', reason: 'not_explicitly_addressed' }
  }
  if (ACTION_VERB_PATTERN.test(directiveVerb)) {
    return { kind: 'act', reason: 'explicit_action_request' }
  }
  if (READ_ONLY_VERB_PATTERN.test(directiveVerb)) {
    return { kind: 'investigate', reason: 'explicit_read_only_request' }
  }
  // The direct-request detector only permits known verbs, but retain a safe
  // read-only fallback if the patterns evolve independently.
  return { kind: 'investigate', reason: 'explicit_read_only_request' }
}

function matchedDirectiveVerb(text: string): string | undefined {
  for (const pattern of DIRECTIVE_PATTERNS) {
    const value = pattern.exec(text)?.[1]?.trim()
    if (value) return value
  }
  return undefined
}

export function slackThreadReplyDecision(
  mode: SlackThreadReplyMode,
  text: string
): SlackThreadReplyDecision {
  if (mode === 'mentions_only') return { kind: 'ignore', reason: 'not_explicitly_addressed' }
  if (mode === 'all') return { kind: 'continue', reason: 'legacy_all_mode' }
  return classifySlackThreadReply(text)
}

/**
 * Kept separate from the base sandbox prompt so that this transport-level
 * authorization distinction survives an overlay prompt change.
 */
export function slackThreadReplyInstruction(
  decision: Extract<SlackThreadReplyDecision, { kind: 'investigate' | 'act' }>
): string {
  const common = [
    '# Unmentioned Slack Thread Continuation',
    '',
    'This follow-up was admitted because it is an explicit request in a thread previously started by a valid Centaur mention.',
    'It does not establish a verified requester identity or grant additional permissions.'
  ]
  if (decision.kind === 'act') {
    return [
      ...common,
      '',
      'The user explicitly requested an action. Stay within that stated scope and follow the normal permission and confirmation rules.',
      '---'
    ].join('\n')
  }
  return [
    ...common,
    '',
    'The user requested investigation, analysis, review, or an explanation only.',
    'Do not edit files, commit, push, create or modify a pull request, deploy, or perform another external mutation.',
    'Treat a code path as a hypothesis until the specific record, event, or execution is verified. If live evidence is unavailable, say so plainly.',
    '---'
  ].join('\n')
}
