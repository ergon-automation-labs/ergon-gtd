defmodule BotArmyGtd.PulsePublisherTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyGtd.PulsePublisher

  test "build_hydration_events returns synapse contract events" do
    pulse = %{
      "tenant_id" => "00000000-0000-0000-0000-000000000001",
      "projects" => [%{"id" => "p1"}],
      "tasks" => [%{"id" => "t1"}],
      "observations" => %{"total_active_tasks" => 12}
    }

    events = PulsePublisher.build_hydration_events(pulse, 7)

    assert length(events) == 4

    assert Enum.map(events, & &1["event"]) == [
             "system.health",
             "system.capability.snapshot",
             "system.risk.signal",
             "task.signal.verification"
           ]

    health = Enum.at(events, 0)
    assert health["tenant_id"] == "00000000-0000-0000-0000-000000000001"
    assert get_in(health, ["payload", "status"]) == "healthy"
    assert get_in(health, ["payload", "sequence"]) == 7

    risk = Enum.at(events, 2)
    assert get_in(risk, ["payload", "risk_type"]) == "risk.backlog_pressure"
    assert get_in(risk, ["payload", "status"]) == "resolved"

    verification = Enum.at(events, 3)
    assert get_in(verification, ["payload", "status"]) == "pass"
    assert get_in(verification, ["payload", "sequence"]) == 10
  end
end
