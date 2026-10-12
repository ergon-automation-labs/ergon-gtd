defmodule BotArmyGtd.EventBuilderTest do
  use ExUnit.Case

  @moduletag :core

  alias BotArmyGtd.EventBuilder

  # These two events cross the bot boundary: `BotArmyRpg.ProgressionSubscriber`
  # reads the task's identity off the envelope ROOT. Anything nested only under
  # `payload["task"]` is invisible to it.
  @task_lifecycle_events ~w(gtd.task.created gtd.task.completed)

  @task %{
    "id" => "11111111-1111-1111-1111-111111111111",
    "title" => "buy milk",
    "priority" => "high"
  }

  describe "build_task_event/4" do
    for event <- @task_lifecycle_events do
      test "#{event} flattens the task identity onto the envelope root" do
        event_data = EventBuilder.build_task_event(unquote(event), @task)

        assert event_data["event"] == unquote(event)
        assert event_data["task_id"] == @task["id"]
        assert event_data["task_title"] == "buy milk"
        assert event_data["priority"] == "high"
        # the nested copy stays, so GTD-side readers keep working
        assert event_data["payload"]["task"] == @task
      end
    end

    test "carries the handler's own payload extras beside the task" do
      event_data =
        EventBuilder.build_task_event("gtd.task.completed", @task, %{
          "triggered_by_event_id" => "evt-1",
          "auto_completed" => true
        })

      assert event_data["payload"]["triggered_by_event_id"] == "evt-1"
      assert event_data["payload"]["auto_completed"] == true
      assert event_data["payload"]["task"] == @task
    end

    test "honours the envelope options" do
      event_data =
        EventBuilder.build_task_event("gtd.task.created", @task, %{},
          tenant_id: "tenant-1",
          user_id: "user-1",
          triggered_by: "claude"
        )

      assert event_data["tenant_id"] == "tenant-1"
      assert event_data["user_id"] == "user-1"
      assert event_data["triggered_by"] == "claude"
    end

    test "does not flatten the identity onto events nobody consumes that way" do
      event_data = EventBuilder.build_task_event("gtd.task.updated", @task)

      refute Map.has_key?(event_data, "task_id")
      refute Map.has_key?(event_data, "task_title")
      assert event_data["payload"]["task"] == @task
    end

    test "a task with no priority still carries the normal default the RPG reads" do
      event_data =
        EventBuilder.build_task_event("gtd.task.created", %{"id" => "t1", "title" => "x"})

      assert event_data["priority"] == "normal"
      assert event_data["task_title"] == "x"
    end
  end

  describe "the cross-bot contract is enforced at the source" do
    test "no module builds a task lifecycle envelope with build_event/3" do
      # A lint, not a parser: whitespace-collapsed source is searched for
      # `build_event( "<task lifecycle event>"` so a new hand-rolled publisher is
      # caught even when the call spans lines. `build_task_event(` does not match.
      offenders =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          flat = path |> File.read!() |> String.replace(~r/\s+/, " ")

          for event <- @task_lifecycle_events,
              Regex.match?(~r/build_event\(\s*"#{Regex.escape(event)}"/, flat),
              do: "#{path} builds #{event} with build_event/3"
        end)

      assert offenders == [],
             "Task lifecycle events must be built with EventBuilder.build_task_event/4, " <>
               "which flattens task_id/task_title/priority to the root for cross-bot " <>
               "consumers (RPG progression, quest auto-create):\n" <> Enum.join(offenders, "\n")
    end

    test "the lint can actually see the mistake it exists to catch" do
      # The guard above is only worth its runtime if it fires on the exact shape
      # that shipped the defect (a nested-only task_completed envelope).
      flat =
        String.replace(
          "EventBuilder.build_event(\n  \"gtd.task.completed\",\n  %{\"task\" => task},\n  opts\n)",
          ~r/\s+/,
          " "
        )

      assert Regex.match?(~r/build_event\(\s*"gtd\.task\.completed"/, flat)
    end
  end
end
