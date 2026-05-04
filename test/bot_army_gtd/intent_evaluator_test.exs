defmodule BotArmyGtd.IntentEvaluatorTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.IntentEvaluator
  alias BotArmyRuntime.Intent.Schema

  describe "extract_observations/1" do
    test "extracts stale task count from pulse data" do
      pulse = %{
        "observations" => %{
          "total_active_tasks" => 5,
          "goals" => %{
            "proj-1" => %{
              "active_tasks" => 3,
              "tasks_older_than_7d" => 2
            }
          }
        }
      }

      observations = IntentEvaluator.extract_observations(pulse)

      stale_entries = Enum.filter(observations, &(&1.type == :stale_task_count))
      assert stale_entries != []

      total_value =
        Enum.filter(stale_entries, &(Map.get(&1.metadata, :source) == "pulse"))
        |> Enum.map(& &1.value)
        |> Enum.at(0)

      assert total_value == 5
    end

    test "extracts per-project stale counts" do
      pulse = %{
        "observations" => %{
          "total_active_tasks" => 10,
          "goals" => %{
            "proj-1" => %{"tasks_older_than_7d" => 3},
            "proj-2" => %{"tasks_older_than_7d" => 0},
            "proj-3" => %{"tasks_older_than_7d" => 1}
          }
        }
      }

      observations = IntentEvaluator.extract_observations(pulse)

      project_entries =
        Enum.filter(observations, fn o ->
          o.type == :stale_task_count && Map.has_key?(o.metadata, :project_id)
        end)

      project_ids = Enum.map(project_entries, &Map.get(&1.metadata, :project_id))
      assert "proj-1" in project_ids
      assert "proj-3" in project_ids
      refute "proj-2" in project_ids
    end

    test "handles empty pulse data" do
      pulse = %{"observations" => %{"total_active_tasks" => 0, "goals" => %{}}}

      observations = IntentEvaluator.extract_observations(pulse)

      assert observations == []
    end

    test "handles missing observations" do
      pulse = %{}

      observations = IntentEvaluator.extract_observations(pulse)

      assert observations == []
    end
  end

  describe "schema integration" do
    test "gtd intent subjects match schema convention" do
      assert Schema.intent_subject("gtd", "nudge") == "bot_army.gtd.intent.nudge"
      assert Schema.intent_subject("gtd", "remind") == "bot_army.gtd.intent.remind"
      assert Schema.intent?("bot_army.gtd.intent.nudge") == true
    end
  end
end
