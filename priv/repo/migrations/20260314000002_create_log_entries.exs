defmodule BotArmyGtd.Repo.Migrations.CreateLogEntries do
  use Ecto.Migration

  def change do
    create table(:log_entries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:body, :text, null: false, comment: "Log entry body text")
      add(:occurred_at, :naive_datetime, null: false, comment: "When the event occurred")

      add(:category, :string,
        null: false,
        default: "personal",
        comment: "work|personal|health|learning|care|admin|social"
      )

      add(:tags, {:array, :string}, default: [], comment: "Tags for categorization")
      add(:task_id, :string, comment: "Optional link to a GTD task")
      add(:project, :string, comment: "Project name or ID")

      add(:source, :string,
        null: false,
        default: "user",
        comment: "user|task_completed|inbox_processed|tui|liveview"
      )

      add(:file_written, :boolean,
        default: false,
        comment: "Whether written to daily markdown file"
      )

      add(:enriched, :boolean, default: false, comment: "Whether LLM enrichment has been applied")
      add(:enriched_at, :naive_datetime, comment: "When enrichment occurred")
      add(:structured_data, :map, comment: "JSONB for additional structured data")

      # Multitenancy
      add(:tenant_id, :uuid, null: false)
      add(:user_id, :uuid, null: false)

      timestamps()
    end

    create(index(:log_entries, [:occurred_at]))
    create(index(:log_entries, [:category]))
    create(index(:log_entries, [:source]))
    create(index(:log_entries, [:tenant_id]))
    create(index(:log_entries, [:user_id]))
  end
end
