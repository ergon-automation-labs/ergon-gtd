defmodule BotArmyGtd.TaskStoreBehaviour do
  @moduledoc """
  Behaviour definition for task storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback update(task_id :: String.t(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback complete(task_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback get(task_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback list() :: {:ok, list(map())}
  @callback clear() :: :ok
end
