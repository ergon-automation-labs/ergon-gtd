defmodule BotArmyGtd.Handlers.CoachChatHandler do
  @moduledoc """
  The GTD coach, asked a question: `gtd.coach.chat`.

  One hop from her question to an answer grounded in her own system. The handler reads what
  `BotArmyGtd.CoachChat` needs — her active projects, her open tasks, her inbox — builds the
  message, and asks the LLM bot for a reply. If the answer needs her notes, it runs the one
  look-up the model asked for and asks again with what it found.

  ## Read-only, and what that means here

  This handler calls `list` and nothing else. It cannot create, rename, complete, defer or
  delete a task or a project, and it never will: the model is told so, no writing subject is
  reachable from this path, and the reply carries words only. Nothing here stages a change for
  her to confirm either (§57, §58).

  ## Why it is spawned by the consumer and not awaited

  Every GTD subscription rides on one consumer process, and the LLM round trip is measured in
  seconds — a minute, on the local model — while every other read on this bot is a database hop.
  Answering in the consumer would mean every task list and every write going quiet behind one
  person's question. The consumer therefore spawns this and the mailbox keeps moving; this
  process owns its own reply, and it replies on every path — an answer, a refusal, or the news
  that the coach could not answer — because a question that never gets an answer is the panel
  waiting forever.

  ## One overall budget, not a budget per stage

  The look-up round is a second model round trip, and a budget attached to each stage would stack
  into one the panel cannot be sized against: two fast lanes, a look-up, and two jobs is two
  fifteen-minute waits. So the coach owns a **single** deadline (`@overall_budget_ms`,
  `GTD_COACH_BUDGET_MS`) that is threaded into every stage — each fast lane, the look-up, and
  whatever is left of the background job. When it runs out the reply is an honest `:llm_failed`,
  and the panel's own timeout sits above this whole budget.

  That deadline is a **ceiling, not an expectation**. It is sized far above the slowest honest
  turn so that a working model is waited for and only a wedged one is cut off — a local model
  answering for minutes is working, not failing, and a coach that hung up on it would turn a slow
  answer into "did not reply" and blame the model for our own impatience. The one stage that gets
  a **slice** of its own rather than the whole remainder is the look-up (`@lookup_budget_ms`): it
  runs second, so "whatever is left" would let a slow first lane starve it into a "could not be
  read just now" that says more about the clock than about her files.

  ## The fast lane, and the background job behind it

  The question goes to `llm.prompt.submit` first, because the general local model answers it in
  about a second and that is the answer almost every time. If that hop fails or outlives its
  twenty seconds, the prompt is handed to `CoachJob` as a backgrounded job on the **local**
  uncensored model (`llm.request.chat`, `model_type: "uncensored"`), and this process waits for
  the words, reading `llm.job.status` each time the llm bot rings its bell. The wire is unchanged
  either way: an answer is still an answer and a failure is still `:llm_failed`, so a panel older
  than this behaviour simply times out where this one waits. Her projects and her notes are the
  reason the fallback is pinned local.

  ## A grounded answer, or an honest refusal

  There is no path here that invents a fact. If every hop fails, the reply is `:llm_failed` with a
  sentence of its own, not a made-up project. If a store could not be read, the facts say so and
  the model is told not to describe what she has — the answer is still an answer about her
  system, and the page can draw it.
  """

  require Logger

  alias BotArmyGtd.{CoachChat, CoachJob, CoachLookup, LlmReply, ProjectStore, TaskStore}
  alias BotArmyLibraryCore.Tenant
  alias BotArmyLibraryRuntime.NATS.Reply

  # One deadline for the whole conversation, and a ceiling rather than an expectation: it has to
  # cover two fast lanes (20 s each), a look-up and a backgrounded job, so it is sized above the
  # slowest honest turn — two local jobs — while staying under the panel's own wait. A model that
  # is still thinking is not failing; only a wedged job meets this ceiling.
  @overall_budget_ms 1_200_000
  @overall_budget_env "GTD_COACH_BUDGET_MS"

  # The look-up runs second, so it is given a slice of its own rather than the whole remainder: a
  # first lane that was slow must not starve her notes into "could not be read just now". A minute
  # is far above the folder walk when it answers (measured 2026-10-16: 6 s for `projects`,
  # sub-second for the rest) and only a miss that walks every folder spends it.
  @lookup_budget_ms 60_000

  # Longer than the persona's eight seconds: the grounded message is much bigger — her whole
  # project list and her open tasks — and this is the one read on the panel a person is watching
  # a "thinking" line for rather than blocking a page on.
  @llm_timeout_ms 20_000

  @doc """
  Answer a `gtd.coach.chat` request. Always answers, never raises.

  Returns `:ok` rather than a reply body: this handler is run in its own process and publishes
  its own reply, because the LLM hop may outlive the consumer's dispatch.
  """
  @spec handle_chat(map(), String.t() | nil) :: :ok
  def handle_chat(message, reply_to) when is_binary(reply_to) and reply_to != "" do
    result =
      try do
        %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)
        payload = message["payload"] || message
        question = payload["message"] || payload["question"]

        if is_binary(question) and String.trim(question) != "" do
          ask(tenant_id, user_id, question)
        else
          {:error, :missing_message}
        end
      rescue
        e ->
          Logger.warning("The GTD coach chat raised: #{inspect(e)}")
          {:error, {:raised, e}}
      end

    publish(reply_to, result)
    :ok
  end

  def handle_chat(_message, _reply_to), do: :ok

  # Public only so the tests can prove the wiring: the fast lane, the look-up round, and the
  # fallback onto a local job.
  @doc false
  def ask(tenant_id, user_id, question) do
    deadline = System.monotonic_time(:millisecond) + budget_ms()
    context = context(tenant_id)

    with {:ok, first} <- answer(CoachChat.prompt(question, context), tenant_id, user_id, deadline) do
      case CoachChat.lookup(first) do
        :none ->
          finish(first)

        {:lookup, source, query} ->
          found = look_up(source, query, deadline)
          followup = CoachChat.followup(question, context, first, found)

          case answer(followup, tenant_id, user_id, deadline) do
            {:ok, second} -> finish(second)
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp finish(text) do
    # `clean/1` drops any look-up directive out of the answer. An answer that was *only* a
    # directive is not an answer, and saying so is better than showing her a blank line.
    case CoachChat.clean(text) do
      "" -> {:error, :llm_failed}
      answer -> {:ok, answer}
    end
  end

  # -- the two lanes ----------------------------------------------------------

  defp answer(prompt, tenant_id, user_id, deadline) do
    case fast_answer(prompt, tenant_id, user_id, deadline) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Logger.info(
          "The GTD coach's fast lane did not answer (#{inspect(reason)}); backgrounding a local job"
        )

        case remaining(deadline) do
          ms when ms <= 0 -> {:error, :job_budget_exceeded}
          ms -> CoachJob.ask(prompt, budget_ms: ms)
        end
    end
  end

  defp fast_answer(prompt, tenant_id, user_id, deadline) do
    llm_publisher().request(
      "llm.prompt.submit",
      %{
        "text" => prompt,
        "request_type" => "chat",
        "tenant_id" => tenant_id,
        "user_id" => user_id,
        "timeout_ms" => @llm_timeout_ms
      },
      timeout_ms: min(@llm_timeout_ms, max(remaining(deadline), 1))
    )
    |> LlmReply.read()
  end

  # -- the look-up ------------------------------------------------------------

  # A look-up that failed is a fact the model is given, in words: "that could not be read just
  # now" is what lets it say it found nothing instead of inventing something. It never turns the
  # question into a refusal, because the first answer may already have been good enough.
  defp look_up(source, query, deadline) do
    case remaining(deadline) do
      ms when ms <= 0 ->
        "That could not be read just now."

      ms ->
        case CoachLookup.run(source, query, timeout_ms: min(ms, @lookup_budget_ms)) do
          {:ok, text} ->
            text

          {:error, reason} ->
            Logger.warning("The GTD coach's #{source} look-up failed: #{inspect(reason)}")
            "That could not be read just now."
        end
    end
  end

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  # -- the facts --------------------------------------------------------------

  # The context is built tolerantly on purpose: a store that could not be read is carried as
  # `:unreadable` so `CoachChat` can say so in the facts, rather than taking the whole answer
  # down. A question about her notes should be answerable on a day the task store is not.
  #
  # `whats_next` is deliberately not read here. Its ranking is a separate engine with its own
  # opinion, and an answer grounded in it would be the coach quietly re-ranking her day.
  #
  # Public only so the tests can prove the tolerance — the read that must not turn a hiccup into
  # "you have no open tasks" is exactly the one worth pinning.
  @doc false
  def context(tenant_id) do
    %{
      today: Date.utc_today() |> Date.to_iso8601(),
      projects: read("projects", fn -> project_store().list(tenant_id) end),
      tasks: read("open tasks", fn -> task_store().list(tenant_id, %{"status" => "active"}) end),
      inbox: read("inbox", fn -> task_store().list(tenant_id, %{"status" => "inbox"}) end)
    }
  end

  defp read(what, reader) do
    case reader.() do
      {:ok, list} when is_list(list) -> {:ok, list}
      other -> unreadable(what, other)
    end
  rescue
    e -> unreadable(what, e)
  catch
    kind, reason -> unreadable(what, {kind, reason})
  end

  defp unreadable(what, reason) do
    Logger.warning("The GTD coach could not read her #{what}: #{inspect(reason)}")
    :unreadable
  end

  defp task_store do
    Application.get_env(:bot_army_gtd, :task_store, TaskStore)
  end

  defp project_store do
    Application.get_env(:bot_army_gtd, :project_store, ProjectStore)
  end

  # Read at call time, not at compile time: the budget is an operator's dial.
  defp budget_ms, do: env_ms(@overall_budget_env, @overall_budget_ms)

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

  # -- the reply --------------------------------------------------------------

  # Injectable so a test can answer the fast lane and drive both look-ups without a broker or a
  # model.
  defp llm_publisher do
    Application.get_env(
      :bot_army_gtd,
      :coach_chat_publisher,
      BotArmyLibraryRuntime.NATS.Publisher
    )
  end

  defp publish(reply_to, result), do: reply(reply_to, reply_payload(result))

  @doc false
  def reply_payload({:ok, text}), do: Reply.ok(%{"response" => text})

  def reply_payload({:error, :missing_message}),
    do: Reply.error("ask the coach a question", :missing_message)

  def reply_payload({:error, reason}) do
    Logger.warning("The GTD coach could not answer: #{inspect(reason)}")
    Reply.error("the coach could not answer just now", :llm_failed)
  end

  defp reply(reply_to, encoded) do
    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} -> Gnat.pub(conn, reply_to, encoded)
      {:error, reason} -> Logger.warning("[GTD coach chat] Failed to reply: #{inspect(reason)}")
    end
  end
end
