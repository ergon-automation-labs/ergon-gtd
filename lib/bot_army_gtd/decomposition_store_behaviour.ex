defmodule BotArmyGtd.DecompositionStoreBehaviour do
  @moduledoc """
  Behaviour definition for decomposition storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback get(decomposition_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback get_by_parent_task(parent_task_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback update(decomposition_id :: String.t(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback list() :: {:ok, list(map())}
  @callback archive(decomposition_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback clear() :: :ok
end
