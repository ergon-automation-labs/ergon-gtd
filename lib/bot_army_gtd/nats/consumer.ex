defmodule BotArmyGtd.NATS.Consumer do
  @moduledoc """
  NATS message consumer for the GTD bot.

  Subscribes to NATS subjects matching GTD message patterns:
  - `gtd.task.*` - Task-related events
  - `gtd.project.*` - Project-related events

  Messages are decoded using BotArmyCore.NATS.Decoder and routed to
  appropriate handlers based on the event type.

  ## Features

  - Automatic subscription to GTD topics
  - Message decoding and validation
  - Event-based routing to handlers
  - Graceful error handling and recovery
  - Comprehensive logging

  ## Connection Management

  The consumer maintains a persistent NATS connection. If the connection
  is lost, it will attempt to reconnect with exponential backoff.

  ## Implementation

  This implementation uses a GenServer to manage subscriptions. In production,
  this would connect to a real NATS broker. The structure supports dependency
  injection for testing and mocking.
  """

  use GenServer
  require Logger

  alias BotArmyCore.NATS.Decoder

  alias BotArmyGtd.Handlers.{
    ClaudeHandler,
    ConversationHandler,
    DecompositionHandler,
    InboxHandler,
    InboxParsingHandler,
    LogEnrichmentHandler,
    LogEntryHandler,
    PlanHandler,
    ProjectHandler,
    SubtaskHandler,
    TaskHandler,
    WhatsNextHandler
  }

  alias BotArmyRuntime.Intent.ArmyOpinionVote
  alias BotArmyRuntime.NATS.{Connection, Reply}
  alias BotArmyRuntime.Registry
  alias BotArmyRuntime.Tracing

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]
  @registry_heartbeat_ms 20_000

  # Register subjects for the registry
  @subjects [
    %{subject: "gtd.inbox.add", type: :subscribe, description: "Add items to inbox"},
    %{subject: "gtd.task.create", type: :request_reply, description: "Create a task"},
    %{subject: "gtd.task.update", type: :request_reply, description: "Update a task"},
    %{subject: "gtd.task.list", type: :request_reply, description: "List tasks"},
    %{subject: "gtd.task.get", type: :request_reply, description: "Get single task by id"},
    %{subject: "gtd.task.search", type: :request_reply, description: "Search tasks"},
    %{subject: "gtd.task.complete", type: :request_reply, description: "Complete a task"},
    %{subject: "gtd.task.command.defer", type: :subscribe, description: "Defer task"},
    %{subject: "gtd.task.command.delete", type: :subscribe, description: "Delete task"},
    %{subject: "gtd.task.decompose", type: :subscribe, description: "Decompose task"},
    %{
      subject: "gtd.decomposition.approve",
      type: :subscribe,
      description: "Approve decomposition"
    },
    %{subject: "gtd.decomposition.reject", type: :subscribe, description: "Reject decomposition"},
    %{subject: "gtd.decomposition.review", type: :subscribe, description: "Review decomposition"},
    %{
      subject: "gtd.decomposition.request_review",
      type: :subscribe,
      description: "Request decomposition review"
    },
    %{subject: "gtd.project.create", type: :request_reply, description: "Create a project"},
    %{subject: "gtd.project.update", type: :request_reply, description: "Update a project"},
    %{subject: "gtd.project.list", type: :request_reply, description: "List projects"},
    %{subject: "gtd.log.create", type: :subscribe, description: "Create log entry"},
    %{
      subject: "gtd.decomposition.list_due",
      type: :request_reply,
      description: "List due decompositions"
    },
    %{
      subject: "events.llm.response.parsed",
      type: :subscribe,
      description: "LLM response parsed"
    },
    %{
      subject: "events.llm.chain.completed",
      type: :subscribe,
      description: "LLM chain completed"
    },
    %{subject: "claude.task.create", type: :subscribe, description: "Claude task creation"},
    %{
      subject: "claude.operation.success",
      type: :subscribe,
      description: "Claude operation success"
    },
    # Cross-bot conversation protocol
    %{
      subject: "conv.request.gtd.*",
      type: :subscribe,
      description: "Cross-bot conversation requests",
      capabilities: ["task.query", "task.count", "context.summary", "inbox.add"],
      conversation_support: %{
        supported: true,
        message_types: ["query", "command", "confirm", "gossip"],
        max_turns: 3
      }
    },
    %{
      subject: "conv.mailbox.gtd",
      type: :subscribe,
      description: "Cross-bot mailbox messages",
      capabilities: ["gossip.check_in"]
    },
    %{
      subject: "conv.followup.*",
      type: :subscribe,
      description: "Multi-turn conversation followups"
    },
    %{
      subject: "ops.deploy.>",
      type: :subscribe,
      description: "Deploy lifecycle events"
    },
    %{
      subject: "gossip.intent.proposed",
      type: :subscribe,
      description: "Topic-agnostic gossip intent proposals"
    },
    %{
      subject: "gossip.social.invite",
      type: :subscribe,
      description: "Adaptive social gossip invites"
    },
    %{
      subject: "gtd.whats_next",
      type: :request_reply,
      description: "Get what's-next ranking snapshot"
    },
    %{
      subject: "gossip.poll.broadcast",
      type: :subscribe,
      description: "Army general poll broadcast messages"
    },
    %{
      subject: "synapse.army_general.poll.broadcast",
      type: :subscribe,
      description: "GTD poll broadcast from PollOrchestrator"
    },
    %{
      subject: "bot_army.gtd.intent.nudge",
      type: :subscribe,
      description: "Intent: nudge user about stale tasks"
    },
    %{
      subject: "bot_army.gtd.intent.remind",
      type: :subscribe,
      description: "Intent: remind user about deadlines/idle projects"
    },
    %{
      subject: "gtd.army.opinion.vote",
      type: :request_reply,
      description: "Army opinion collect voter (persona-style choice)"
    },
    %{
      subject: "gtd.para.backfill",
      type: :request_reply,
      description: "Backfill PARA folders for existing GTD projects"
    },
    %{
      subject: "gtd.para.cleanup",
      type: :request_reply,
      description: "Sweep and archive stale PARA projects"
    },
    %{
      subject: "gtd.review.weekly",
      type: :request_reply,
      description: "Generate weekly review summary"
    },
    %{
      subject: "gtd.review.inbox_aging",
      type: :request_reply,
      description: "Find stale inbox items"
    },
    %{
      subject: "gtd.review.coherence",
      type: :request_reply,
      description: "Check project-task coherence"
    },
    %{
      subject: "gtd.goal.plan",
      type: :request_reply,
      description: "Decompose goal into tasks and create plan"
    },
    %{
      subject: "gtd.goal.status",
      type: :request_reply,
      description: "Get plan status"
    },
    %{
      subject: "gtd.goal.list",
      type: :request_reply,
      description: "List active plans"
    },
    %{
      subject: "gtd.goal.cancel",
      type: :request_reply,
      description: "Cancel a plan"
    },
    %{
      subject: "dispatcher.subtask.intent.bot_army_gtd",
      type: :subscribe,
      description: "Dispatcher subtask intent (Phase 2: autonomous execution)"
    }
  ]

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Route decoded message to appropriate handler based on event type.

  This is the core dispatch logic that routes incoming messages to handlers.
  Handles both GTD-internal events and cross-bot events from LLM bot.
  """
  def route_message(message) do
    event = message["event"]

    cond do
      is_binary(event) and String.starts_with?(event, "conv.request.gtd.") ->
        ConversationHandler.handle_request(message)

      is_binary(event) and String.starts_with?(event, "conv.followup.") ->
        ConversationHandler.handle_request(message)

      event == "conv.mailbox.gtd" ->
        ConversationHandler.handle_mailbox(message)

      true ->
        route_event(event, message)
    end
  end

  defp route_event("gtd.inbox.add", message) do
    InboxHandler.handle_add(message)
  end

  defp route_event("gtd.task.create", message) do
    TaskHandler.handle_create(message)
  end

  defp route_event("gtd.task.update", message) do
    TaskHandler.handle_update(message)
  end

  defp route_event("gtd.task.complete", message) do
    TaskHandler.handle_complete(message)
  end

  defp route_event("gtd.task.command.defer", message) do
    TaskHandler.handle_defer(message)
  end

  defp route_event("gtd.task.command.delete", message) do
    TaskHandler.handle_delete(message)
  end

  defp route_event("gtd.task.decompose", message) do
    DecompositionHandler.handle_decompose(message)
  end

  defp route_event("gtd.decomposition.approve", message) do
    DecompositionHandler.handle_approve(message)
  end

  defp route_event("gtd.decomposition.reject", message) do
    DecompositionHandler.handle_reject(message)
  end

  defp route_event("gtd.decomposition.review", message) do
    DecompositionHandler.handle_review(message)
  end

  defp route_event("gtd.decomposition.request_review", message) do
    DecompositionHandler.handle_request_review(message)
  end

  defp route_event("gtd.project.create", message) do
    ProjectHandler.handle_create(message)
  end

  defp route_event("gtd.project.update", message) do
    ProjectHandler.handle_update(message)
  end

  defp route_event("gtd.goal.plan", message) do
    PlanHandler.handle_goal_plan(message)
  end

  defp route_event("gtd.goal.status", message) do
    PlanHandler.handle_goal_status(message)
  end

  defp route_event("gtd.goal.list", message) do
    PlanHandler.handle_goal_list(message)
  end

  defp route_event("gtd.goal.cancel", message) do
    PlanHandler.handle_goal_cancel(message)
  end

  defp route_event("gtd.log.create", message) do
    LogEntryHandler.handle_create(message)
  end

  defp route_event("llm.response.parsed", message) do
    case get_in(message, ["payload", "enrichment_source"]) do
      "log_enrichment" ->
        LogEnrichmentHandler.handle_enriched(message)

      _ ->
        InboxParsingHandler.handle_parse(message)
    end
  end

  defp route_event("llm.chain.completed", message) do
    DecompositionHandler.handle_chain_completed(message)
  end

  defp route_event("claude.task.create", message) do
    ClaudeHandler.handle_task_create(message)
  end

  defp route_event("claude.operation.success", message) do
    ClaudeHandler.handle_operation_success(message)
  end

  defp route_event("dispatcher.subtask.intent", message) do
    SubtaskHandler.handle_subtask_intent(message)
  end

  defp route_event(event, _message) do
    Logger.debug("Unknown event type: #{event}")
  end

  defp parse_task_list_params(body) do
    case Jason.decode(body) do
      {:ok, params} ->
        tid = extract_tenant_id(params)
        lim = min(params["limit"] || 100, 500)
        off = params["offset"] || 0

        filters = %{
          "status" => params["status"],
          "labels" => params["labels"],
          "sort" => params["sort"],
          "order" => params["order"]
        }

        {tid, lim, off, filters}

      _ ->
        {Application.get_env(:bot_army_gtd, :default_tenant_id, "default"), 100, 0, %{}}
    end
  end

  defp extract_tenant_id(params) do
    case params["tenant_id"] do
      t when is_binary(t) and t != "" -> t
      _ -> Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
    end
  end

  defp fetch_task_list_response(task_store, tenant_id, filters, limit, offset) do
    case task_store.list_prioritized(tenant_id, filters) do
      {:ok, all_tasks} ->
        page = all_tasks |> Enum.drop(offset) |> Enum.take(limit)

        Reply.ok(%{
          "tasks" => page,
          "total_count" => length(all_tasks),
          "limit" => limit,
          "offset" => offset
        })

      {:error, reason} ->
        Reply.error(inspect(reason), :list_failed)
    end
  end

  defp extract_decomposition_tenant_id(body) do
    case Jason.decode(body) do
      {:ok, %{"tenant_id" => tid}} when is_binary(tid) and tid != "" ->
        tid

      _ ->
        Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
    end
  end

  defp fetch_due_decompositions_response(store, tenant_id) do
    now = DateTime.utc_now()

    case store.list(tenant_id) do
      {:ok, decompositions} ->
        due =
          decompositions
          |> Enum.filter(&due_for_review?(&1, now))
          |> Enum.sort_by(fn d -> d["due_at"] end)

        Reply.ok(%{"decompositions" => due})

      {:error, reason} ->
        Reply.error(inspect(reason), :list_failed)
    end
  end

  defp due_for_review?(decomposition, now) do
    decomposition["status"] in ["completed", "reviewed"] and
      decomposition["due_at"] != nil and
      case DateTime.from_iso8601(decomposition["due_at"]) do
        {:ok, due_at, _} -> DateTime.compare(due_at, now) in [:lt, :eq]
        _ -> false
      end
  end

  # Callbacks

  @impl true
  def init(opts) do
    # Ensure Logger is started (in case we're starting before app full initialization)
    case :application.start(:logger) do
      :ok -> :ok
      {:error, {:already_started, :logger}} -> :ok
    end

    Logger.info("Starting GTD NATS consumer")

    state = %{
      subscriptions: [],
      reconnect_attempt: 0,
      conn: nil,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    # credo:disable-for-next-line
    try do
      case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
        {:ok, conn} ->
          Connection.subscribe_to_status()
          Logger.info("Connected to NATS, subscribing to GTD topics")

          subscriptions =
            [
              "gtd.inbox.add",
              "gtd.task.create",
              "gtd.task.update",
              "gtd.task.complete",
              "gtd.task.command.defer",
              "gtd.task.command.delete",
              "gtd.task.decompose",
              "gtd.decomposition.approve",
              "gtd.decomposition.reject",
              "gtd.decomposition.review",
              "gtd.decomposition.request_review",
              "gtd.project.create",
              "gtd.project.update",
              "gtd.project.list",
              "gtd.log.create",
              "events.llm.response.parsed",
              "events.llm.chain.completed",
              "gtd.task.list",
              "gtd.task.get",
              "gtd.task.search",
              "gtd.decomposition.list_due",
              "claude.task.create",
              "claude.operation.success",
              "conv.request.gtd.>",
              "conv.mailbox.gtd",
              "conv.followup.>",
              "ops.deploy.>",
              "gossip.intent.proposed",
              "gossip.social.invite",
              "gossip.poll.broadcast",
              "gtd.whats_next",
              "synapse.army_general.poll.broadcast",
              "gtd.army.opinion.vote",
              "gtd.para.backfill",
              "gtd.para.cleanup",
              "gtd.review.weekly",
              "gtd.review.inbox_aging",
              "gtd.review.coherence"
            ]
            |> Enum.map(fn subject ->
              case Gnat.sub(conn, self(), subject) do
                {:ok, sub} ->
                  Logger.info("GTD consumer subscribed to #{subject}")
                  sub

                {:error, reason} ->
                  Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
                  nil
              end
            end)
            |> Enum.filter(&(not is_nil(&1)))

          deployment_status = Application.get_env(:bot_army_gtd, :deployment_status, "deployed")
          Registry.register("gtd", @subjects, @version, deployment_status)
          Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
          {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

        {:error, _reason} ->
          Logger.warning("NATS connection not ready, will retry")
          Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
          {:noreply, state}
      end
    rescue
      e ->
        Logger.error("Error connecting to NATS: #{inspect(e)}")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    catch
      :exit, reason ->
        Logger.error("Exit while connecting to NATS: #{inspect(reason)}")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.army.opinion.vote", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span(
      "gtd.army.opinion.vote",
      Map.get(msg, :headers, []),
      fn ->
        resp = ArmyOpinionVote.build_reply(:gtd, body)
        reply_traced(state.conn, reply_to, Jason.encode!(resp))
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "gtd.task.list", reply_to: reply_to, body: body} = msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span("gtd.task.list", Map.get(msg, :headers, []), fn ->
      task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

      {tenant_id, limit, offset, filters} = parse_task_list_params(body)
      TaskHandler.expire_active_tasks(tenant_id, nil)

      response = fetch_task_list_response(task_store, tenant_id, filters, limit, offset)
      reply_traced(state.conn, reply_to, response)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "gtd.task.get", reply_to: reply_to, body: body} = msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span("gtd.task.get", Map.get(msg, :headers, []), fn ->
      task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

      {tenant_id, task_id} =
        case Jason.decode(body) do
          {:ok, params} ->
            tid = extract_tenant_id_from_params(params)
            {tid, params["task_id"]}

          _ ->
            {Application.get_env(:bot_army_gtd, :default_tenant_id, "default"), nil}
        end

      response = build_task_get_response(task_store, tenant_id, task_id)
      reply_traced(state.conn, reply_to, response)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.task.search", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span("gtd.task.search", Map.get(msg, :headers, []), fn ->
      task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

      {tenant_id, query, filters, pagination} = parse_search_params(body)

      response =
        case task_store.search(tenant_id, query, filters, pagination) do
          {:ok, {tasks, total_count}} ->
            Reply.ok(%{
              "tasks" => tasks,
              "total_count" => total_count,
              "limit" => Map.get(pagination, "limit"),
              "offset" => Map.get(pagination, "offset"),
              "query" => query
            })

          {:error, reason} ->
            Reply.error(inspect(reason), :search_failed)
        end

      reply_traced(state.conn, reply_to, response)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.decomposition.list_due", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span(
      "gtd.decomposition.list_due",
      Map.get(msg, :headers, []),
      fn ->
        decomposition_store =
          Application.get_env(:bot_army_gtd, :decomposition_store, BotArmyGtd.DecompositionStore)

        tenant_id = extract_decomposition_tenant_id(body)
        response = fetch_due_decompositions_response(decomposition_store, tenant_id)
        reply_traced(state.conn, reply_to, response)
      end
    )

    {:noreply, state}
  end

  # --- GTD Voting V1 request/reply handlers ---

  @impl true
  def handle_info({:msg, %{topic: "gtd.whats_next", reply_to: reply_to, body: body} = msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span("gtd.whats_next", Map.get(msg, :headers, []), fn ->
      params = decode_body(body)

      response =
        case WhatsNextHandler.handle_request(params) do
          {:ok, result} -> Reply.ok(result)
          {:error, reason} -> Reply.error(inspect(reason), :whats_next_failed)
        end

      reply_traced(state.conn, reply_to, response)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.para.backfill", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span(
      "gtd.para.backfill",
      Map.get(msg, :headers, []),
      fn ->
        params = decode_body(body)

        tenant_id =
          params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

        skip_slugs = params["skip_slugs"] || []
        apply? = params["apply"] == true

        response =
          case BotArmyGtd.ParaExporter.backfill_projects(tenant_id,
                 skip_slugs: skip_slugs,
                 apply: apply?
               ) do
            {:ok, result} -> Reply.ok(result)
            {:error, reason} -> Reply.error(inspect(reason), :backfill_failed)
          end

        reply_traced(state.conn, reply_to, response)
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.para.cleanup", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span(
      "gtd.para.cleanup",
      Map.get(msg, :headers, []),
      fn ->
        params = decode_body(body)

        tenant_id =
          params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

        existing_archive_slugs = params["existing_archive_slugs"] || []
        apply? = params["apply"] == true

        response =
          case BotArmyGtd.ParaExporter.sweep_stale(tenant_id,
                 existing_archive_slugs: existing_archive_slugs,
                 apply: apply?
               ) do
            {:ok, result} -> Reply.ok(result)
            {:error, reason} -> Reply.error(inspect(reason), :cleanup_failed)
          end

        reply_traced(state.conn, reply_to, response)
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.review.weekly", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span(
      "gtd.review.weekly",
      Map.get(msg, :headers, []),
      fn ->
        params = decode_body(body)

        tenant_id =
          params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

        window_days = params["window_days"]
        opts = if window_days, do: [window_days: window_days], else: []

        response =
          case BotArmyGtd.ReviewEngine.weekly_review(tenant_id, opts) do
            {:ok, result} -> Reply.ok(result)
            {:error, reason} -> Reply.error(inspect(reason), :review_failed)
          end

        reply_traced(state.conn, reply_to, response)
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.review.inbox_aging", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span(
      "gtd.review.inbox_aging",
      Map.get(msg, :headers, []),
      fn ->
        params = decode_body(body)

        tenant_id =
          params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

        threshold = params["threshold_hours"]
        opts = if threshold, do: [threshold_hours: threshold], else: []

        response =
          case BotArmyGtd.ReviewEngine.inbox_aging(tenant_id, opts) do
            {:ok, result} ->
              Reply.ok(result)

            {:error, reason} ->
              Reply.error(inspect(reason), :inbox_aging_failed)
          end

        reply_traced(state.conn, reply_to, response)
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "gtd.review.coherence", reply_to: reply_to, body: body} = msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    Tracing.with_consumer_span(
      "gtd.review.coherence",
      Map.get(msg, :headers, []),
      fn ->
        params = decode_body(body)

        tenant_id =
          params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

        response =
          case BotArmyGtd.ReviewEngine.project_coherence(tenant_id) do
            {:ok, result} ->
              Reply.ok(result)

            {:error, reason} ->
              Reply.error(inspect(reason), :coherence_failed)
          end

        reply_traced(state.conn, reply_to, response)
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "ops.deploy.complete", body: body} = msg}, state) do
    Tracing.with_consumer_span(
      "ops.deploy.complete",
      Map.get(msg, :headers, []),
      fn ->
        case Decoder.decode(body) do
          {:ok, decoded} ->
            handle_deploy_complete(decoded)

          {:error, reason} ->
            Logger.warning("Failed to decode deploy complete message: #{inspect(reason)}")
        end
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    topic = msg.topic
    reply_to = Map.get(msg, :reply_to)

    Tracing.with_consumer_span(topic, Map.get(msg, :headers, []), fn ->
      dispatch_message(msg, topic, reply_to, state)
    end)

    {:noreply, state}
  end

  defp dispatch_message(msg, "gtd.task.create", reply_to, state)
       when is_binary(reply_to) and reply_to != "" do
    handle_task_create_request(msg, reply_to, state)
  end

  defp dispatch_message(msg, "gtd.task.update", reply_to, state)
       when is_binary(reply_to) and reply_to != "" do
    handle_task_update_request(msg, reply_to, state)
  end

  defp dispatch_message(msg, "gtd.task.complete", reply_to, state)
       when is_binary(reply_to) and reply_to != "" do
    handle_task_complete_request(msg, reply_to, state)
  end

  defp dispatch_message(msg, "gtd.project.create", reply_to, state)
       when is_binary(reply_to) and reply_to != "" do
    handle_project_create_request(msg, reply_to, state)
  end

  defp dispatch_message(msg, "gtd.project.update", reply_to, state)
       when is_binary(reply_to) and reply_to != "" do
    handle_project_update_request(msg, reply_to, state)
  end

  defp dispatch_message(msg, "gtd.project.list", reply_to, state)
       when is_binary(reply_to) and reply_to != "" do
    handle_project_list_request(msg, reply_to, state)
  end

  defp dispatch_message(msg, "gossip.intent.proposed", _reply_to, _state) do
    handle_gossip_message(msg, :intent_proposed)
  end

  defp dispatch_message(msg, "gossip.social.invite", _reply_to, _state) do
    handle_gossip_message(msg, :social_invite)
  end

  defp dispatch_message(msg, "gossip.poll.broadcast", _reply_to, _state) do
    handle_gossip_message(msg, :poll_broadcast)
  end

  defp dispatch_message(msg, "synapse.army_general.poll.broadcast", _reply_to, _state) do
    handle_gtd_poll_broadcast(msg)
  end

  defp dispatch_message(msg, topic, _reply_to, _state) do
    Logger.debug("Received NATS message on subject: #{topic}")
    handle_fallback_message(msg, topic)
  end

  defp handle_fallback_message(msg, topic) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{topic}: #{inspect(reason)}")
    end
  end

  defp handle_gossip_message(msg, type) do
    case Jason.decode(msg.body) do
      {:ok, decoded} ->
        case type do
          :intent_proposed -> BotArmyGtd.Gossip.handle_intent_proposed(decoded)
          :social_invite -> BotArmyGtd.Gossip.handle_social_invite(decoded)
          :poll_broadcast -> BotArmyGtd.Gossip.handle_poll_broadcast(decoded)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode gossip message from #{msg.topic}: #{inspect(reason)}")
    end
  end

  defp handle_gtd_poll_broadcast(msg) do
    case Jason.decode(msg.body) do
      {:ok, decoded} ->
        BotArmyGtd.Gossip.handle_gtd_poll_broadcast(decoded)

      {:error, reason} ->
        Logger.warning("Failed to decode GTD poll broadcast: #{inspect(reason)}")
    end
  end

  defp handle_task_create_request(msg, reply_to, state) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        process_task_create(decoded_message, reply_to, state)

      {:error, reason} ->
        Logger.warning("Failed to decode task create message: #{inspect(reason)}")
        error_response = Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp process_task_create(decoded_message, reply_to, state) do
    case TaskHandler.handle_create(decoded_message) do
      {:ok, task} ->
        response = Reply.ok(%{"task_id" => task["id"], "task" => task})
        reply_traced(state.conn, reply_to, response)

      {:error, reason} ->
        error_response = Reply.error(inspect(reason), :create_failed)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_task_update_request(msg, reply_to, state) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case TaskHandler.handle_update(decoded_message) do
          :ok ->
            response = Reply.ok(%{})
            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = Reply.error(inspect(reason), :update_failed)
            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode task update message: #{inspect(reason)}")
        error_response = Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_task_complete_request(msg, reply_to, state) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case TaskHandler.handle_complete(decoded_message) do
          :ok ->
            response = Reply.ok(%{})
            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = Reply.error(inspect(reason), :complete_failed)
            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode task complete message: #{inspect(reason)}")
        error_response = Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_project_create_request(msg, reply_to, state) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case ProjectHandler.handle_create(decoded_message) do
          {:ok, project} ->
            response =
              Reply.ok(%{"project_id" => project["id"], "project" => project})

            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = Reply.error(inspect(reason), :create_failed)
            reply_traced(state.conn, reply_to, error_response)

          other ->
            Logger.warning("Unexpected return value from handle_create: #{inspect(other)}")

            error_response =
              Reply.error(
                "Internal error: unexpected handler response",
                :internal_error
              )

            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode project create message: #{inspect(reason)}")
        error_response = Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_project_update_request(msg, reply_to, state) do
    case Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case ProjectHandler.handle_update(decoded_message) do
          {:ok, project} ->
            response =
              Reply.ok(%{"project_id" => project["id"], "project" => project})

            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = Reply.error(inspect(reason), :update_failed)
            reply_traced(state.conn, reply_to, error_response)

          other ->
            Logger.warning("Unexpected return value from handle_update: #{inspect(other)}")

            error_response =
              Reply.error(
                "Internal error: unexpected handler response",
                :internal_error
              )

            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode project update message: #{inspect(reason)}")
        error_response = Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_project_list_request(msg, reply_to, state) do
    tenant_id =
      case Decoder.decode(msg.body) do
        {:ok, decoded} ->
          case Map.get(decoded, "payload") do
            %{"tenant_id" => tid} when is_binary(tid) and tid != "" ->
              tid

            _ ->
              Map.get(
                decoded,
                "tenant_id",
                Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
              )
          end

        _ ->
          Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
      end

    project_store = Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)

    response =
      case project_store.list(tenant_id) do
        {:ok, projects} ->
          Reply.ok(%{"projects" => projects})

        {:error, reason} ->
          Reply.error(inspect(reason), :list_failed)
      end

    reply_traced(state.conn, reply_to, response)
  end

  # Deploy event integration

  defp handle_deploy_complete(message) do
    payload = message["payload"] || %{}
    bot = payload["bot"]
    status = payload["status"]
    error = payload["error"]

    if is_nil(bot) do
      Logger.warning("[DeployConsumer] ops.deploy.complete missing bot name")
      :ok
    else
      case status do
        "success" ->
          Logger.info("[DeployConsumer] Deploy succeeded for #{bot}, completing waiting task")
          complete_waiting_task(bot)
          schedule_post_deploy_verification(bot, payload["version"])

        "failure" ->
          Logger.info("[DeployConsumer] Deploy failed for #{bot}, creating incident task")
          create_incident_task(bot, error)

        _ ->
          Logger.warning("[DeployConsumer] Unknown deploy status: #{status}")
      end
    end
  end

  defp complete_task_by_id(task_id, task_store, tenant_id, bot) do
    case task_store.complete(tenant_id, task_id) do
      {:ok, _} ->
        Logger.info("[DeployConsumer] Completed waiting task #{task_id} for #{bot}")

      {:error, reason} ->
        Logger.error("[DeployConsumer] Failed to complete task #{task_id}: #{inspect(reason)}")
    end
  end

  defp complete_waiting_task(bot) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    tenant_id = Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    filters = %{"status" => "active"}

    case task_store.list(tenant_id, filters) do
      {:ok, tasks} ->
        match =
          Enum.find(tasks, fn t ->
            t["title"] == bot and t["context"] == "waiting"
          end)

        if match do
          complete_task_by_id(match["id"], task_store, tenant_id, bot)
        else
          Logger.debug("[DeployConsumer] No waiting task found for #{bot}")
        end

      {:error, reason} ->
        Logger.error("[DeployConsumer] Failed to list tasks: #{inspect(reason)}")
    end
  end

  defp create_incident_task(bot, error) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

    description =
      if error do
        "Deploy of #{bot} failed with error:\n\n#{error}\n\nCheck Jenkins logs at http://localhost:18080/job/Ergon%20Automation%20Labs/job/ergon-#{bot}/"
      else
        "Deploy of #{bot} failed. Check Jenkins logs at http://localhost:18080/job/Ergon%20Automation%20Labs/job/ergon-#{bot}/"
      end

    payload = %{
      "title" => "[INCIDENT] #{bot} deploy failed",
      "description" => description,
      "context" => "next",
      "priority" => "high",
      "labels" => ["incident", "deploy", bot],
      "status" => "active"
    }

    case task_store.create(payload) do
      {:ok, _} ->
        Logger.info("[DeployConsumer] Created incident task for #{bot} deploy failure")

      {:error, reason} ->
        Logger.error("[DeployConsumer] Failed to create incident task: #{inspect(reason)}")
    end
  end

  defp schedule_post_deploy_verification(bot, version) when is_binary(bot) do
    # Give the bot 5 seconds to register with the registry after restart
    Process.send_after(self(), {:verify_deploy, bot, version || "unknown"}, 5_000)
  end

  defp schedule_post_deploy_verification(_, _), do: :ok

  defp parse_search_params(body) do
    case Jason.decode(body) do
      {:ok, params} ->
        tid = extract_tenant_id_or_default(params["tenant_id"])
        q = params["query"] || ""
        f = Map.get(params, "filters", %{})

        p = %{
          "limit" => min(params["limit"] || 50, 500),
          "offset" => params["offset"] || 0,
          "sort" => params["sort"],
          "order" => params["order"]
        }

        {tid, q, f, p}

      _ ->
        {Application.get_env(:bot_army_gtd, :default_tenant_id, "default"), "", %{},
         %{"limit" => 50, "offset" => 0}}
    end
  end

  defp extract_tenant_id_or_default(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    tenant_id
  end

  defp extract_tenant_id_or_default(_) do
    Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
  end

  defp reply_traced(conn, reply_to, body) do
    if conn do
      headers = Tracing.inject_trace_context([])
      Gnat.pub(conn, reply_to, body, headers: headers)
    end
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, params} -> params
      {:error, _} -> %{}
    end
  end

  defp decode_body(body) when is_map(body), do: body
  defp decode_body(_), do: %{}

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will attempt to reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Connected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to NATS")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:verify_deploy, bot, version}, state) do
    Task.start(fn ->
      case BotArmyGtd.ReviewEngine.verify_deploy(bot, version) do
        {:ok, %{"healthy" => true}} ->
          Logger.info("[PostDeploy] ✅ #{bot} v#{version} verified healthy")

        {:ok, result} ->
          Logger.warning("[PostDeploy] ⚠️ #{bot} v#{version} verification: #{inspect(result)}")

        _ ->
          Logger.warning(
            "[PostDeploy] #{bot} v#{version} verification returned unexpected result"
          )
      end
    end)

    {:noreply, state}
  end

  defp build_task_get_response(_task_store, _tenant_id, nil) do
    Reply.error("task_id required", :missing_field)
  end

  defp build_task_get_response(task_store, tenant_id, task_id) do
    case task_store.get(tenant_id, task_id) do
      {:ok, task} ->
        Reply.ok(%{"task" => task})

      {:error, reason} ->
        Reply.error(inspect(reason), :not_found)
    end
  end

  defp extract_tenant_id_from_params(params) do
    case params["tenant_id"] do
      t when is_binary(t) and t != "" -> t
      _ -> Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
    end
  end

  @impl true
  def handle_info(:registry_heartbeat, state) do
    if state.subscriptions != [] do
      deployment_status = Application.get_env(:bot_army_gtd, :deployment_status, "deployed")
      Registry.register("gtd", @subjects, @version, deployment_status)
      BotArmyGtd.Gossip.maybe_vote_on_heartbeat()
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end
end
