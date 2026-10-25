require "test_helper"

module Api
  module V1
    class SandboxAutomationInteractionReviewsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @proxy = proxies(:acme_proxy)
      end

      test "returns a bounded aggregate snapshot only to the dedicated read principal" do
        @proxy.principal.update!(
          sandbox_sessions_read_enabled: true,
          sandbox_workflows_read_enabled: true
        )
        snapshot = {
          "schema_version" => 1,
          "window" => { "days" => 7 },
          "availability" => { "workflow_runs" => "available" },
          "evidence" => []
        }
        builder = ->(days:) do
          assert_equal "7", days
          Struct.new(:as_json).new(snapshot)
        end

        with_env("CENTAUR_JWT_SIGNING_SECRET" => "test-secret") do
          AutomationInteractionReviewSnapshot.stub(:new, builder) do
            get "/api/v1/sandbox/automation_interaction_review", params: { days: 7 }, headers: auth_headers(token_for(@proxy))
          end
        end

        assert_response :ok
        assert_equal snapshot, JSON.parse(response.body).fetch("data")
        assert_equal "no-store", response.headers["Cache-Control"]
      end

      test "denies a sandbox without both aggregate-read capabilities" do
        with_env("CENTAUR_JWT_SIGNING_SECRET" => "test-secret") do
          get "/api/v1/sandbox/automation_interaction_review", headers: auth_headers(token_for(@proxy))
        end

        assert_response :forbidden
      end

      private

      def auth_headers(token)
        { "Authorization" => "Bearer #{token}" }
      end

      def token_for(proxy)
        SandboxEntitlements::Jwt.encode_for_proxy(proxy)
      end
    end
  end
end
