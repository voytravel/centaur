class CreateAutomationPolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :automation_policies do |t|
      t.string :name, null: false
      t.string :provider, null: false
      t.string :repository
      t.string :linear_team_id
      t.string :linear_project_id
      t.boolean :enabled, null: false, default: true
      t.string :mode, null: false, default: "observe"
      t.jsonb :settings, null: false, default: {}
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :automation_policies, [ :provider, :repository ],
              unique: true,
              where: "repository IS NOT NULL",
              name: "index_automation_policies_on_provider_and_repository"
    add_index :automation_policies, [ :provider, :linear_team_id, :linear_project_id ],
              name: "index_automation_policies_on_linear_scope"
    # PostgreSQL normally treats NULL values as distinct in a unique index.
    # Normalize the optional project portion in the index itself so a team-wide
    # policy can never be duplicated by a concurrent UI/API request using blank
    # versus NULL project IDs.
    add_index :automation_policies,
              "provider, linear_team_id, COALESCE(linear_project_id, '')",
              unique: true,
              where: "provider = 'linear'",
              name: "index_automation_policies_unique_linear_scope"

    create_table :automation_workstreams do |t|
      t.references :automation_policy, foreign_key: true
      t.string :provider, null: false
      t.string :subject_key, null: false
      t.string :session_key, null: false
      t.string :state, null: false, default: "idle"
      t.string :repository
      t.datetime :last_event_at
      t.string :last_execution_id
      t.integer :event_count, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :automation_workstreams, [ :provider, :subject_key ],
              unique: true,
              name: "index_automation_workstreams_on_provider_and_subject"
    add_index :automation_workstreams, :last_event_at

    create_table :automation_events do |t|
      t.references :automation_workstream, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :deduplication_key, null: false
      t.string :event_type, null: false
      t.string :event_action
      t.string :decision, null: false, default: "ignored"
      t.string :action_kind
      t.jsonb :metadata, null: false, default: {}
      t.datetime :received_at, null: false
      t.timestamps
    end

    add_index :automation_events, [ :provider, :deduplication_key ],
              unique: true,
              name: "index_automation_events_on_provider_and_deduplication_key"
    add_index :automation_events, :received_at
  end
end
