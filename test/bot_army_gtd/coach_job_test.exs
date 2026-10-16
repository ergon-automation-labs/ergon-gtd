defmodule BotArmyGtd.CoachJobTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.{CoachJob, JobBell}

  # Every reply the job client reads — submit and status — comes from here, so the whole wait is
  # exercised with no broker and no model. The test installs a function; the function decides
  # what each subject answers, and can talk to the test process to drive the bell.
  defmodule FakePublisher do
    def request(subject, payload, _opts) do
      fun = Agent.get(:coach_job_fake, & &1)
      fun.(subject, payload)
    end
  end

  setup do
    {:ok, pid} =
      Agent.start_link(fn -> fn _subject, _payload -> flunk("no fake installed") end end)

    # Registered by name so `FakePublisher` (a module, not a captured closure) can find it.
    Process.register(pid, :coach_job_fake)

    on_exit(fn ->
      if Process.alive?(pid), do: Agent.stop(pid)
    end)

    :ok
  end

  describe "ask/2" do
    test "waits on the bell and reads the words from the store" do
      test_pid = self()
      {:ok, polls} = Agent.start_link(fn -> 0 end)

      set_fake(fn
        "llm.request.chat", _payload ->
          {:ok, %{"job_id" => "job-1", "status" => "accepted"}}

        "llm.job.status", _payload ->
          case Agent.get_and_update(polls, fn n -> {n, n + 1} end) do
            0 ->
              send(test_pid, :first_status)
              {:ok, %{"ok" => true, "job_id" => "job-1", "status" => "pending"}}

            _ ->
              {:ok,
               %{
                 "ok" => true,
                 "job_id" => "job-1",
                 "status" => "completed",
                 "result" => %{"content" => "you have three projects open"}
               }}
          end
      end)

      task = Task.async(fn -> CoachJob.ask("q", publisher: FakePublisher, poll_ms: 5_000) end)

      assert_receive :first_status, 1_000
      # The waiter is now in `receive`. A bell for its job must end the wait without the poll
      # interval elapsing — that is the whole point of the bell.
      JobBell.ring("job-1")

      assert Task.await(task, 1_000) == {:ok, "you have three projects open"}
    end

    test "the job asks for the local-only model, never the default lane" do
      test_pid = self()

      set_fake(fn
        "llm.request.chat", payload ->
          send(test_pid, {:submitted, payload})
          {:ok, %{"job_id" => "job-lane"}}

        "llm.job.status", _ ->
          {:ok, %{"ok" => true, "status" => "completed", "result" => %{"content" => "words"}}}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher) == {:ok, "words"}
      assert_receive {:submitted, payload}
      assert payload["async"] == true
      assert payload["model_type"] == "uncensored"
      assert payload["prompt_context"]["prompt"] == "q"
    end

    test "a completed job with no words is a failure, not an empty answer" do
      set_fake(fn
        "llm.request.chat", _ -> {:ok, %{"job_id" => "job-2"}}
        "llm.job.status", _ -> {:ok, %{"ok" => true, "status" => "completed", "result" => %{}}}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher) == {:error, :llm_failed}
    end

    test "a failed job is a refusal" do
      set_fake(fn
        "llm.request.chat", _ -> {:ok, %{"job_id" => "job-3"}}
        "llm.job.status", _ -> {:ok, %{"ok" => true, "status" => "failed", "error" => "boom"}}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher) == {:error, :llm_failed}
    end

    test "a job the store has forgotten is a refusal, never a retry forever" do
      set_fake(fn
        "llm.request.chat", _ -> {:ok, %{"job_id" => "job-4"}}
        "llm.job.status", _ -> {:ok, %{"ok" => false, "error" => "job_not_found"}}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher) == {:error, :llm_failed}
    end

    test "an llm bot older than the async path answers in one shot" do
      set_fake(fn
        "llm.request.chat", _ -> {:ok, %{"content" => "answered the old way"}}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher) == {:ok, "answered the old way"}
    end

    test "a submit that never reaches the llm bot is its own error" do
      set_fake(fn
        "llm.request.chat", _ -> {:error, :timeout}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher) == {:error, :timeout}
    end

    test "the budget bounds the wait, not the model" do
      set_fake(fn
        "llm.request.chat", _ -> {:ok, %{"job_id" => "job-5"}}
        "llm.job.status", _ -> flunk("the budget was already spent; the store must not be asked")
      end)

      assert CoachJob.ask("q", publisher: FakePublisher, budget_ms: 0) ==
               {:error, :job_budget_exceeded}
    end

    test "three unreachable status reads in a row end the wait" do
      set_fake(fn
        "llm.request.chat", _ -> {:ok, %{"job_id" => "job-6"}}
        "llm.job.status", _ -> {:error, :timeout}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher, poll_ms: 0, status_timeout_ms: 10) ==
               {:error, :job_status_unreachable}
    end

    test "an unexpected status shape is unreachable, not a crash" do
      set_fake(fn
        "llm.request.chat", _ -> {:ok, %{"job_id" => "job-7"}}
        "llm.job.status", _ -> {:ok, "not a map"}
      end)

      assert CoachJob.ask("q", publisher: FakePublisher, poll_ms: 0, status_timeout_ms: 10) ==
               {:error, :job_status_unreachable}
    end
  end

  defp set_fake(fun) do
    Agent.update(:coach_job_fake, fn _ -> fun end)
  end
end
