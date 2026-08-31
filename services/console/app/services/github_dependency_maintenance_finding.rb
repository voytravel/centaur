# Parses the bounded, validated output of the reviewed GitHub dependency
# maintenance workflow into a safe Console approval target. The model's result
# is treated as data: this class derives every action input from a small allow
# list and never forwards free-form text to the action workflow.
class GithubDependencyMaintenanceFinding
  WORKFLOW_NAME = "github_dependency_maintenance"
  ACTION_WORKFLOW_NAME = "github_dependency_maintenance_action"
  SCHEMA_VERSIONS = %w[2 3].freeze

  REPOSITORY_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze
  BRANCH_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/.freeze
  RUN_ID_PATTERN = /\A[A-Za-z0-9_-]{1,200}\z/.freeze
  FINDING_KINDS = %w[security_advisory dependabot_pull_request dependabot_consolidation].freeze
  ACTIONS = %w[draft_pr repair consolidate merge].freeze
  DIAGNOSTICS = {
    "obsolete_proposal_shape" => {
      title: "Observer result rejected",
      detail: "The observer used an obsolete proposal shape. No repository action was authorized."
    },
    "unsupported_result_schema" => {
      title: "Observer result rejected",
      detail: "The observer used an unsupported result schema. No repository action was authorized."
    },
    "selection_count_contract" => {
      title: "Observer result rejected",
      detail: "The observer mixed observed totals and selected candidates. No repository action was authorized."
    },
    "missing_structured_result" => {
      title: "Observer result rejected",
      detail: "The observer did not return the required structured result. No repository action was authorized."
    },
    "invalid_structured_result" => {
      title: "Observer result rejected",
      detail: "The observer result failed the reviewed contract. No repository action was authorized."
    },
    "agent_turn_unavailable" => {
      title: "Observer unavailable",
      detail: "The scheduled observer did not complete after its bounded retry. No repository action was authorized."
    },
    "legacy_contract_rejection" => {
      title: "Observer result rejected",
      detail: "The observer result was rejected by the workflow contract. No repository action was authorized."
    }
  }.freeze
  DIAGNOSTIC_KINDS = {
    "agent_turn_unavailable" => "observer_unavailable"
  }.freeze

  Invalid = Class.new(StandardError)
  Diagnostic = Struct.new(:repository, :code, :title, :detail, keyword_init: true)

  attr_reader :source_run_id, :repository, :base_branch, :kind, :action, :source_numbers

  def initialize(source_run_id:, repository:, base_branch:, kind:, action:, source_numbers:)
    @source_run_id = source_run_id
    @repository = repository
    @base_branch = base_branch
    @kind = kind
    @action = action
    @source_numbers = source_numbers
  end

  def self.for_run(run)
    Parser.new(run).findings
  rescue Invalid
    []
  end

  def self.diagnostics_for_run(run)
    Parser.new(run).diagnostics
  rescue Invalid
    []
  end

  def self.find_for_approval(run:, repository:, finding_key:)
    finding = Parser.new(run).findings.find do |candidate|
      candidate.repository == repository && candidate.key == finding_key
    end
    raise Invalid, "the selected proposal is no longer available" unless finding

    finding
  end

  def key
    case kind
    when "security_advisory"
      "security:#{source_numbers.first}"
    when "dependabot_pull_request"
      "dependabot:#{source_numbers.first}"
    when "dependabot_consolidation"
      "dependabot:consolidation:#{source_numbers.join('-')}"
    else
      raise Invalid, "unsupported proposal kind"
    end
  end

  def source_label
    case kind
    when "security_advisory"
      "security alert ##{source_numbers.first}"
    when "dependabot_pull_request"
      "Dependabot PR ##{source_numbers.first}"
    when "dependabot_consolidation"
      "Dependabot PRs #{source_numbers.map { |number| "##{number}" }.join(", ")}"
    end
  end

  def action_label
    case action
    when "draft_pr" then "Create a scoped Draft PR"
    when "repair" then "Repair the existing Dependabot PR"
    when "consolidate" then "Create a scoped consolidation Draft PR"
    when "merge" then "Merge the ready Dependabot PR"
    end
  end

  def action_explanation
    case action
    when "repair"
      "The action agent re-checks the exact Dependabot PR, then may make one ordinary non-force update to its existing branch. It cannot merge or deploy."
    when "merge"
      "The action agent re-checks that exact PR is still green and clean, then may squash-merge it through GitHub's normal protections. It cannot deploy."
    else
      "The action agent must re-check this target, stay within the reviewed route, and open a Draft PR only if it remains valid."
    end
  end

  def approval_confirmation
    case action
    when "repair"
      "Approve repair of the existing Dependabot PR for #{repository} (#{source_label})? This can update only that branch; it cannot merge or deploy."
    when "merge"
      "Approve a revalidated squash merge for #{repository} (#{source_label})? This can merge only if GitHub still accepts the exact ready PR; it cannot deploy."
    else
      "Approve #{action_label.downcase} for #{repository} (#{source_label})? This can create a Draft PR, but cannot merge or deploy."
    end
  end

  def queued_notice
    case action
    when "repair"
      "It may update only the existing Dependabot PR after revalidation; it cannot merge or deploy."
    when "merge"
      "It may squash-merge only the revalidated ready Dependabot PR through GitHub's normal protections; it cannot deploy."
    else
      "It may create only a Draft PR; it cannot merge or deploy."
    end
  end

  def source_url
    case kind
    when "security_advisory"
      "https://github.com/#{repository}/security/dependabot/#{source_numbers.first}"
    when "dependabot_pull_request"
      "https://github.com/#{repository}/pull/#{source_numbers.first}"
    end
  end

  def action_input(approved_by:)
    {
      "source_run_id" => source_run_id,
      "repository" => repository,
      "base_branch" => base_branch,
      "finding" => {
        "key" => key,
        "kind" => kind,
        "action" => action,
        "source_numbers" => source_numbers
      },
      "approved_by" => approved_by
    }
  end

  def idempotency_key
    "github-dependency-maintenance-action:#{source_run_id}:#{key}"
  end

  class Parser
    def initialize(run)
      @run = run
    end

    def findings
      ensure_workflow!
      result = workflow_result(@run["result"])
      return [] unless result["status"] == "completed"

      source_run_id = required_string(@run["run_id"], "workflow run id")
      raise Invalid, "workflow run id is invalid" unless RUN_ID_PATTERN.match?(source_run_id)
      routes = result["routes"]
      unless routes.is_a?(Array) && routes.length <= 100
        raise Invalid, "workflow result routes must be an array"
      end

      routes.flat_map { |route| parse_route(route, source_run_id) }
    end

    def diagnostics
      ensure_workflow!
      result = workflow_result(@run["result"])
      return [] unless result["status"] == "completed"

      routes = result["routes"]
      unless routes.is_a?(Array) && routes.length <= 100
        raise Invalid, "workflow result routes must be an array"
      end

      routes.filter_map { |route| parse_diagnostic(route) }
    end

    private

    # Python-hosted workflows return their own payload under `result.output`,
    # alongside run/task metadata. Native workflows return the payload directly
    # as `result`. Normalize only the known wrapper shape so both paths use the
    # same strict finding parser below; a malformed wrapper remains no-action.
    def workflow_result(value)
      result = hash(value, "workflow result")
      return result if result.key?("status")
      return result unless result["output"].is_a?(Hash)

      hash(result["output"], "workflow result output")
    end

    def ensure_workflow!
      unless @run.is_a?(Hash) && @run["workflow_name"] == WORKFLOW_NAME
        raise Invalid, "workflow is not dependency maintenance"
      end
    end

    def parse_route(value, source_run_id)
      route = hash(value, "workflow route")
      return [] unless SCHEMA_VERSIONS.include?(route["schema_version"])

      repository = required_string(route["repository"], "repository")
      raise Invalid, "workflow route repository is invalid" unless REPOSITORY_PATTERN.match?(repository)

      base_branch = required_string(route["base_branch"], "base branch")
      unless BRANCH_PATTERN.match?(base_branch) && !base_branch.start_with?("/")
        raise Invalid, "workflow route base branch is invalid"
      end

      security = hash(route["security_advisories"], "security advisories")
      dependabot = hash(route["dependabot"], "dependabot")
      proposals = route["proposals"]
      unless proposals.is_a?(Array) && proposals.length <= 10
        raise Invalid, "workflow proposals must be an array"
      end

      findings = proposals.map do |proposal|
        parse_proposal(
          proposal,
          source_run_id:,
          repository:,
          base_branch:,
          security:,
          dependabot:
        )
      end
      validate_proposal_limits!(findings)
      findings
    end

    def parse_diagnostic(value)
      route = hash(value, "workflow route")
      return unless SCHEMA_VERSIONS.include?(route["schema_version"])

      repository = required_string(route["repository"], "repository")
      raise Invalid, "workflow route repository is invalid" unless REPOSITORY_PATTERN.match?(repository)

      code = diagnostic_code(route)
      return unless code

      presentation = DIAGNOSTICS.fetch(code)
      Diagnostic.new(
        repository: repository,
        code: code,
        title: presentation.fetch(:title),
        detail: presentation.fetch(:detail)
      )
    end

    def diagnostic_code(route)
      diagnostic = route["diagnostic"]
      if diagnostic.is_a?(Hash)
        source = diagnostic.deep_stringify_keys
        return unless source.keys.sort == %w[code kind summary]
        code = source["code"]
        return unless DIAGNOSTICS.key?(code)

        expected_kind = DIAGNOSTIC_KINDS.fetch(code, "observer_result_rejected")
        return code if source["kind"] == expected_kind
      end

      return "legacy_contract_rejection" if legacy_contract_rejection?(route)

      nil
    end

    def legacy_contract_rejection?(route)
      security = route["security_advisories"]
      dependabot = route["dependabot"]
      return false unless security.is_a?(Hash) && dependabot.is_a?(Hash)
      return false unless security["outcome"] == "blocked" && dependabot["outcome"] == "blocked"
      return false unless route["proposals"] == []

      Array(route["validation"]).any? do |entry|
        entry.is_a?(Hash) && entry["command"] == "structured workflow result" && entry["status"] == "failed"
      end
    end

    def parse_proposal(value, source_run_id:, repository:, base_branch:, security:, dependabot:)
      proposal = hash(value, "workflow proposal")
      unknown = proposal.keys - %w[kind action source_numbers]
      raise Invalid, "workflow proposal has unsupported fields" if unknown.any?

      kind = required_string(proposal["kind"], "proposal kind")
      action = required_string(proposal["action"], "proposal action")
      numbers = positive_numbers(proposal["source_numbers"])
      raise Invalid, "workflow proposal kind is invalid" unless FINDING_KINDS.include?(kind)
      raise Invalid, "workflow proposal action is invalid" unless ACTIONS.include?(action)

      case kind
      when "security_advisory"
        validate_security_proposal!(security, action, numbers)
      when "dependabot_pull_request"
        validate_dependabot_pull_request_proposal!(dependabot, action, numbers)
      when "dependabot_consolidation"
        validate_dependabot_consolidation_proposal!(dependabot, action, numbers)
      end

      GithubDependencyMaintenanceFinding.new(
        source_run_id:,
        repository:,
        base_branch:,
        kind:,
        action:,
        source_numbers: numbers
      )
    end

    def validate_security_proposal!(security, action, numbers)
      unless action == "draft_pr" && numbers.one?
        raise Invalid, "security proposal must create a Draft PR"
      end
      unless security["mode"] == "approval_required"
        raise Invalid, "security proposal needs approval-required mode"
      end
      unless security["outcome"] == "observed"
        raise Invalid, "security proposal does not match the observed outcome"
      end
      alert_numbers = positive_numbers(security["alert_numbers"])
      unless alert_numbers.include?(numbers.first)
        raise Invalid, "security proposal does not match an observed alert"
      end
    end

    def validate_dependabot_pull_request_proposal!(dependabot, action, numbers)
      unless %w[repair merge].include?(action) && numbers.one?
        raise Invalid, "Dependabot pull-request proposal is invalid"
      end
      unless dependabot["mode"] == "approval_required"
        raise Invalid, "Dependabot pull-request proposal needs approval-required mode"
      end
      expected_outcome = action == "repair" ? "repair_needed" : "direct_ready"
      unless dependabot["outcome"] == expected_outcome
        raise Invalid, "Dependabot #{action} does not match the observed outcome"
      end
      source_numbers = positive_numbers(dependabot["source_pr_numbers"])
      unless source_numbers.include?(numbers.first)
        raise Invalid, "Dependabot #{action} does not match an observed pull request"
      end
    end

    def validate_dependabot_consolidation_proposal!(dependabot, action, numbers)
      unless action == "consolidate" && numbers.length >= 2
        raise Invalid, "Dependabot consolidation proposal is invalid"
      end
      unless dependabot["mode"] == "approval_required"
        raise Invalid, "Dependabot consolidation needs approval-required mode"
      end
      unless dependabot["outcome"] == "consolidation_candidate"
        raise Invalid, "Dependabot consolidation does not match the observed outcome"
      end
      source_numbers = positive_numbers(dependabot["source_pr_numbers"])
      unless numbers == source_numbers
        raise Invalid, "Dependabot consolidation does not match observed pull requests"
      end
    end

    def validate_proposal_limits!(findings)
      security_count = findings.count { |finding| finding.kind == "security_advisory" }
      dependabot_count = findings.length - security_count
      raise Invalid, "workflow has multiple security proposals" if security_count > 1
      raise Invalid, "workflow has multiple Dependabot proposals" if dependabot_count > 1
    end

    def hash(value, field)
      raise Invalid, "#{field} must be an object" unless value.is_a?(Hash)

      value.deep_stringify_keys
    end

    def required_string(value, field)
      raise Invalid, "#{field} is required" unless value.is_a?(String) && value.strip.present?

      value.strip
    end

    def positive_numbers(value)
      unless value.is_a?(Array) && value.any? && value.length <= 20
        raise Invalid, "proposal sources must be an array"
      end
      unless value.all? { |number| number.is_a?(Integer) && number.positive? } && value.uniq.length == value.length
        raise Invalid, "proposal sources must be unique positive integers"
      end

      value.sort
    end
  end
end
