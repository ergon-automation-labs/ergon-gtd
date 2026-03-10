defmodule BotArmyGtdTest do
  use ExUnit.Case
  doctest BotArmyGtd

  test "version" do
    assert BotArmyGtd.version() == "0.1.1"
  end
end
