defmodule BotArmyGtd.Handlers.CoachChatHandlerTest do
  use ExUnit.Case
  @moduletag :handlers

  import Mox

  alias BotArmyGtd.Handlers.CoachChatHandler

  setup :set_mox_global

  @tenant "00000000-0000-0000-0000-000000000001"

  # Both lanes and both look-ups come from here, so the whole conversation is exercised with no
  # broker and no model. `ask/3` is public only so that this file can prove the wiring.
  defmodule FakeLlm do
    def request(subject, payload, _opts) do
      fun = Agent.get(:gtd_coach_chat_fake, & &1)
      fun.(subject, payload)
    end
  end

  setup do
    {:ok, pid} =
      Agent.start_link(fn -> fn _subject, _payload -> flunk("no fake installed") end end)

    Process.register(pid, :gtd_coach_chat_fake)

    Application.put_env(:bot_army_gtd, :coach_chat_publisher, FakeLlm)
    Application.put_env(:bot_army_gtd, :coach_job_publisher, FakeLlm)

    # `:task_store` and `:project_store` are already the Mox mocks in `config/test.exs`; the
    # handler reads them through those same seams, so nothing is installed or removed here. The
    # two publisher seams above are this file's own and are removed on exit.
    on_exit(fn ->
      if Process.alive?(pid), do: Agent.stop(pid)

      Application.delete_env(:bot_army_gtd, :coach_chat_publisher)
      Application.delete_env(:bot_army_gtd, :coach_job_publisher)
    end)

    :ok
  end

  describe "handle_chat/2" do
    test "a question with nobody to answer is dropped, not answered into the void" do
      assert CoachChatHandler.handle_chat(request(), nil) == :ok
      assert CoachChatHandler.handle_chat(request(), "") == :ok
    end
  end

  describe "context/1" do
    test "her projects, her open tasks and her inbox are all read, and today is today" do
      expect_stores(%{"name" => "Feature Development"}, [])

      context = CoachChatHandler.context(@tenant)

      assert context.today == Date.utc_today() |> Date.to_iso8601()
      assert {:ok, [%{"name" => "Feature Development"}]} = context.projects
      assert context.tasks == {:ok, []}
      assert context.inbox == {:ok, []}
    end

    test "a store that raised is unreadable, not a crash and not an empty result" do
      stub(BotArmyGtd.ProjectStoreMock, :list, fn _ -> raise "the store is not there" end)
      stub(BotArmyGtd.TaskStoreMock, :list, fn _, _ -> {:ok, []} end)

      context = CoachChatHandler.context(@tenant)
      assert context.projects == :unreadable
      assert context.tasks == {:ok, []}
    end

    test "a store that exited is unreadable too, not a crash" do
      stub(BotArmyGtd.ProjectStoreMock, :list, fn _ -> exit(:noproc) end)
      stub(BotArmyGtd.TaskStoreMock, :list, fn _, _ -> {:ok, []} end)

      assert CoachChatHandler.context(@tenant).projects == :unreadable
    end
  end

  describe "reply_payload/1" do
    test "an answer is the coach's words under the ok envelope" do
      reply = CoachChatHandler.reply_payload({:ok, "words"}) |> decode()

      assert reply["ok"] == true
      assert reply["data"] == %{"response" => "words"}
    end

    test "a question nobody asked is refused in the handler's own words" do
      reply = CoachChatHandler.reply_payload({:error, :missing_message}) |> decode()

      assert reply["ok"] == false
      assert reply["code"] == "missing_message"
      assert reply["error"] == "ask the coach a question"
    end

    test "every other failure is one honest refusal, never the internal reason" do
      for reason <- [:whatever, :timeout, {:invalid_response, nil}] do
        reply = CoachChatHandler.reply_payload({:error, reason}) |> decode()

        assert reply["ok"] == false
        assert reply["code"] == "llm_failed"
        assert reply["error"] == "the coach could not answer just now"
        refute reply["data"]
      end
    end
  end

  describe "ask/3" do
    test "the fast lane's answer is the answer" do
      expect_stores(%{"name" => "Feature Development"}, [])
      set_llm(fn "llm.prompt.submit", _ -> {:ok, %{"completion" => "the fast words"}} end)

      assert CoachChatHandler.ask(@tenant, "u", "q") == {:ok, "the fast words"}
    end

    test "her stores are in front of the model before it is asked" do
      test_pid = self()

      expect_stores(
        %{"name" => "Feature Development"},
        [%{"title" => "Renew the domain", "project_id" => "p1", "status" => "active"}]
      )

      set_llm(fn "llm.prompt.submit", payload ->
        send(test_pid, {:prompt, payload["text"]})
        {:ok, %{"completion" => "words"}}
      end)

      assert {:ok, "words"} = CoachChatHandler.ask(@tenant, "u", "where is the domain thing?")
      assert_receive {:prompt, prompt}
      assert prompt =~ "Feature Development"
      assert prompt =~ "Renew the domain"
      assert prompt =~ "where is the domain thing?"
    end

    test "a fast lane that fails backgrounds a local job instead of losing the question" do
      expect_stores(%{"name" => "Feature Development"}, [])

      set_llm(fn
        "llm.prompt.submit", _ ->
          {:error, :timeout}

        "llm.request.chat", _ ->
          {:ok, %{"job_id" => "job-x", "status" => "accepted"}}

        "llm.job.status", _ ->
          {:ok,
           %{"ok" => true, "status" => "completed", "result" => %{"content" => "the slow words"}}}
      end)

      assert CoachChatHandler.ask(@tenant, "u", "q") == {:ok, "the slow words"}
    end

    test "both lanes failing is a refusal, never an invented answer" do
      expect_stores(%{"name" => "Feature Development"}, [])

      set_llm(fn
        "llm.prompt.submit", _ -> {:error, :timeout}
        "llm.request.chat", _ -> {:error, :timeout}
      end)

      assert CoachChatHandler.ask(@tenant, "u", "q") == {:error, :timeout}
    end

    test "the model may look her notes up once, and the answer comes from what it found" do
      expect_stores(%{"name" => "Feature Development"}, [])
      test_pid = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      set_llm(fn
        "llm.prompt.submit", payload ->
          case Agent.get_and_update(calls, fn n -> {n, n + 1} end) do
            0 ->
              assert payload["text"] =~ "where is the tax thing?"
              {:ok, %{"completion" => ~s(LOOKUP para "tax 2025")}}

            _ ->
              send(test_pid, {:followup, payload["text"]})
              {:ok, %{"completion" => "Your 2025 return is in areas/taxes.md."}}
          end

        "para.fs.search", payload ->
          assert payload == %{"query" => "tax 2025", "scope" => "projects"}

          # The para bot answers inside the core envelope (measured 2026-10-16).
          {:ok,
           %{
             "data" => %{
               "matches" => [
                 %{
                   "path" => "personal_os/areas/taxes.md",
                   "match_type" => "content",
                   "excerpt" => "the return"
                 }
               ]
             },
             "ok" => true
           }}
      end)

      assert CoachChatHandler.ask(@tenant, "u", "where is the tax thing?") ==
               {:ok, "Your 2025 return is in areas/taxes.md."}

      assert_receive {:followup, followup}
      assert followup =~ "the return"
      assert followup =~ ~s(LOOKUP para "tax 2025")
    end

    test "a look-up that failed is said in words, and the question is still answered" do
      expect_stores(%{"name" => "Feature Development"}, [])
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      set_llm(fn
        "llm.prompt.submit", _ ->
          case Agent.get_and_update(calls, fn n -> {n, n + 1} end) do
            0 -> {:ok, %{"completion" => ~s(LOOKUP docs "panels")}}
            _ -> {:ok, %{"completion" => "I could not read your notes just now."}}
          end

        "internal_docs.search.hybrid", _ ->
          {:error, :timeout}
      end)

      assert CoachChatHandler.ask(@tenant, "u", "what do the panel docs say?") ==
               {:ok, "I could not read your notes just now."}
    end

    test "an answer that was only a directive is a failure, not a blank line" do
      expect_stores(%{"name" => "Feature Development"}, [])
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      set_llm(fn
        "llm.prompt.submit", _ ->
          case Agent.get_and_update(calls, fn n -> {n, n + 1} end) do
            # The second round answers with nothing but a second directive. There is no third
            # round to give it, so what is left is an empty answer — and an empty answer is not an
            # answer.
            0 -> {:ok, %{"completion" => ~s(LOOKUP para "tax")}}
            _ -> {:ok, %{"completion" => ~s(LOOKUP docs "tax")}}
          end

        "para.fs.search", _ ->
          {:ok, %{"matches" => []}}
      end)

      assert CoachChatHandler.ask(@tenant, "u", "q") == {:error, :llm_failed}
    end

    test "a directive is never shown to her, even when the model appends it to a real answer" do
      expect_stores(%{"name" => "Feature Development"}, [])

      set_llm(fn
        "llm.prompt.submit", _ ->
          {:ok, %{"completion" => "You have one project open.\nLOOKUP docs \"x\""}}
      end)

      assert CoachChatHandler.ask(@tenant, "u", "q") == {:ok, "You have one project open."}
    end

    test "a store the coach could not read is said in the facts, not turned into an empty system" do
      stub(BotArmyGtd.ProjectStoreMock, :list, fn _ -> {:error, :timeout} end)
      stub(BotArmyGtd.TaskStoreMock, :list, fn _, _ -> {:error, :timeout} end)

      test_pid = self()

      set_llm(fn "llm.prompt.submit", payload ->
        send(test_pid, {:prompt, payload["text"]})
        {:ok, %{"completion" => "words"}}
      end)

      assert {:ok, "words"} = CoachChatHandler.ask(@tenant, "u", "q")
      assert_receive {:prompt, prompt}
      assert prompt =~ "could not be read just now"
      refute prompt =~ "she has none"
    end
  end

  # Same workspace contract as the other schema-parity tests: the schemas repo is a sibling
  # checkout and the bot is the side that must not drift from it.
  describe "parity with the published schema" do
    test "the refusal codes the handler utters are the only ones the reply allows" do
      schema = "gtd.coach.chat.reply.json" |> gtd_schema()
      [_ok, refused] = schema["oneOf"]

      assert refused["properties"]["code"]["enum"] == ["missing_message", "llm_failed"]
    end

    test "the request field the handler reads is the field the schema calls required" do
      schema = "gtd.coach.chat.json" |> gtd_schema()

      assert schema["properties"]["payload"]["required"] == ["message"]
    end
  end

  defp gtd_schema(name) do
    Path.expand("../../../../../schemas/bot_army_schemas_gtd/schemas", __DIR__)
    |> Path.join(name)
    |> File.read!()
    |> Jason.decode!()
  end

  defp request do
    %{
      "event" => "gtd.coach.chat",
      "tenant_id" => @tenant,
      "user_id" => "00000000-0000-0000-0000-000000000002",
      "payload" => %{"message" => "what am I working on?"}
    }
  end

  defp expect_stores(project, tasks) do
    stub(BotArmyGtd.ProjectStoreMock, :list, fn _ -> {:ok, [project]} end)

    stub(BotArmyGtd.TaskStoreMock, :list, fn
      _, %{"status" => "active"} -> {:ok, tasks}
      _, %{"status" => "inbox"} -> {:ok, []}
    end)
  end

  defp set_llm(fun) do
    Agent.update(:gtd_coach_chat_fake, fn _ -> fun end)
  end

  defp decode(encoded) when is_binary(encoded), do: Jason.decode!(encoded)
end
