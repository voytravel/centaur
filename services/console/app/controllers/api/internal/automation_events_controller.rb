module Api
  module Internal
    class AutomationEventsController < ActionController::API
      before_action :authenticate_automation_ingress!

      rescue_from ActionController::ParameterMissing do |error|
        render json: { error: { message: error.message } }, status: :bad_request
      end
      rescue_from AutomationEventIngestor::InvalidEvent do |error|
        render json: { error: { message: error.message } }, status: :unprocessable_entity
      end

      def create
        result = AutomationEventIngestor.new(event_params.to_h).call
        render json: { data: result }
      end

      private

      # This is a single-purpose service credential, not an operator Console API
      # key. It can only submit normalized event summaries to this controller.
      def authenticate_automation_ingress!
        expected = ENV["CENTAUR_AUTOMATION_INGRESS_TOKEN"].to_s
        provided = request.authorization.to_s.delete_prefix("Bearer ").strip
        valid = expected.present? &&
          provided.present? &&
          provided.bytesize == expected.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(provided, expected)
        head :unauthorized unless valid
      end

      def event_params
        params.require(:event).permit(
          :provider,
          :deduplication_key,
          :event_type,
          :event_action,
          :repository,
          :subject_number,
          :head_sha,
          :base_branch,
          :draft,
          :mentioned_bot,
          :linear_issue_id,
          :linear_issue_identifier,
          :linear_issue_url,
          :linear_team_id,
          :linear_project_id,
          :title,
          :description,
          :status,
          :blocked,
          labels: []
        )
      end
    end
  end
end
