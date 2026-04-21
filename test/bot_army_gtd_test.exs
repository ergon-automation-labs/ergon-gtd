defmodule BotArmyGtdTest do
  use ExUnit.Case
  @moduletag :handlers
  doctest BotArmyGtd

  test "version" do
    assert BotArmyGtd.version() == "0.1.1"
  end
end
