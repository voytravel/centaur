require "test_helper"

class AutomationIngressContractV1Test < ActiveSupport::TestCase
  test "accepts the existing normalized provider identities" do
    github = {
      "provider" => "github", "event_type" => "pull_request",
      "deduplication_key" => "github:delivery-1:9",
      "repository" => "acme/widgets", "subject_number" => 9
    }
    linear = {
      "provider" => "linear", "event_type" => "Issue",
      "deduplication_key" => "linear:delivery-1",
      "linear_issue_id" => "issue-42", "linear_team_id" => "team-1"
    }

    assert_nil AutomationIngressContractV1.validate!(github)
    assert_nil AutomationIngressContractV1.validate!(linear)
  end

  test "rejects a missing provider identity before policy evaluation" do
    event = {
      "provider" => "github", "event_type" => "pull_request",
      "deduplication_key" => "github:delivery-1:9", "subject_number" => 9
    }

    assert_raises(AutomationEventIngestor::InvalidEvent) do
      AutomationIngressContractV1.validate!(event)
    end
  end
end
