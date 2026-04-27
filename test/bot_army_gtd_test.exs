defmodule BotArmyGtdTest do
  use ExUnit.Case
  @moduletag :handlers
  doctest BotArmyGtd

  test "version matches mix.exs" do
    expected = Mix.Project.config()[:version]
    assert BotArmyGtd.version() == expected
  end
end
