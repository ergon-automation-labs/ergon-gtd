defmodule BotArmyGtd.InboxItemStoreBehaviour do
  @moduledoc """
  Behaviour definition for inbox item storage.

  Allows different implementations (real database, mock) to be swapped via configuration.
  """

  @callback create(payload :: map()) :: {:ok, map()} | {:error, atom()}
  @callback mark_processed(item_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback mark_discarded(item_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback get(item_id :: String.t()) :: {:ok, map()} | {:error, atom()}
  @callback list_pending() :: {:ok, list(map())}
  @callback list_all() :: {:ok, list(map())}
  @callback clear() :: :ok
end
