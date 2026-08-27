# Parses the bounded, validated output of the reviewed GitHub dependency
# maintenance workflow into a safe Console approval target. The model's result
# is treated as data: this class derives every action input from a small allow
# list and never forwards free-form text to the action workflow.
class GithubDependencyMaintenanceFinding
  WORKFLOW_NAME = "github_dependency_maintenance"
  ACTION_WORKFLOW_NAME = "github_dependency_maintenance_action"
  SCHEMA_VERSION = "2"

  REPOSITORY_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze
  BRANCH_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._\/-]{0,199}\z/.freeze
  RUN_ID_PATTERN = /\A[A-Za-z0-9_-]{1,200}\z/.freeze
  FINDING_KINDS = %w[security_advisory dependabot_pull_request dependabot_consolidation].freeze
  ACTIONS = %w[draft_pr repair consolidate].freeze

  Invalid = Class.new(StandardError)

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
    when "repair" then "Repair through a scoped Draft PR"
    when "consolidate" then "Create a scoped consolidation Draft PR"
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
      result = hash(@run["result"], "workflow result")
      return [] unless result["status"] == "completed"

      source_run_id = required_string(@run["run_id"], "workflow run id")
      raise Invalid, "workflow run id is invalid" unless RUN_ID_PATTERN.match?(source_run_id)
      routes = result["routes"]
      unless routes.is_a?(Array) && routes.length <= 100
        raise Invalid, "workflow result routes must be an array"
      end

      routes.flat_map { |route| parse_route(route, source_run_id) }
    end

    private

    def ensure_workflow!
      unless @run.is_a?(Hash) && @run["workflow_name"] == WORKFLOW_NAME
        raise Invalid, "workflow is not dependency maintenance"
      end
    end

    def parse_route(value, source_run_id)
      route = hash(value, "workflow route")
      return [] unless route["schema_version"] == SCHEMA_VERSION

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
        validate_dependabot_repair_proposal!(dependabot, action, numbers)
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

    def validate_dependabot_repair_proposal!(dependabot, action, numbers)
      unless action == "repair" && numbers.one?
        raise Invalid, "Dependabot repair proposal is invalid"
      end
      unless dependabot["mode"] == "approval_required"
        raise Invalid, "Dependabot repair needs approval-required mode"
      end
      unless dependabot["outcome"] == "repair_needed"
        raise Invalid, "Dependabot repair does not match the observed outcome"
      end
      source_numbers = positive_numbers(dependabot["source_pr_numbers"])
      unless source_numbers.include?(numbers.first)
        raise Invalid, "Dependabot repair does not match an observed pull request"
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
