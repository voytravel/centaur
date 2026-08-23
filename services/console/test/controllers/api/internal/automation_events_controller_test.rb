require "test_helper"

class Api::Internal::AutomationEventsControllerTest < ActionDispatch::IntegrationTest
  test "rejects missing or invalid ingress credentials" do
    post api_internal_automation_events_url, params: { event: github_event }
    assert_response :unauthorized

    with_env("CENTAUR_AUTOMATION_INGRESS_TOKEN" => "expected") do
      post api_internal_automation_events_url,
           params: { event: github_event },
           headers: { "Authorization" => "Bearer wrong" }
    end
    assert_response :unauthorized
  end

  test "accepts a normalized event using the single-purpose ingress token" do
    with_env("CENTAUR_AUTOMATION_INGRESS_TOKEN" => "expected") do
      post api_internal_automation_events_url,
           params: { event: github_event },
           headers: { "Authorization" => "Bearer expected" },
           as: :json
    end

    assert_response :ok
    body = response.parsed_body.fetch("data")
    assert_equal "ignored", body["decision"]
    assert_equal "github-manage:acme/widgets:3", body["session_key"]
  end

  test "retains a normalized Linear source reference for the operator audit" do
    AutomationPolicy.create!(
      name: "Linear source reference",
      provider: "linear",
      linear_team_id: "team-1",
      enabled: true,
      mode: "observe",
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "github_repository" => "acme/widgets"
        }
      }
    )

    with_env("CENTAUR_AUTOMATION_INGRESS_TOKEN" => "expected") do
      post api_internal_automation_events_url,
           params: {
             event: {
               provider: "linear",
               deduplication_key: "linear-source-reference",
               event_type: "Issue",
               event_action: "update",
               linear_issue_id: "issue-1",
               linear_issue_identifier: "ENG-42",
               linear_issue_url: "https://linear.app/voytravel/issue/ENG-42/implement-it?tracking=one#activity",
               linear_team_id: "team-1",
               title: "Implement it",
               description: "Acceptance Criteria\n- Works",
               labels: []
             }
           },
           headers: { "Authorization" => "Bearer expected" },
           as: :json
    end

    assert_response :ok
    workstream = AutomationWorkstream.sole
    assert_equal "ENG-42", workstream.metadata["linear_issue_identifier"]
    assert_equal "https://linear.app/voytravel/issue/ENG-42/implement-it", workstream.metadata["linear_issue_url"]
  end

  private

  def github_event
    {
      provider: "github",
      deduplication_key: "delivery-test",
      event_type: "pull_request",
      event_action: "opened",
      repository: "acme/widgets",
      subject_number: 3
    }
  end
end
