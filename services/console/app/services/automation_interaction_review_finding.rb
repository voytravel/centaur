# Parses the bounded output of the scheduled interaction-review observer into a
# Console approval target. Narrative fields remain untrusted supporting data:
# they are rendered for an administrator and supplied to the action only inside
# a fixed contract that cannot widen the repository, branch, or mutation.
class AutomationInteractionReviewFinding
  WORKFLOW_NAME = "automation_interaction_review"
  ACTION_WORKFLOW_NAME = "automation_interaction_review_action"
  SCHEMA_VERSION = 1
  MAX_FINDINGS = 3

  REPOSITORY_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze
  BRANCH_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/.freeze
  RUN_ID_PATTERN = /\A[A-Za-z0-9_-]{1,200}\z/.freeze
  FINGERPRINT_PATTERN = /\A[a-f0-9]{16}\z/.freeze
  EVIDENCE_REF_PATTERN = /\A[a-z][a-z0-9:_-]{1,127}\z/.freeze
  CATEGORIES = %w[
    agent_behavior delivery observability policy qa_control_plane workflow_contract
  ].freeze

  Invalid = Class.new(StandardError)

  attr_reader :source_run_id, :repository, :base_branch, :fingerprint, :category,
              :evidence_refs, :title, :rationale, :proposed_change

  def initialize(source_run_id:, repository:, base_branch:, fingerprint:, category:, evidence_refs:, title:, rationale:, proposed_change:)
    @source_run_id = source_run_id
    @repository = repository
    @base_branch = base_branch
    @fingerprint = fingerprint
    @category = category
    @evidence_refs = evidence_refs
    @title = title
    @rationale = rationale
    @proposed_change = proposed_change
  end

  def self.for_run(run)
    Parser.new(run).findings
  rescue Invalid
    []
  end

  def self.find_for_approval(run:, repository:, finding_key:)
    finding = Parser.new(run).findings.find do |candidate|
      candidate.repository == repository && candidate.fingerprint == finding_key
    end
    raise Invalid, "the selected improvement proposal is no longer available" unless finding

    finding
  end

  def key = fingerprint

  def source_label
    category.tr("_", " ")
  end

  def action_label
    "Draft a verified improvement PR"
  end

  def action_explanation
    "The action agent must verify this observed pattern against the current code and open at most one Draft PR in the reviewed repository. It cannot merge, deploy, alter credentials, or change policy scope."
  end

  def approval_confirmation
    "Approve a verification-led Draft PR for #{repository}? The suggestion is supporting data only; the action can modify only this repository and cannot merge or deploy."
  end

  def queued_notice
    "It will verify the proposed improvement and may open one Draft PR only; it cannot merge or deploy."
  end

  def source_url
    "https://github.com/#{repository}"
  end

  def action_input(approved_by:)
    {
      "source_run_id" => source_run_id,
      "repository" => repository,
      "base_branch" => base_branch,
      "finding" => {
        "fingerprint" => fingerprint,
        "category" => category,
        "evidence_refs" => evidence_refs,
        "title" => title,
        "rationale" => rationale,
        "proposed_change" => proposed_change
      },
      "approved_by" => approved_by
    }
  end

  def idempotency_key
    "automation-interaction-review-action:#{source_run_id}:#{fingerprint}"
  end

  class Parser
    def initialize(run)
      @run = run
    end

    def findings
      ensure_workflow!
      result = workflow_result(@run["result"])
      return [] unless result["status"] == "completed"
      raise Invalid, "workflow result schema is invalid" unless result["schema_version"] == SCHEMA_VERSION

      source_run_id = required_string(@run["run_id"], "workflow run id")
      raise Invalid, "workflow run id is invalid" unless RUN_ID_PATTERN.match?(source_run_id)
      raw_findings = result["findings"]
      unless raw_findings.is_a?(Array) && raw_findings.length <= MAX_FINDINGS
        raise Invalid, "workflow findings must be an array"
      end

      findings = raw_findings.map { |value| parse_finding(value, source_run_id:) }
      fingerprints = findings.map(&:fingerprint)
      raise Invalid, "workflow findings must not repeat a fingerprint" unless fingerprints.uniq.length == fingerprints.length

      findings
    end

    private

    def ensure_workflow!
      unless @run.is_a?(Hash) && @run["workflow_name"] == WORKFLOW_NAME
        raise Invalid, "workflow is not an interaction review"
      end
    end

    # Python-hosted workflows return their own payload under result.output;
    # accept only that known wrapper so malformed run metadata remains no-action.
    def workflow_result(value)
      result = hash(value, "workflow result")
      return result if result.key?("status")
      return result unless result["output"].is_a?(Hash)

      hash(result["output"], "workflow result output")
    end

    def parse_finding(value, source_run_id:)
      source = hash(value, "workflow finding")
      allowed = %w[base_branch category evidence_refs fingerprint proposed_change rationale repository title]
      unknown = source.keys - allowed
      raise Invalid, "workflow finding has unsupported fields" if unknown.any?

      repository = required_string(source["repository"], "finding repository")
      raise Invalid, "finding repository is invalid" unless REPOSITORY_PATTERN.match?(repository)
      base_branch = required_string(source["base_branch"], "finding base branch")
      unless BRANCH_PATTERN.match?(base_branch) && !base_branch.start_with?("/")
        raise Invalid, "finding base branch is invalid"
      end
      fingerprint = required_string(source["fingerprint"], "finding fingerprint")
      raise Invalid, "finding fingerprint is invalid" unless FINGERPRINT_PATTERN.match?(fingerprint)
      category = required_string(source["category"], "finding category")
      raise Invalid, "finding category is invalid" unless CATEGORIES.include?(category)

      evidence_refs = source["evidence_refs"]
      unless evidence_refs.is_a?(Array) && evidence_refs.length.between?(1, 5) && evidence_refs.all? { |ref| ref.is_a?(String) && EVIDENCE_REF_PATTERN.match?(ref) }
        raise Invalid, "finding evidence references are invalid"
      end
      raise Invalid, "finding evidence references must not repeat" unless evidence_refs.uniq.length == evidence_refs.length

      AutomationInteractionReviewFinding.new(
        source_run_id:,
        repository:,
        base_branch:,
        fingerprint:,
        category:,
        evidence_refs: evidence_refs,
        title: bounded_text(source["title"], "finding title", 160),
        rationale: bounded_text(source["rationale"], "finding rationale", 700),
        proposed_change: bounded_text(source["proposed_change"], "finding proposed change", 1_000)
      )
    end

    def hash(value, field)
      raise Invalid, "#{field} must be an object" unless value.is_a?(Hash)

      value.deep_stringify_keys
    end

    def required_string(value, field)
      raise Invalid, "#{field} is required" unless value.is_a?(String) && value.strip.present?

      value.strip
    end

    def bounded_text(value, field, maximum)
      text = required_string(value, field).gsub(/\r\n?/, "\n")
      unless text.valid_encoding? && text.bytesize <= maximum && !text.include?("\u0000")
        raise Invalid, "#{field} is invalid"
      end

      text
    end
  end
end
