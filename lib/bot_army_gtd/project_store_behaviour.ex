defmodule BotArmyGtd.ProjectStoreBehaviour do
  @moduledoc """
  Behaviour definition for project storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback update(project_id :: String.t(), payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback get(tenant_id :: String.t(), project_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback list(tenant_id :: String.t()) :: {:ok, list(map())}
end
