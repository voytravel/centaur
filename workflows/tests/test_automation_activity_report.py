from __future__ import annotations

import asyncio

from workflows import automation_activity_report


class FakeContext:
    def __init__(self) -> None:
        self.step_calls: list[str] = []
        self.step_results: dict[str, object] = {}
        self.slack_calls: list[tuple[str, str, dict[str, object]]] = []

    async def step(self, name, fn):
        self.step_calls.append(name)
        if name not in self.step_results:
            self.step_results[name] = await fn()
        return self.step_results[name]

    async def post_to_slack(self, channel, text, **kwargs):
        self.slack_calls.append((channel, text, kwargs))
        return {"channel": channel, "ts": "123.456"}


def test_handler_posts_one_checkpointed_accepted_notice():
    context = FakeContext()
    params = {
        "channel": "c0123456789",
        "kind": "accepted",
        "text": ":gear: *Centaur automation accepted*",
    }

    result = asyncio.run(automation_activity_report.handler(params, context))
    asyncio.run(automation_activity_report.handler(params, context))

    assert result == {"kind": "accepted", "delivery": {"channel": "C0123456789", "ts": "123.456"}}
    assert context.step_calls == ["post_accepted_activity", "post_accepted_activity"]
    assert context.slack_calls == [
        (
            "C0123456789",
            ":gear: *Centaur automation accepted*",
            {"mrkdwn": True, "unfurl_links": False, "unfurl_media": False},
        )
    ]


def test_handler_rejects_non_channel_destinations_and_unknown_kinds():
    context = FakeContext()

    try:
        asyncio.run(
            automation_activity_report.handler(
                {"channel": "U0123456789", "kind": "accepted", "text": "safe"}, context
            )
        )
    except ValueError as error:
        assert "public or private Slack channel" in str(error)
    else:
        raise AssertionError("expected channel validation failure")

    try:
        asyncio.run(
            automation_activity_report.handler(
                {"channel": "C0123456789", "kind": "completed", "text": "safe"}, context
            )
        )
    except ValueError as error:
        assert "does not support kind" in str(error)
    else:
        raise AssertionError("expected kind validation failure")

    assert context.step_calls == []
    assert context.slack_calls == []
