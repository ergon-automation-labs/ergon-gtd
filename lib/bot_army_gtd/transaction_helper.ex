defmodule BotArmyGtd.TransactionHelper do
  @moduledoc """
  Helper for transaction patterns in store modules.
  Reduces nesting depth by handling Repo.update pattern uniformly.
  """

  require Logger

  def update_changeset_in_transaction(repo, schema, uuid, changes_fn)
      when is_function(changes_fn) do
    repo.transaction(fn ->
      case repo.get(schema, uuid) do
        nil ->
          repo.rollback(:not_found)

        db_record ->
          changeset = schema.changeset(db_record, changes_fn.(db_record))
          handle_repo_update(repo, changeset)
      end
    end)
  end

  defp handle_repo_update(repo, changeset) do
    case repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, changeset} -> repo.rollback(changeset)
    end
  end
end
