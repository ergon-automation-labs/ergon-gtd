defmodule BotArmyGtd.PollRoundStoreBehaviour do
  @callback create(payload :: map()) :: {:ok, map()} | {:error, term()}
  @callback get(tenant_id :: String.t(), poll_id :: String.t()) ::
              {:ok, map()} | {:error, :not_found}
  @callback get_open(tenant_id :: String.t()) :: {:ok, map() | nil}
  @callback close(tenant_id :: String.t(), poll_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback list(tenant_id :: String.t(), filters :: map()) :: {:ok, [map()]}
  @callback clear() :: :ok
end
