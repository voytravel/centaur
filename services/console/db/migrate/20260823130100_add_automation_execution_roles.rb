class AddAutomationExecutionRoles < ActiveRecord::Migration[8.1]
  def change
    # An explicit role is the policy's capability boundary. An operator picks
    # it before Act mode can create a sandbox; webhook text never selects or
    # mutates it.
    add_reference :automation_policies, :execution_role, foreign_key: { to_table: :roles }

    # The derived platform principal and the particular role this workstream
    # attached to it. Keeping both makes later policy disable/role changes
    # deterministic and auditable.
    add_reference :automation_workstreams, :principal, foreign_key: true
    add_reference :automation_workstreams, :authorization_role, foreign_key: { to_table: :roles }
  end
end
