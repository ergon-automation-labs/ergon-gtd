defmodule BotArmyGtd.LogEntryStoreBehaviour do
  @moduledoc """
  Behaviour for log entry store implementations.
  """

  @callback mark_enriched(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback create(map()) :: {:ok, map()} | {:error, term()}
  @callback list(map()) :: {:ok, [map()]} | {:error, term()}
  @callback mark_file_written(String.t()) :: {:ok, map()} | {:error, term()}
end
