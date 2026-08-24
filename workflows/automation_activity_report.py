"""Deliver one compact, policy-authorized automation activity notice to Slack."""

from __future__ import annotations

from typing import Any

WORKFLOW_NAME = "automation_activity_report"
REPORT_KINDS = ("accepted", "pr_created")
SLACK_CHANNEL_PREFIXES = ("C", "G")
SLACK_MESSAGE_MAX_LENGTH = 3_800


def _required_string(params: Any, key: str) -> str:
    if not isinstance(params, dict):
        raise TypeError("automation_activity_report input must be an object")
    value = params.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"automation_activity_report requires {key}")
    return value.strip()


def _channel(params: Any) -> str:
    channel = _required_string(params, "channel").upper()
    if not channel.startswith(SLACK_CHANNEL_PREFIXES) or not channel[1:].isalnum():
        raise ValueError("automation_activity_report requires a public or private Slack channel ID")
    return channel


async def handler(params: Any, ctx: Any) -> dict[str, Any]:
    kind = _required_string(params, "kind")
    if kind not in REPORT_KINDS:
        raise ValueError(f"automation_activity_report does not support kind {kind}")

    channel = _channel(params)
    text = _required_string(params, "text")
    if len(text) > SLACK_MESSAGE_MAX_LENGTH:
        raise ValueError("automation_activity_report text is too long")

    delivery = await ctx.step(
        f"post_{kind}_activity",
        lambda: ctx.post_to_slack(
            channel,
            text,
            mrkdwn=True,
            unfurl_links=False,
            unfurl_media=False,
        ),
    )
    return {"kind": kind, "delivery": delivery}
