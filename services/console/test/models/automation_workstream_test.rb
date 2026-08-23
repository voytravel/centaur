require "test_helper"

class AutomationWorkstreamTest < ActiveSupport::TestCase
  test "derives a GitHub pull request source URL from the normalized subject" do
    workstream = AutomationWorkstream.new(
      provider: "github",
      repository: "voytravel/centaur",
      subject_key: "github:voytravel/centaur:pr:42",
      session_key: "github-manage:voytravel/centaur:42"
    )

    assert_equal "https://github.com/voytravel/centaur/pull/42", workstream.safe_source_url
  end

  test "does not form a GitHub source URL when the subject and repository disagree" do
    workstream = AutomationWorkstream.new(
      provider: "github",
      repository: "voytravel/centaur",
      subject_key: "github:other/repository:pr:42",
      session_key: "github-manage:voytravel/centaur:42"
    )

    assert_nil workstream.safe_source_url
  end

  test "keeps only a provider-owned Linear HTTPS issue URL" do
    workstream = AutomationWorkstream.new(
      provider: "linear",
      subject_key: "linear:issue-42",
      session_key: "linear:issue-42",
      metadata: {
        "linear_issue_url" => "https://linear.app/voytravel/issue/ENG-42/implement-it?tracking=one#activity"
      }
    )

    assert_equal "https://linear.app/voytravel/issue/ENG-42/implement-it", workstream.safe_source_url
  end

  test "does not render a non-Linear URL as a source link" do
    workstream = AutomationWorkstream.new(
      provider: "linear",
      subject_key: "linear:issue-42",
      session_key: "linear:issue-42",
      metadata: { "linear_issue_url" => "https://linear.app.example.test/issue/ENG-42" }
    )

    assert_nil workstream.safe_source_url
  end

  test "does not render a Linear host on a nonstandard port" do
    workstream = AutomationWorkstream.new(
      provider: "linear",
      subject_key: "linear:issue-42",
      session_key: "linear:issue-42",
      metadata: { "linear_issue_url" => "https://linear.app:444/issue/ENG-42" }
    )

    assert_nil workstream.safe_source_url
  end
end
