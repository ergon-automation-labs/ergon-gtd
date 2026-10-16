defmodule BotArmyGtd.Handlers.GraphHandler do
  @moduledoc """
  The graphs the task log can draw: `gtd.graph.series`.

  One read for the whole menu rather than one subject per chart. A card that offers a list
  of graphs needs to know what the list *is* before anybody picks one, and four subjects
  would be four ways to ask one question ("what could you draw?") — so the bot answers with
  every series it knows, each carrying its own points, and the page chooses which one to
  show. `Graphs` owns what a series means and `GraphSource` owns the reading; this module
  owns only the composition, and it never touches the database itself.

  ## A read that fails says so

  Four reads go into this answer and any one of them failing is a refusal rather than a
  shorter menu. A graph drawn from a read that did not answer would be a *wrong* graph — an
  empty week that had work in it — and nothing about a wrong chart looks broken. So the
  page says the log could not be read instead.

  ## Two windows, because two units

  The three weekly series read from the Monday twelve weeks back; the monthly project series
  reads from the first of the month twelve months back. Both windows are the bot's own, and
  both are asked of the source explicitly rather than by a row count, so the numbers cannot
  grow with the log.
  """

  require Logger

  alias BotArmyGtd.GraphSource
  alias BotArmyGtd.Graphs
  alias BotArmyGtd.HouseholdDay
  alias BotArmyLibraryCore.Tenant
  alias BotArmyLibraryRuntime.NATS.Reply

  @doc """
  Answer a `gtd.graph.series` request. Always answers, never raises.

  Returns the already-encoded `Reply` binary the consumer publishes, so its clause is one
  line: the same shape `gtd.whats_next` answers with.
  """
  def handle_graphs(message) do
    %{tenant_id: tenant_id} = Tenant.extract_context(message)
    today = HouseholdDay.today()

    with {:ok, opened} <- call(:tasks_opened, [tenant_id, Graphs.window_start(today)]),
         {:ok, closed} <- call(:tasks_closed, [tenant_id, Graphs.window_start(today)]),
         {:ok, worked} <- call(:task_checkouts, [tenant_id, Graphs.window_start(today)]),
         {:ok, projects} <- call(:projects_started, [tenant_id, Graphs.month_window_start(today)]) do
      graphs =
        Graphs.build(
          %{opened: opened, closed: closed, worked: worked, projects: projects},
          today
        )

      Reply.ok(%{
        "graphs" => graphs,
        "count" => length(graphs),
        "window_days" => Graphs.window_days()
      })
    else
      {:error, reason} ->
        Logger.warning("Could not read the task log to draw the graphs: #{inspect(reason)}")

        Reply.error(
          "The task log could not be read just now, so nothing can be drawn from it.",
          :read_failed
        )
    end
  end

  defp call(function, args) do
    case apply(source(), function, args) do
      {:ok, days} when is_list(days) -> {:ok, days}
      other -> {:error, {:unexpected_source_reply, other}}
    end
  rescue
    error -> {:error, error}
  end

  defp source do
    Application.get_env(:bot_army_gtd, :graph_source, GraphSource)
  end
end
