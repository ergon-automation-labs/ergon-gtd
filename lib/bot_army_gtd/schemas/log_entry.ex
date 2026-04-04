defmodule BotArmyGtd.Schemas.LogEntry do
  @moduledoc """
  Ecto schema for GTD daily log entries.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "log_entries" do
    field :body, :string
    field :occurred_at, :naive_datetime
    field :category, :string, default: "personal"
    field :tags, {:array, :string}, default: []
    field :task_id, :string
    field :project, :string
    field :source, :string, default: "user"
    field :file_written, :boolean, default: false
    field :enriched, :boolean, default: false
    field :enriched_at, :naive_datetime
    field :structured_data, :map
    field :tenant_id, Ecto.UUID
    field :user_id, Ecto.UUID

    timestamps()
  end

  @doc false
  def changeset(log_entry, attrs) do
    log_entry
    |> cast(attrs, [
      :body,
      :occurred_at,
      :category,
      :tags,
      :task_id,
      :project,
      :source,
      :file_written,
      :enriched,
      :enriched_at,
      :structured_data,
      :tenant_id,
      :user_id
    ])
    |> validate_required([:body, :occurred_at])
    |> validate_inclusion(:category, [
      "work",
      "personal",
      "health",
      "learning",
      "care",
      "admin",
      "social"
    ])
    |> validate_inclusion(:source, [
      "user",
      "task_completed",
      "inbox_processed",
      "tui",
      "liveview"
    ])
  end
end
