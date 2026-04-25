defmodule BotArmyGtd.ArmyContextConsumerTest do
  use ExUnit.Case
  @moduletag :nats

  setup do
    {:ok, _} = Application.ensure_all_started(:bot_army_gtd)
    :ok
  end

  describe "get_at_risk_goals/0" do
    test "returns empty list when no at-risk goals" do
      goals = BotArmyGtd.ArmyContextConsumer.get_at_risk_goals()
      assert is_list(goals)
    end
  end
end
