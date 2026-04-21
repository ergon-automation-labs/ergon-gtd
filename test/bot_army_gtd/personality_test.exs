defmodule BotArmyGtd.PersonalityTest do
  use ExUnit.Case
  @moduletag :core
  doctest BotArmyGtd.Personality

  alias BotArmyGtd.Personality

  describe "system_prompt/0" do
    test "returns a non-empty system prompt" do
      prompt = Personality.system_prompt()
      assert is_binary(prompt)
      assert String.length(prompt) > 100
    end

    test "includes bot symbol in prompt" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "◉")
    end

    test "includes role description" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "chief of staff")
    end

    test "includes voice principles" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "Warm")
      assert String.contains?(prompt, "Sarcastic")
      assert String.contains?(prompt, "Honest")
    end

    test "includes example messages" do
      prompt = Personality.system_prompt()
      assert String.contains?(prompt, "uncaptured tasks")
    end
  end

  describe "symbol/0" do
    test "returns GTD bot symbol" do
      assert Personality.symbol() == "◉"
    end
  end
end
