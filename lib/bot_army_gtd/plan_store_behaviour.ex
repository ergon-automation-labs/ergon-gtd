defmodule BotArmyGtd.PlanStoreBehaviour do
  @moduledoc """
  Behaviour for plan storage operations.

  Defines the contract for storing and retrieving plans in the GTD system.
  Plans represent high-level goals that have been decomposed into subtasks.
  """

  @callback create(map()) :: {:ok, map()} | {:error, term()}
  @callback get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback update(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback list(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  @callback delete(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
end
