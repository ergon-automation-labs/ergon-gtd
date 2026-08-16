defmodule BotArmyGtd.CircuitBreakerHelper do
  @moduledoc """
  Utility to unwrap CircuitBreakerRepo tuple responses.

  When Repo operations fail or return via CircuitBreakerRepo, they may return
  {:ok, result} or {:error, reason} tuples. This module provides helpers to
  unwrap those tuples consistently across all stores and schedulers.
  """

  @doc """
  Unwrap a CircuitBreakerRepo response tuple.

  Returns the value if it was {:ok, value}, empty list on error, or passes
  through non-tuple values unchanged (for direct Repo responses).
  """
  def unwrap_list(result) do
    case result do
      {:ok, list} when is_list(list) -> list
      {:error, _reason} -> []
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc """
  Unwrap a CircuitBreakerRepo single-result response.

  Returns the value if it was {:ok, value}, nil on error, or passes
  through non-tuple values unchanged.
  """
  def unwrap_one(result) do
    case result do
      {:ok, value} -> value
      {:error, _reason} -> nil
      value -> value
    end
  end
end
