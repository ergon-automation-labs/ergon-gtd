defmodule BotArmyGtd.TaskStoreBehaviour do
  @moduledoc """
  Behaviour definition for task storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback update(task_id :: String.t(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback complete(task_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback get(tenant_id :: String.t(), task_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback list(tenant_id :: String.t()) :: {:ok, list(map())}
  @callback list(tenant_id :: String.t(), filters :: map()) :: {:ok, list(map())}
  @callback list_prioritized(tenant_id :: String.t()) :: {:ok, list(map())}
  @callback list_prioritized(tenant_id :: String.t(), filters :: map()) :: {:ok, list(map())}
  @callback search(
              tenant_id :: String.t(),
              query :: String.t(),
              filters :: map(),
              pagination :: map()
            ) :: {:ok, {list(map()), integer()}} | {:error, atom()}
  @callback clear() :: :ok
end
