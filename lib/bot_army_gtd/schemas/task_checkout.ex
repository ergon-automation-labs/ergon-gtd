defmodule BotArmyGtd.Schemas.TaskCheckout do
  @moduledoc """
  Ecto schema for task checkouts.

  Tracks which agent (coding agent, TUI, etc.) has checked out a task for active work.
  Allows multi-agent coordination — prevents conflicting edits on the same task.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "task_checkouts" do
    field(:task_id, Ecto.UUID)
    field(:agent_id, :string)
    field(:agent_type, :string, default: "unknown")
    field(:checked_out_at, :utc_datetime_usec)
    field(:checked_in_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  def changeset(checkout, attrs) do
    checkout
    |> cast(attrs, [
      :task_id,
      :agent_id,
      :agent_type,
      :checked_out_at,
      :checked_in_at,
      :metadata
    ])
    |> validate_required([:task_id, :agent_id, :checked_out_at])
  end
end
