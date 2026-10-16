defmodule BotArmyGtd.CoachLookupTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.CoachLookup

  # Both look-ups go out over NATS; here every reply comes from a function the test installs, so
  # the whole round is exercised with no broker and nobody's notes.
  defmodule FakePublisher do
    def request(subject, payload, _opts) do
      fun = Agent.get(:coach_lookup_fake, & &1)
      fun.(subject, payload)
    end
  end

  setup do
    {:ok, pid} =
      Agent.start_link(fn -> fn _subject, _payload -> flunk("no fake installed") end end)

    Process.register(pid, :coach_lookup_fake)

    on_exit(fn ->
      if Process.alive?(pid), do: Agent.stop(pid)
    end)

    :ok
  end

  describe "run/3" do
    test "the docs look-up asks the docs bot's own hybrid search, not the job-shaped façade" do
      test_pid = self()

      set_fake(fn subject, payload ->
        send(test_pid, {:asked, subject, payload})

        {:ok,
         %{
           "ok" => true,
           "count" => 1,
           "results" => [
             %{
               "heading" => "Wife care panels",
               "content" => "  The panel and the bot deploy separately.\n  ",
               "metadata" => %{"path" => "/opt/bot_army/docs/panels.md"}
             }
           ]
         }}
      end)

      assert {:ok, text} = CoachLookup.run("docs", "panels", publisher: FakePublisher)
      assert_receive {:asked, "internal_docs.search.hybrid", payload}
      assert payload == %{"query" => "panels", "limit" => 3}
      assert text =~ "Wife care panels"
      assert text =~ "/opt/bot_army/docs/panels.md"
      assert text =~ "The panel and the bot deploy separately."
    end

    test "the para look-up names the path, because that is what makes a hit useful" do
      set_fake(fn "para.fs.search", payload ->
        assert payload == %{"query" => "tax"}

        {:ok,
         %{
           "matches" => [
             %{
               "path" => "personal_os/areas/taxes.md",
               "match_type" => "content",
               "excerpt" => "the 2025 return"
             },
             %{"path" => "personal_os/projects/tax/", "match_type" => "filename"}
           ]
         }}
      end)

      assert {:ok, text} = CoachLookup.run("para", "tax", publisher: FakePublisher)
      assert text =~ "personal_os/areas/taxes.md: the 2025 return"
      # A filename hit has no excerpt; the path is still the answer.
      assert text =~ "personal_os/projects/tax/"
    end

    test "nothing matched is a fact, not a failure" do
      set_fake(fn _, _ -> {:ok, %{"results" => []}} end)
      assert {:ok, text} = CoachLookup.run("docs", "nothing", publisher: FakePublisher)
      assert text =~ "Nothing in the project docs matched"

      set_fake(fn _, _ -> {:ok, %{"matches" => []}} end)
      assert {:ok, text} = CoachLookup.run("para", "nothing", publisher: FakePublisher)
      assert text =~ "Nothing in her PARA files matched"
    end

    test "a search that could not be run is an error the caller can say out loud in words" do
      set_fake(fn _, _ -> {:error, :timeout} end)
      assert CoachLookup.run("para", "tax", publisher: FakePublisher) == {:error, :timeout}
    end

    test "a reply this bot does not recognise is an error, never a silent empty result" do
      set_fake(fn _, _ -> {:ok, %{"unexpected" => true}} end)

      assert {:error, {:unexpected_lookup_reply, %{"unexpected" => true}}} =
               CoachLookup.run("docs", "x", publisher: FakePublisher)
    end

    test "a source that is not one of the two is refused" do
      assert CoachLookup.run("memory", "x", publisher: FakePublisher) ==
               {:error, {:unknown_lookup_source, "memory"}}
    end

    test "the look-up is clamped to what is left of the caller's deadline" do
      # The publisher runs inline, so `self/0` inside it is this test process.
      assert {:ok, _} =
               CoachLookup.run("para", "x",
                 publisher: BotArmyGtd.CoachLookupTest.TimeoutPublisher,
                 timeout_ms: 1
               )

      assert_receive {:para_timeout, 1}
    end

    test "a deadline larger than the look-up's own default does not buy it more time" do
      assert {:ok, _} =
               CoachLookup.run("para", "x",
                 publisher: BotArmyGtd.CoachLookupTest.TimeoutPublisher,
                 timeout_ms: 600_000
               )

      assert_receive {:para_timeout, 25_000}
    end

    test "the para look-up gets the longer of the two timeouts, because it walks a filesystem" do
      assert {:ok, _} =
               CoachLookup.run("docs", "x",
                 publisher: BotArmyGtd.CoachLookupTest.TimeoutPublisher
               )

      assert_receive {:docs_timeout, docs}

      assert {:ok, _} =
               CoachLookup.run("para", "x",
                 publisher: BotArmyGtd.CoachLookupTest.TimeoutPublisher
               )

      assert_receive {:para_timeout, para}
      assert docs < para
    end
  end

  # A publisher that reports the timeout it was handed, so the clamp and the relative size of the
  # two budgets are pinned without a broker.
  defmodule TimeoutPublisher do
    def request(subject, _payload, opts) do
      send(self(), {timeout_key(subject), Keyword.fetch!(opts, :timeout_ms)})
      {:ok, %{"results" => [], "matches" => []}}
    end

    defp timeout_key("internal_docs.search.hybrid"), do: :docs_timeout
    defp timeout_key("para.fs.search"), do: :para_timeout
  end

  defp set_fake(fun) do
    Agent.update(:coach_lookup_fake, fn _ -> fun end)
  end
end
