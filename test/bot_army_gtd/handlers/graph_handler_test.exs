defmodule BotArmyGtd.Handlers.GraphHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyGtd.Graphs
  alias BotArmyGtd.Handlers.GraphHandler
  alias BotArmyGtd.HouseholdDay

  @tenant "00000000-0000-0000-0000-000000000001"

  # The handler's only door to the database is the `:graph_source` key, and this stands in
  # for the reads behind it. Each answer is whatever the test put in the process dictionary
  # — days, a raise, or a reply of the wrong shape — so the failure paths can be walked
  # without a database and without a mock module per read.
  defmodule SourceStub do
    @moduledoc false

    def tasks_opened(tenant, since), do: answer(:opened, tenant, since)
    def tasks_closed(tenant, since), do: answer(:closed, tenant, since)
    def task_checkouts(tenant, since), do: answer(:worked, tenant, since)
    def projects_started(tenant, since), do: answer(:projects, tenant, since)

    defp answer(key, _tenant, since) do
      send(self(), {:asked, key, since})

      case Process.get({:stub_reply, key}) do
        nil -> {:ok, Process.get({:stub_days, key}) || []}
        :raise -> raise "could not lookup Ecto repo"
        other -> other
      end
    end
  end

  setup do
    previous = Application.get_env(:bot_army_gtd, :graph_source)
    Application.put_env(:bot_army_gtd, :graph_source, SourceStub)
    on_exit(fn -> Application.put_env(:bot_army_gtd, :graph_source, previous) end)
    :ok
  end

  describe "handle_graphs/1" do
    test "answers the whole menu, each series with its points" do
      reply = decode(GraphHandler.handle_graphs(request()))

      assert reply["ok"] == true
      assert reply["data"]["count"] == length(reply["data"]["graphs"])
      assert reply["data"]["window_days"] == Graphs.window_days()

      assert Enum.map(reply["data"]["graphs"], & &1["id"]) ==
               Enum.map(Graphs.build(%{}, HouseholdDay.today()), & &1["id"])

      for graph <- reply["data"]["graphs"] do
        assert is_binary(graph["title"])
        assert is_binary(graph["note"])
        assert graph["kind"] in ["bars", "line"]
        assert is_list(graph["points"])
      end
    end

    test "reads each window from the bot's own week and month, not from a row count" do
      today = HouseholdDay.today()

      _ = GraphHandler.handle_graphs(request())

      for key <- [:opened, :closed, :worked] do
        assert_received {:asked, ^key, since}
        assert since == Graphs.window_start(today)
      end

      assert_received {:asked, :projects, month_since}
      assert month_since == Graphs.month_window_start(today)
    end

    test "puts the days the source returned into the weeks and months they belong to" do
      today = HouseholdDay.today()
      Process.put({:stub_days, :opened}, [today, today])
      Process.put({:stub_days, :worked}, [today])
      Process.put({:stub_days, :projects}, [today])

      reply = decode(GraphHandler.handle_graphs(request()))

      today_label = label(Graphs.week_buckets(today, 1))

      assert List.last(series(reply, "gtd.tasks.opened.week")["points"]) ==
               %{"label" => today_label, "value" => 2}

      assert List.last(series(reply, "gtd.tasks.worked.week")["points"])["value"] == 1

      month_label = label(Graphs.month_buckets(today, 1))
      assert List.last(series(reply, "gtd.projects.started.month")["points"])["value"] == 1

      assert List.last(series(reply, "gtd.projects.started.month")["points"])["label"] ==
               month_label
    end

    test "a read that cannot answer is a refusal, not a shorter menu" do
      Process.put({:stub_reply, :closed}, :raise)

      reply = decode(GraphHandler.handle_graphs(request()))

      assert reply["ok"] == false
      assert reply["code"] == "read_failed"
      refute Map.has_key?(reply, "data")
      assert reply["error"] =~ "could not be read"
    end

    test "a read that answers with something unexpected is a refusal too" do
      Process.put({:stub_reply, :worked}, :no_reply)

      reply = decode(GraphHandler.handle_graphs(request()))

      assert reply["ok"] == false
      assert reply["code"] == "read_failed"
    end
  end

  describe "parity with the published schema" do
    test "the reply's only refusal is the one the handler utters" do
      path =
        Path.expand("../../../../../schemas/bot_army_schemas_gtd/schemas", __DIR__)
        |> Path.join("gtd.graph.series.reply.json")

      [_ok, refused] = path |> File.read!() |> Jason.decode!() |> Map.fetch!("oneOf")

      assert refused["properties"]["code"]["enum"] == ["read_failed"]
    end
  end

  defp request do
    %{
      "event" => "gtd.graph.series",
      "tenant_id" => @tenant,
      "user_id" => "00000000-0000-0000-0000-000000000002",
      "payload" => %{}
    }
  end

  defp decode(reply), do: Jason.decode!(reply)
  defp series(reply, id), do: Enum.find(reply["data"]["graphs"], &(&1["id"] == id))
  defp label([bucket]), do: bucket.label
end
