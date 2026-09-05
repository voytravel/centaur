# Binds a policy-selected execution role to precisely the derived platform
# principal for an authorized workstream. The webhook ingress never carries a
# role, secret, or principal ID: those are resolved from the durable policy and
# the platform identity that api-rs derives from the session key.
class AutomationPrincipalAuthorizer
  class << self
    def reconcile_principal(principal)
      workstreams_for(principal).find_each do |workstream|
        reconcile_workstream(workstream, principal)
      end
    end

    # Called after each normalized event and when an operator edits a policy.
    # It is deliberately safe when api-rs has not created the principal yet;
    # Principal's callback will retry once the platform session exists.
    def reconcile_workstream(workstream, principal = nil)
      if !authorizable?(workstream)
        revoke_workstream(workstream)
        return
      end

      principal ||= workstream.principal || principal_for(workstream)
      return unless principal

      bind(workstream, principal, workstream.automation_policy.execution_role)
    end

    def reconcile_policy(policy)
      policy.automation_workstreams.includes(:principal, :authorization_role).find_each do |workstream|
        reconcile_workstream(workstream)
      end
    end

    def revoke_policy(policy)
      policy.automation_workstreams.includes(:principal, :authorization_role).find_each do |workstream|
        revoke_workstream(workstream)
      end
    end

    private

    def authorizable?(workstream)
      policy = workstream.automation_policy
      return false unless policy&.enabled? && policy.act? && policy.execution_role

      # `active` is durable continuation state owned by AutomationEventIngestor.
      # It is set by an allowed Act event, survives unrelated lifecycle events
      # that have no configured action, and is changed to `blocked` by a
      # policy-safety rejection. Checking only the latest event decision would
      # revoke a valid PR's role before its next feedback/check/conflict event
      # could reuse the same authorized workspace.
      return false unless workstream.state == "active"

      # A policy can combine ready-issue coding with the deterministic QA
      # bridge. `run_qa` is a fixed workflow dispatch, not an agent turn, so a
      # QA transition must never attach the policy's model/repository role to
      # the Linear issue principal. Look at the last authorized action rather
      # than the latest event: ignored lifecycle noise is allowed to preserve a
      # preceding coding authorization, while a later QA transition revokes it.
      !latest_authorized_actions(workstream).include?("run_qa")
    end

    def latest_authorized_actions(workstream)
      record = workstream.automation_events
        .where(decision: "act")
        .order(received_at: :desc, id: :desc)
        .first
      record&.action_kind.to_s.split(",").map(&:strip).reject(&:blank?) || []
    end

    def workstreams_for(principal)
      case principal.kind
      when "linear_issue"
        issue_id = principal.labels.to_h["linear_issue_id"].to_s
        return AutomationWorkstream.none if issue_id.blank?

        AutomationWorkstream.where(provider: "linear", subject_key: "linear:#{issue_id}")
      when "github_pull_request"
        repository = principal.labels.to_h["github_repository"].to_s.downcase
        number = principal.labels.to_h["github_pull_request_number"].to_s
        return AutomationWorkstream.none unless repository.match?(%r{\A[^/\s]+/[^/\s]+\z}) && number.match?(/\A\d+\z/)

        AutomationWorkstream.where(
          provider: "github",
          subject_key: "github:#{repository}:pr:#{number}"
        )
      else
        AutomationWorkstream.none
      end
    end

    def principal_for(workstream)
      provider, subject = workstream.provider, workstream.subject_key
      case provider
      when "linear"
        issue_id = subject.delete_prefix("linear:")
        Principal.where(kind: "linear_issue")
          .where("labels ->> 'linear_issue_id' = ?", issue_id)
          .order(:id).first
      when "github"
        match = %r{\Agithub:([^/\s]+/[^/\s]+):pr:(\d+)\z}.match(subject)
        return unless match

        Principal.where(kind: "github_pull_request")
          .where("labels ->> 'github_repository' = ?", match[1].downcase)
          .where("labels ->> 'github_pull_request_number' = ?", match[2])
          .order(:id).first
      end
    end

    def bind(workstream, principal, role)
      old_principal = workstream.principal
      old_role = workstream.authorization_role
      return if old_principal == principal && old_role == role

      AutomationWorkstream.transaction do
        ensure_role(principal, role)
        workstream.update!(principal: principal, authorization_role: role)
        detach_role_if_unused(old_principal, old_role, except: workstream)
      end
    end

    # Preserve the derived principal for audit after revocation; only the role
    # association is cleared. The shared role is removed only when no other
    # currently authorized workstream still binds that principal to it.
    def revoke_workstream(workstream)
      role = workstream.authorization_role
      principal = workstream.principal
      return unless role && principal

      AutomationWorkstream.transaction do
        workstream.update!(authorization_role: nil)
        detach_role_if_unused(principal, role, except: workstream)
      end
    end

    def ensure_role(principal, role)
      principal.principal_roles.find_or_create_by!(role: role)
    rescue ActiveRecord::RecordNotUnique
      # Another webhook for the same durable workstream completed first.
      principal.principal_roles.find_by!(role: role)
    end

    def detach_role_if_unused(principal, role, except:)
      return unless principal && role
      return if AutomationWorkstream.where(principal: principal, authorization_role: role)
                                     .where.not(id: except.id).exists?

      principal.principal_roles.find_by(role: role)&.destroy!
    end
  end
end
