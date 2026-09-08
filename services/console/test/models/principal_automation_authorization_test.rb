require "test_helper"

class PrincipalAutomationAuthorizationTest < ActiveSupport::TestCase
  # This test must cross a real commit boundary because the production
  # authorization hook is after_create_commit. Transactional fixtures defer
  # that hook until test teardown.
  self.use_transactional_tests = false

  setup do
    @suffix = SecureRandom.hex(8)
    @issue_id = "issue-#{@suffix}"
    @role = Role.create!(
      foreign_id: "automation-commit-#{@suffix}",
      name: "Automation commit role #{@suffix}",
      labels: { Role::AUTOMATION_EXECUTION_LABEL => "true" },
      created_by: users(:acme_admin)
    )
    @policy = AutomationPolicy.create!(
      name: "Automation commit policy #{@suffix}",
      provider: "linear",
      linear_team_id: "team-#{@suffix}",
      enabled: true,
      mode: "act",
      execution_role: @role,
      created_by: users(:acme_admin),
      settings: {
        "linear" => {
          "issue" => "ready_issues",
          "github_repository" => "acme/widgets"
        }
      }
    )
    AutomationEventIngestor.new(
      "provider" => "linear",
      "deduplication_key" => "issue-#{@suffix}-v1",
      "event_type" => "Issue",
      "event_action" => "create",
      "linear_issue_id" => @issue_id,
      "linear_team_id" => @policy.linear_team_id,
      "title" => "Implement it",
      "description" => "Ready to ship",
      "labels" => []
    ).call
  end

  teardown do
    AutomationWorkstream.where(subject_key: "linear:#{@issue_id}").destroy_all
    @policy&.destroy! if @policy&.persisted?
    PrincipalRole.where(principal: @principal, role: @role).delete_all if @principal
    @principal&.destroy! if @principal&.persisted?
    @role&.destroy! if @role&.persisted?
  end

  test "a committed Linear issue principal receives its act policy role" do
    @principal = Principal.create!(
      foreign_id: "linear-issue-commit-#{@suffix}",
      name: "ENG-42",
      kind: "linear_issue",
      labels: { "linear_issue_id" => @issue_id },
      created_by: users(:acme_admin)
    )

    workstream = AutomationWorkstream.find_by!(subject_key: "linear:#{@issue_id}")
    assert_equal @principal, workstream.principal
    assert_equal @role, workstream.authorization_role
    assert_includes @principal.reload.roles, @role
  end
end
