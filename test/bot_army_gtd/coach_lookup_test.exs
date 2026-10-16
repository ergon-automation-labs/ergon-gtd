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
        assert payload == %{"query" => "tax", "scope" => "projects"}

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

    test "the para look-up asks one folder at a time, and stops at the first folder that answers" do
      # A whole-tree search answers only when it has finished walking, so a search that times out
      # returns nothing at all — not the matches it had already found. Asking one folder at a time
      # is what makes an answer survive a slow folder, and stopping at the first hit is what keeps
      # the common question to a handful of seconds.
      set_fake(fn "para.fs.search", payload ->
        send(self(), {:asked, payload["scope"]})
        {:ok, %{"matches" => [%{"path" => "personal_os/projects/tax/plan.md"}]}}
      end)

      assert {:ok, text} = CoachLookup.run("para", "tax", publisher: FakePublisher)
      assert_receive {:asked, "projects"}
      # The publisher runs inline, so a second folder would already be in the mailbox by now.
      refute_received {:asked, _other}
      assert text =~ "personal_os/projects/tax/plan.md"
    end

    test "a folder with nothing in it does not end the search — the next folder is asked" do
      set_fake(fn "para.fs.search", payload ->
        send(self(), {:asked, payload["scope"]})

        case payload["scope"] do
          "projects" ->
            {:ok, %{"matches" => []}}

          "areas" ->
            {:ok, %{"matches" => [%{"path" => "personal_os/areas/taxes.md"}]}}
        end
      end)

      assert {:ok, text} = CoachLookup.run("para", "tax", publisher: FakePublisher)
      assert_receive {:asked, "projects"}
      assert_receive {:asked, "areas"}
      refute_received {:asked, _other}
      assert text =~ "personal_os/areas/taxes.md"
    end

    test "a folder that could not be read does not throw away what the folders before it found" do
      set_fake(fn "para.fs.search", payload ->
        case payload["scope"] do
          "projects" ->
            {:error, :timeout}

          "areas" ->
            {:ok, %{"matches" => [%{"path" => "personal_os/areas/taxes.md"}]}}

          other ->
            flunk("should have stopped at the folder that answered, but asked #{other}")
        end
      end)

      assert {:ok, text} = CoachLookup.run("para", "tax", publisher: FakePublisher)
      assert text =~ "personal_os/areas/taxes.md"
    end

    test "a search that ran out of budget says which folders it got to" do
      # Four of her five folders fit in a few seconds; the fifth is big enough to spend the whole
      # budget by itself. Reporting that search as "nothing matched" would be a lie of omission
      # about the one folder she would have wanted looked in.
      set_fake(fn "para.fs.search", _payload ->
        Process.sleep(80)
        {:ok, %{"matches" => []}}
      end)

      assert {:ok, text} =
               CoachLookup.run("para", "tax", publisher: FakePublisher, timeout_ms: 40)

      assert text =~ "Nothing matched those words in her projects"
      assert text =~ "ran out of time before it finished areas, inbox, archive and resources"
      refute text =~ "Nothing in her PARA files matched"
    end

    test "each folder is offered what is left of the budget, never more" do
      assert {:ok, _text} =
               CoachLookup.run("para", "x", publisher: BotArmyGtd.CoachLookupTest.SlicePublisher)

      assert_receive {:para_slice, "projects", first}
      assert_receive {:para_slice, "areas", second}
      assert first == 25_000
      assert second <= first
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

  # A publisher that reports the timeout each folder was handed, so the slicing of the budget is
  # pinned without a clock: the first folder gets the whole budget, and no folder after it gets more
  # than the one before.
  defmodule SlicePublisher do
    def request("para.fs.search", payload, opts) do
      send(self(), {:para_slice, payload["scope"], Keyword.fetch!(opts, :timeout_ms)})
      {:ok, %{"matches" => []}}
    end

    def request(_subject, _payload, _opts), do: {:ok, %{"results" => []}}
  end

  defp set_fake(fun) do
    Agent.update(:coach_lookup_fake, fn _ -> fun end)
  end
end
