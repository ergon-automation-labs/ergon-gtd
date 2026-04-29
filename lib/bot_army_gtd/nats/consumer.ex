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
    %{subject: "gtd.task.complete", type: :subscribe, description: "Task completion events"},
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
    }
  ]

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, debug: [:trace])
  end

  @doc """
  Route decoded message to appropriate handler based on event type.

  This is the core dispatch logic that routes incoming messages to handlers.
  Handles both GTD-internal events and cross-bot events from LLM bot.
  """
  def route_message(message) do
    event = message["event"]

    # Conversation events use prefix matching (not case-exact event types)
    cond do
      is_binary(event) and String.starts_with?(event, "conv.request.gtd.") ->
        BotArmyGtd.Handlers.ConversationHandler.handle_request(message)

      is_binary(event) and String.starts_with?(event, "conv.followup.") ->
        BotArmyGtd.Handlers.ConversationHandler.handle_request(message)

      event == "conv.mailbox.gtd" ->
        BotArmyGtd.Handlers.ConversationHandler.handle_mailbox(message)

      true ->
        case event do
          "gtd.inbox.add" ->
            BotArmyGtd.Handlers.InboxHandler.handle_add(message)

          "gtd.task.create" ->
            BotArmyGtd.Handlers.TaskHandler.handle_create(message)

          "gtd.task.update" ->
            BotArmyGtd.Handlers.TaskHandler.handle_update(message)

          "gtd.task.complete" ->
            BotArmyGtd.Handlers.TaskHandler.handle_complete(message)

          "gtd.task.command.defer" ->
            BotArmyGtd.Handlers.TaskHandler.handle_defer(message)

          "gtd.task.command.delete" ->
            BotArmyGtd.Handlers.TaskHandler.handle_delete(message)

          "gtd.task.decompose" ->
            BotArmyGtd.Handlers.DecompositionHandler.handle_decompose(message)

          "gtd.decomposition.approve" ->
            BotArmyGtd.Handlers.DecompositionHandler.handle_approve(message)

          "gtd.decomposition.reject" ->
            BotArmyGtd.Handlers.DecompositionHandler.handle_reject(message)

          "gtd.decomposition.review" ->
            BotArmyGtd.Handlers.DecompositionHandler.handle_review(message)

          "gtd.decomposition.request_review" ->
            BotArmyGtd.Handlers.DecompositionHandler.handle_request_review(message)

          "gtd.project.create" ->
            BotArmyGtd.Handlers.ProjectHandler.handle_create(message)

          "gtd.project.update" ->
            BotArmyGtd.Handlers.ProjectHandler.handle_update(message)

          "gtd.log.create" ->
            BotArmyGtd.Handlers.LogEntryHandler.handle_create(message)

          "llm.response.parsed" ->
            case get_in(message, ["payload", "enrichment_source"]) do
              "log_enrichment" ->
                BotArmyGtd.Handlers.LogEnrichmentHandler.handle_enriched(message)

              _ ->
                BotArmyGtd.Handlers.InboxParsingHandler.handle_parse(message)
            end

          "llm.chain.completed" ->
            BotArmyGtd.Handlers.DecompositionHandler.handle_chain_completed(message)

          "claude.task.create" ->
            BotArmyGtd.Handlers.ClaudeHandler.handle_task_create(message)

          "claude.operation.success" ->
            BotArmyGtd.Handlers.ClaudeHandler.handle_operation_success(message)

          _ ->
            Logger.debug("Unknown event type: #{event}")
        end
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
    try do
      case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
        {:ok, conn} ->
          BotArmyRuntime.NATS.Connection.subscribe_to_status()
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
              "ops.deploy.>"
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

          BotArmyRuntime.Registry.register("gtd", @subjects, @version)
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
  def handle_info({:msg, %{topic: "gtd.task.list", reply_to: reply_to, body: body} = msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    BotArmyRuntime.Tracing.with_consumer_span("gtd.task.list", Map.get(msg, :headers, []), fn ->
      task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

      {tenant_id, limit, offset, filters} =
        case Jason.decode(body) do
          {:ok, params} ->
            tid =
              case params["tenant_id"] do
                t when is_binary(t) and t != "" -> t
                _ -> Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
              end

            lim = min(params["limit"] || 100, 500)
            off = params["offset"] || 0
            filters = %{"status" => params["status"], "labels" => params["labels"]}
            {tid, lim, off, filters}

          _ ->
            {Application.get_env(:bot_army_gtd, :default_tenant_id, "default"), 100, 0, %{}}
        end

      BotArmyGtd.Handlers.TaskHandler.expire_active_tasks(tenant_id, nil)

      response =
        case task_store.list_prioritized(tenant_id, filters) do
          {:ok, all_tasks} ->
            page = all_tasks |> Enum.drop(offset) |> Enum.take(limit)

            BotArmyRuntime.NATS.Reply.ok(%{
              "tasks" => page,
              "total_count" => length(all_tasks),
              "limit" => limit,
              "offset" => offset
            })

          {:error, reason} ->
            BotArmyRuntime.NATS.Reply.error(inspect(reason), :list_failed)
        end

      reply_traced(state.conn, reply_to, response)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "gtd.task.get", reply_to: reply_to, body: body} = msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    BotArmyRuntime.Tracing.with_consumer_span("gtd.task.get", Map.get(msg, :headers, []), fn ->
      task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

      {tenant_id, task_id} =
        case Jason.decode(body) do
          {:ok, params} ->
            tid =
              case params["tenant_id"] do
                t when is_binary(t) and t != "" -> t
                _ -> Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
              end

            {tid, params["task_id"]}

          _ ->
            {Application.get_env(:bot_army_gtd, :default_tenant_id, "default"), nil}
        end

      response =
        if task_id do
          case task_store.get(tenant_id, task_id) do
            {:ok, task} ->
              BotArmyRuntime.NATS.Reply.ok(%{"task" => task})

            {:error, reason} ->
              BotArmyRuntime.NATS.Reply.error(inspect(reason), :not_found)
          end
        else
          BotArmyRuntime.NATS.Reply.error("task_id required", :missing_field)
        end

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
    BotArmyRuntime.Tracing.with_consumer_span("gtd.task.search", Map.get(msg, :headers, []), fn ->
      task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

      {tenant_id, query, filters, pagination} =
        case Jason.decode(body) do
          {:ok, params} ->
            tid =
              case params["tenant_id"] do
                t when is_binary(t) and t != "" -> t
                _ -> Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
              end

            q = params["query"] || ""
            f = Map.get(params, "filters", %{})

            p = %{
              "limit" => min(params["limit"] || 50, 500),
              "offset" => params["offset"] || 0
            }

            {tid, q, f, p}

          _ ->
            {Application.get_env(:bot_army_gtd, :default_tenant_id, "default"), "", %{},
             %{"limit" => 50, "offset" => 0}}
        end

      response =
        case task_store.search(tenant_id, query, filters, pagination) do
          {:ok, {tasks, total_count}} ->
            BotArmyRuntime.NATS.Reply.ok(%{
              "tasks" => tasks,
              "total_count" => total_count,
              "limit" => Map.get(pagination, "limit"),
              "offset" => Map.get(pagination, "offset"),
              "query" => query
            })

          {:error, reason} ->
            BotArmyRuntime.NATS.Reply.error(inspect(reason), :search_failed)
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
    BotArmyRuntime.Tracing.with_consumer_span(
      "gtd.decomposition.list_due",
      Map.get(msg, :headers, []),
      fn ->
        decomposition_store =
          Application.get_env(
            :bot_army_gtd,
            :decomposition_store,
            BotArmyGtd.DecompositionStore
          )

        tenant_id =
          case Jason.decode(body) do
            {:ok, %{"tenant_id" => tid}} when is_binary(tid) and tid != "" -> tid
            _ -> Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
          end

        now = DateTime.utc_now()

        response =
          case decomposition_store.list(tenant_id) do
            {:ok, decompositions} ->
              due =
                decompositions
                |> Enum.filter(fn d ->
                  d["status"] in ["completed", "reviewed"] and d["due_at"] != nil
                end)
                |> Enum.filter(fn d ->
                  case DateTime.from_iso8601(d["due_at"]) do
                    {:ok, due_at, _} -> DateTime.compare(due_at, now) in [:lt, :eq]
                    _ -> false
                  end
                end)
                |> Enum.sort_by(fn d -> d["due_at"] end)

              BotArmyRuntime.NATS.Reply.ok(%{"decompositions" => due})

            {:error, reason} ->
              BotArmyRuntime.NATS.Reply.error(inspect(reason), :list_failed)
          end

        reply_traced(state.conn, reply_to, response)
      end
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "ops.deploy.complete", body: body} = msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(
      "ops.deploy.complete",
      Map.get(msg, :headers, []),
      fn ->
        case BotArmyCore.NATS.Decoder.decode(body) do
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

    BotArmyRuntime.Tracing.with_consumer_span(topic, Map.get(msg, :headers, []), fn ->
      case topic do
        "gtd.task.create" when is_binary(reply_to) and reply_to != "" ->
          handle_task_create_request(msg, reply_to, state)

        "gtd.task.update" when is_binary(reply_to) and reply_to != "" ->
          handle_task_update_request(msg, reply_to, state)

        "gtd.project.create" when is_binary(reply_to) and reply_to != "" ->
          handle_project_create_request(msg, reply_to, state)

        "gtd.project.update" when is_binary(reply_to) and reply_to != "" ->
          handle_project_update_request(msg, reply_to, state)

        "gtd.project.list" when is_binary(reply_to) and reply_to != "" ->
          handle_project_list_request(msg, reply_to, state)

        _ ->
          Logger.debug("Received NATS message on subject: #{topic}")

          case BotArmyCore.NATS.Decoder.decode(msg.body) do
            {:ok, decoded_message} ->
              route_message(decoded_message)

            {:error, reason} ->
              Logger.warning("Failed to decode message from #{topic}: #{inspect(reason)}")
          end
      end
    end)

    {:noreply, state}
  end

  defp handle_task_create_request(msg, reply_to, state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case BotArmyGtd.Handlers.TaskHandler.handle_create(decoded_message) do
          {:ok, task} ->
            response = BotArmyRuntime.NATS.Reply.ok(%{"task_id" => task["id"], "task" => task})
            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = BotArmyRuntime.NATS.Reply.error(inspect(reason), :create_failed)
            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode task create message: #{inspect(reason)}")
        error_response = BotArmyRuntime.NATS.Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_task_update_request(msg, reply_to, state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case BotArmyGtd.Handlers.TaskHandler.handle_update(decoded_message) do
          :ok ->
            response = BotArmyRuntime.NATS.Reply.ok(%{})
            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = BotArmyRuntime.NATS.Reply.error(inspect(reason), :update_failed)
            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode task update message: #{inspect(reason)}")
        error_response = BotArmyRuntime.NATS.Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_project_create_request(msg, reply_to, state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case BotArmyGtd.Handlers.ProjectHandler.handle_create(decoded_message) do
          {:ok, project} ->
            response =
              BotArmyRuntime.NATS.Reply.ok(%{"project_id" => project["id"], "project" => project})

            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = BotArmyRuntime.NATS.Reply.error(inspect(reason), :create_failed)
            reply_traced(state.conn, reply_to, error_response)

          other ->
            Logger.warning("Unexpected return value from handle_create: #{inspect(other)}")

            error_response =
              BotArmyRuntime.NATS.Reply.error(
                "Internal error: unexpected handler response",
                :internal_error
              )

            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode project create message: #{inspect(reason)}")
        error_response = BotArmyRuntime.NATS.Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_project_update_request(msg, reply_to, state) do
    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        case BotArmyGtd.Handlers.ProjectHandler.handle_update(decoded_message) do
          {:ok, project} ->
            response =
              BotArmyRuntime.NATS.Reply.ok(%{"project_id" => project["id"], "project" => project})

            reply_traced(state.conn, reply_to, response)

          {:error, reason} ->
            error_response = BotArmyRuntime.NATS.Reply.error(inspect(reason), :update_failed)
            reply_traced(state.conn, reply_to, error_response)

          other ->
            Logger.warning("Unexpected return value from handle_update: #{inspect(other)}")

            error_response =
              BotArmyRuntime.NATS.Reply.error(
                "Internal error: unexpected handler response",
                :internal_error
              )

            reply_traced(state.conn, reply_to, error_response)
        end

      {:error, reason} ->
        Logger.warning("Failed to decode project update message: #{inspect(reason)}")
        error_response = BotArmyRuntime.NATS.Reply.error("Invalid message format", :decode_error)
        reply_traced(state.conn, reply_to, error_response)
    end
  end

  defp handle_project_list_request(msg, reply_to, state) do
    tenant_id =
      case BotArmyCore.NATS.Decoder.decode(msg.body) do
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
          BotArmyRuntime.NATS.Reply.ok(%{"projects" => projects})

        {:error, reason} ->
          BotArmyRuntime.NATS.Reply.error(inspect(reason), :list_failed)
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

        "failure" ->
          Logger.info("[DeployConsumer] Deploy failed for #{bot}, creating incident task")
          create_incident_task(bot, error)

        _ ->
          Logger.warning("[DeployConsumer] Unknown deploy status: #{status}")
      end
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
          task_id = match["id"]

          case task_store.complete(tenant_id, task_id) do
            {:ok, _} ->
              Logger.info("[DeployConsumer] Completed waiting task #{task_id} for #{bot}")

            {:error, reason} ->
              Logger.error(
                "[DeployConsumer] Failed to complete task #{task_id}: #{inspect(reason)}"
              )
          end
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

  defp reply_traced(conn, reply_to, body) do
    if conn do
      headers = BotArmyRuntime.Tracing.inject_trace_context([])
      Gnat.pub(conn, reply_to, body, headers: headers)
    end
  end

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
  def handle_info(:registry_heartbeat, state) do
    if length(state.subscriptions) > 0 do
      BotArmyRuntime.Registry.register("gtd", @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

end
