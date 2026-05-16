defmodule BotArmyGtd.PlanStoreBehaviour do
  @moduledoc """
  Behaviour for plan storage operations.

  Allows mocking PlanStore in tests.
  """

  @callback create(map) :: {:ok, map} | {:error, term}
  @callback get(binary, binary) :: {:ok, map} | {:error, term}
  @callback update(binary, binary, map) :: {:ok, map} | {:error, term}
  @callback list(binary, map) :: {:ok, list} | {:error, term}
  @callback delete(binary, binary) :: {:ok, map} | {:error, term}
  @callback clear() :: :ok
end
