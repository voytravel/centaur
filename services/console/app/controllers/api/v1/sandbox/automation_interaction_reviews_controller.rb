module Api
  module V1
    module Sandbox
      # Bounded, aggregate-only operational evidence for the isolated weekly
      # automation reviewer. This is intentionally separate from the Threads
      # API: it cannot retrieve conversation text, individual error payloads,
      # secrets, or arbitrary workflow results.
      class AutomationInteractionReviewsController < Api::SandboxBaseController
        before_action :require_interaction_review_capabilities!

        rescue_from AutomationInteractionReviewSnapshot::InvalidWindow do |error|
          render_error(status: :unprocessable_entity, message: error.message)
        end

        def show
          snapshot = AutomationInteractionReviewSnapshot.new(days: params.fetch(:days, "7")).as_json
          response.headers["Cache-Control"] = "no-store"
          render json: { data: snapshot }
        end

        private

        # Reuse the existing split read capabilities. The deployment grants
        # both only to the dedicated review workflow principal; a capability
        # must not be inferred from a user-controlled query parameter.
        def require_interaction_review_capabilities!
          principal = current_proxy&.principal
          return if principal&.sandbox_sessions_read_enabled && principal.sandbox_workflows_read_enabled

          render_error(
            status: :forbidden,
            message: "sandbox principal is not authorized for interaction-review evidence"
          )
        end
      end
    end
  end
end
