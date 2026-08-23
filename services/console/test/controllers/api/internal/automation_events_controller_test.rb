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
