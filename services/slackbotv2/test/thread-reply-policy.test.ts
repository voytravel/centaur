import { describe, expect, test } from 'bun:test'
import {
  classifySlackThreadReply,
  slackThreadReplyDecision,
  slackThreadReplyInstruction,
  slackThreadReplyMode
} from '../src/thread-reply-policy'

describe('Slack thread reply policy', () => {
  test('fails closed for ordinary discussion and corrections', () => {
    expect(classifySlackThreadReply('Agreed with Blaze — that diagnosis sounds off.')).toEqual({
      kind: 'ignore',
      reason: 'not_explicitly_addressed'
    })
    expect(classifySlackThreadReply('I think we should fix the gate.')).toEqual({
      kind: 'ignore',
      reason: 'not_explicitly_addressed'
    })
  })

  test('accepts explicit read-only requests', () => {
    expect(classifySlackThreadReply('Can you investigate how this record entered the pool?')).toEqual({
      kind: 'investigate',
      reason: 'explicit_read_only_request'
    })
    expect(classifySlackThreadReply('Please check the deployment logs.')).toEqual({
      kind: 'investigate',
      reason: 'explicit_read_only_request'
    })
    expect(classifySlackThreadReply('Please check why the failed run produced X.')).toEqual({
      kind: 'investigate',
      reason: 'explicit_read_only_request'
    })
    expect(classifySlackThreadReply('Please investigate the crash; do not run anything.')).toEqual({
      kind: 'investigate',
      reason: 'explicit_read_only_request'
    })
    expect(classifySlackThreadReply('Can you analyze the failed build output?')).toEqual({
      kind: 'investigate',
      reason: 'explicit_read_only_request'
    })
  })

  test('distinguishes explicit requested actions from investigations', () => {
    expect(classifySlackThreadReply('Fix the failing test and open a draft PR.')).toEqual({
      kind: 'act',
      reason: 'explicit_action_request'
    })
    expect(classifySlackThreadReply('Could you deploy the verified fix?')).toEqual({
      kind: 'act',
      reason: 'explicit_action_request'
    })
  })

  test('maps modes safely and keeps the legacy boolean compatible', () => {
    expect(slackThreadReplyMode({ apiUrl: 'http://api', botToken: 'x', signingSecret: 'x' })).toBe(
      'mentions_only'
    )
    expect(
      slackThreadReplyMode({
        apiUrl: 'http://api',
        botToken: 'x',
        continueThreadReplies: true,
        signingSecret: 'x'
      })
    ).toBe('all')
    expect(
      slackThreadReplyMode({
        apiUrl: 'http://api',
        botToken: 'x',
        continueThreadReplies: true,
        signingSecret: 'x',
        threadReplyMode: 'actionable'
      })
    ).toBe('actionable')
    expect(slackThreadReplyDecision('mentions_only', 'Fix this.').kind).toBe('ignore')
    expect(slackThreadReplyDecision('all', 'Anything at all.').kind).toBe('continue')
  })

  test('makes read-only continuation constraints explicit to the harness', () => {
    const instruction = slackThreadReplyInstruction({
      kind: 'investigate',
      reason: 'explicit_read_only_request'
    })
    expect(instruction).toContain('Do not edit files, commit, push, create or modify a pull request, deploy')
    expect(instruction).toContain('does not establish a verified requester identity')
  })
})
