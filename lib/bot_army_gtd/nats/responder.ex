defmodule BotArmyGtd.NATS.Responder do
  @moduledoc """
  Standardized response builder for GTD NATS request/reply.
  Decouples the transport layer (Consumer) from the response shape.
  """

  alias BotArmyLibraryRuntime.NATS.Reply

  @doc """
  Build a paginated task list response.
  """
  def task_list(tasks, total_count, limit, offset) do
    Reply.ok(%{
      "tasks" => tasks,
      "total_count" => total_count,
      "limit" => limit,
      "offset" => offset
    })
  end

  @doc """
  Build a single task response.
  """
  def task_get(task) do
    Reply.ok(%{"task" => task})
  end

  @doc """
  Build a search results response.
  """
  def search_results(tasks, total_count, limit, offset, query) do
    Reply.ok(%{
      "tasks" => tasks,
      "total_count" => total_count,
      "limit" => limit,
      "offset" => offset,
      "query" => query
    })
  end

  @doc """
  Build a due decompositions response.
  """
  def due_decompositions(decompositions) do
    Reply.ok(%{"decompositions" => decompositions})
  end

  @doc """
  Generic error response.
  """
  def error(reason, code) do
    Reply.error(inspect(reason), code)
  end
end
