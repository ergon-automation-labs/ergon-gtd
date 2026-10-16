defmodule BotArmyGtd.GraphsTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyGtd.Graphs

  @today ~D[2026-10-16]

  describe "week_buckets/2" do
    test "ends on the Monday of the week today is in, and counts back in sevens" do
      buckets = Graphs.week_buckets(@today, 3)

      assert Enum.map(buckets, & &1.start) == [~D[2026-09-28], ~D[2026-10-05], ~D[2026-10-12]]
      assert Enum.map(buckets, & &1.label) == ["Sep 28", "Oct 5", "Oct 12"]
    end
  end

  describe "month_buckets/2" do
    test "ends on the first of the month today is in, and counts back by calendar month" do
      buckets = Graphs.month_buckets(@today, 3)

      assert Enum.map(buckets, & &1.start) == [~D[2026-08-01], ~D[2026-09-01], ~D[2026-10-01]]
      assert Enum.map(buckets, & &1.label) == ["Aug 2026", "Sep 2026", "Oct 2026"]
    end

    test "crosses a year boundary without arithmetic of its own" do
      assert Enum.map(Graphs.month_buckets(~D[2026-02-14], 3), & &1.start) == [
               ~D[2025-12-01],
               ~D[2026-01-01],
               ~D[2026-02-01]
             ]
    end
  end

  describe "build/2" do
    test "offers every series, including the ones an empty log cannot fill" do
      graphs = Graphs.build(%{}, @today)

      assert Enum.map(graphs, & &1["id"]) == [
               "gtd.tasks.opened.week",
               "gtd.tasks.closed.week",
               "gtd.tasks.worked.week",
               "gtd.projects.started.month"
             ]

      for graph <- graphs do
        assert graph["kind"] == "bars"
        assert is_binary(graph["title"])
        assert is_binary(graph["note"])
        assert is_binary(graph["unit"])
        refute graph["points"] == []
      end
    end

    test "an empty log draws twelve empty weeks and twelve empty months, not nothing" do
      graphs = series(Graphs.build(%{}, @today))

      assert length(graphs["gtd.tasks.opened.week"]["points"]) == 12
      assert length(graphs["gtd.projects.started.month"]["points"]) == 12

      for graph <- Map.values(graphs),
          do: assert(Enum.all?(graph["points"], &(&1["value"] == 0)))
    end

    test "counts each kind of day into the week it belongs to" do
      data = %{
        opened: [~D[2026-10-16], ~D[2026-10-15], ~D[2026-09-28]],
        closed: [~D[2026-10-16]],
        worked: [~D[2026-10-16], ~D[2026-10-14], ~D[2026-10-13]]
      }

      graphs = series(Graphs.build(data, @today))

      # Twelve buckets, oldest first: 09-28 is the tenth, 10-14 and 10-15 and 10-16 are in
      # the twelfth — today included, because the current week's bucket holds the days
      # later in the week than its Monday.
      assert values(graphs["gtd.tasks.opened.week"]) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2]
      assert values(graphs["gtd.tasks.closed.week"]) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
      assert values(graphs["gtd.tasks.worked.week"]) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3]
    end

    test "drops a day older than the window instead of folding it into the oldest bar" do
      graphs = series(Graphs.build(%{opened: [~D[2026-07-20]]}, @today))

      assert Enum.all?(values(graphs["gtd.tasks.opened.week"]), &(&1 == 0))
    end

    test "counts a project into its calendar month" do
      graphs = series(Graphs.build(%{projects: [~D[2026-10-02], ~D[2026-09-30]]}, @today))

      assert values(graphs["gtd.projects.started.month"]) |> Enum.take(-2) == [1, 1]
    end

    test "says what one bar counts, and does not pretend a chart is a scoreboard" do
      graphs = series(Graphs.build(%{}, @today))

      assert graphs["gtd.tasks.worked.week"]["unit"] == "times"
      assert graphs["gtd.projects.started.month"]["note"] =~ "calendar month"
      assert graphs["gtd.tasks.opened.week"]["note"] =~ "one week"
    end

    test "window_start/1 is the first bucket's Monday and month_window_start/1 the first month" do
      assert Graphs.window_start(@today) == ~D[2026-07-27]
      assert Graphs.month_window_start(@today) == ~D[2025-11-01]
    end
  end

  defp series(graphs), do: Map.new(graphs, &{&1["id"], &1})
  defp values(series), do: Enum.map(series["points"], & &1["value"])
end
