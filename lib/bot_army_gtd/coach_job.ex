defmodule BotArmyGtd.CoachJob do
  @moduledoc """
  The coach's question, backgrounded on the local model when the fast lane cannot answer.

  `gtd.coach.chat` asks `llm.prompt.submit` first: the general local model usually answers in
  about a second, and that is the answer most of the time. When that hop fails or outlives its
  twenty seconds, the question is not lost — it is handed to the llm bot as a **background job**
  (`llm.request.chat` with `"async" => true`) and this module waits for the words.

  ## Why a job, and not a longer blocking request

  A local model's duration is a property of the model, not a fault. Blocking one request/reply
  for it forces the caller to invent a wall-clock deadline for work whose duration is unknowable,
  and a guess that is too small *silently* loses the answer. The job protocol separates the two:
  the submit returns a `job_id` immediately, and the wait becomes polling with a budget the
  caller owns. This module's own budget is fifteen minutes (`GTD_COACH_JOB_BUDGET_MS`) and it is a
  net for a job that has **wedged**, not a guess at how long a model may think; the coach usually
  hands it less, because it threads one overall deadline through the whole conversation and the
  job only gets what is left of it. A local model answering for minutes is working, and the panel
  waits past all of it rather than turn a slow answer into "did not reply".

  ## Local-only by construction

  The job asks for `"model_type" => "uncensored"`. That type is served by a **local** model and
  the llm bot promises never to substitute a cloud provider for it (the same promise the wife-care
  narrator leans on). Her projects, her tasks and her notes are hers; the fallback is the path
  that must not export them.

  ## The bell, and why the status is still read

  Waiting is *on* the job, not *for* it: while the job is pending this process sits in `receive`
  on `BotArmyGtd.JobBell`, which the consumer rings when `events.llm.job.completed` arrives. The
  bell (or the patience running out) ends the wait, and then `llm.job.status` is **read** — a bell
  is a wake-up, never a proof, and one that arrived before the result was stored must not be
  mistaken for the result. Against an llm bot that does not ring, the patience is also the polling
  cadence, so the behaviour degrades to exactly what it was before the bell existed.
  """

  require Logger

  alias BotArmyGtd.{JobBell, LlmReply}

  @subject "llm.request.chat"
  @status_subject "llm.job.status"

  # The prompt is big (her projects, her tasks, her inbox) but the submit itself is a round trip
  # to the llm bot and returns an acceptance immediately; twenty seconds is generous for the hop.
  @submit_timeout_ms 20_000
  @status_timeout_ms 10_000

  # How long the job may take before we stop being patient. A net for a wedged job rather than a
  # guess at how long a model may think; an operator can move it without a release
  # (`GTD_COACH_JOB_BUDGET_MS`). The coach normally passes a smaller budget of its own — whatever
  # is left of its single overall deadline.
  @job_budget_ms 900_000
  @job_budget_env "GTD_COACH_JOB_BUDGET_MS"
  @poll_ms 2_000

  # One unreachable status is "the model is thinking"; three in a row is "nobody is answering".
  @max_status_errors 3

  # The type whose promise is "served by a local model, never a cloud provider".
  @model_type "uncensored"

  @doc """
  Ask the llm bot for a backgrounded answer and wait for its words.

  Returns `{:ok, text}` or `{:error, reason}` — reasons are the caller's to read, never hers.
  """
  @spec ask(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ask(prompt, opts \\ []) when is_binary(prompt) do
    case submit(prompt, opts) do
      {:job, job_id} -> await(job_id, deadline(opts), opts, 0)
      {:answer, text} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- submit -----------------------------------------------------------------

  defp submit(prompt, opts) do
    payload = %{
      "prompt_context" => %{"prompt" => prompt},
      "async" => true,
      "model_type" => @model_type
    }

    case publisher(opts).request(@subject, payload,
           timeout_ms: Keyword.get(opts, :submit_timeout_ms, @submit_timeout_ms)
         ) do
      {:ok, %{"job_id" => job_id}} when is_binary(job_id) -> {:job, job_id}
      # An llm bot older than the async path answers in one shot, and that answer is the answer.
      {:ok, reply} when is_map(reply) -> LlmReply.text(reply) |> wrap_sync()
      {:error, reason} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_job_reply, other}}
    end
  rescue
    e -> {:error, {:submit_raised, Exception.message(e)}}
  catch
    # A Gnat call to a connection that is not there *exits*; rescuing alone would miss it.
    kind, reason -> {:error, {:submit_crashed, kind, reason}}
  end

  defp wrap_sync({:ok, text}), do: {:answer, text}
  defp wrap_sync({:error, reason}), do: {:error, reason}

  # -- wait -------------------------------------------------------------------

  defp await(job_id, deadline, opts, errors) do
    JobBell.watch(job_id)

    try do
      poll(job_id, deadline, opts, errors)
    after
      JobBell.unwatch(job_id)
    end
  end

  defp poll(job_id, deadline, opts, errors) do
    cond do
      errors >= @max_status_errors -> {:error, :job_status_unreachable}
      System.monotonic_time(:millisecond) > deadline -> {:error, :job_budget_exceeded}
      true -> poll_status(job_id, deadline, opts, errors)
    end
  end

  defp poll_status(job_id, deadline, opts, errors) do
    case status(job_id, opts) do
      {:done, text} -> {:ok, text}
      :pending -> wait_then_poll(job_id, deadline, opts, 0)
      :failed -> {:error, :llm_failed}
      :missing -> {:error, :llm_failed}
      :unreachable -> wait_then_poll(job_id, deadline, opts, errors + 1)
    end
  end

  # The wait between status reads. A bell for this job ends it; so does a bell for somebody
  # else's (draining it costs one status request and keeps a neighbour's message from sitting in
  # this mailbox until the next model finishes); so does the patience running out.
  defp wait_then_poll(job_id, deadline, opts, errors) do
    wait_ms = Keyword.get(opts, :poll_ms, @poll_ms)

    receive do
      {:job_bell, _job_id} -> :ok
    after
      wait_ms -> :ok
    end

    poll(job_id, deadline, opts, errors)
  end

  defp status(job_id, opts) do
    case publisher(opts).request(@status_subject, %{"job_id" => job_id},
           timeout_ms: Keyword.get(opts, :status_timeout_ms, @status_timeout_ms)
         ) do
      {:ok, %{"ok" => true, "status" => "completed"} = reply} -> completed(reply["result"])
      {:ok, %{"ok" => true, "status" => "pending"}} -> :pending
      {:ok, %{"ok" => true, "status" => "failed"}} -> :failed
      {:ok, %{"ok" => false, "error" => "job_not_found"}} -> :missing
      {:ok, other} -> unexpected_status(other)
      {:error, _reason} -> :unreachable
    end
  rescue
    _e -> :unreachable
  catch
    _kind, _reason -> :unreachable
  end

  # A completed job whose result carries no words is not an answer: storing an empty string would
  # make the page say "answered" about silence.
  defp completed(result) do
    case LlmReply.text(result) do
      {:ok, text} -> {:done, text}
      {:error, _reason} -> :failed
    end
  end

  defp unexpected_status(other) do
    Logger.warning("[coach job] Unexpected status reply: #{inspect(other)}")
    :unreachable
  end

  defp deadline(opts) do
    System.monotonic_time(:millisecond) + budget_ms(opts)
  end

  # Read at call time, not at compile time: the budget is an operator's dial. A caller that owns a
  # larger deadline (the coach does) passes what is left of it, so the job can never outlive the
  # conversation; zero or less means there is nothing left, and the wait ends before it starts.
  defp budget_ms(opts) do
    case Keyword.get(opts, :budget_ms) do
      ms when is_integer(ms) -> ms
      _other -> env_ms(@job_budget_env, @job_budget_ms)
    end
  end

  defp env_ms(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {ms, ""} when ms > 0 -> ms
          _other -> default
        end
    end
  end

  # Injectable so a test can drive the whole wait — submit, pending, bell, completed — with no
  # broker and no model. A caller may pass `:publisher` itself; otherwise it is the fleet one.
  defp publisher(opts) do
    Keyword.get(opts, :publisher) ||
      Application.get_env(
        :bot_army_gtd,
        :coach_job_publisher,
        BotArmyLibraryRuntime.NATS.Publisher
      )
  end
end
