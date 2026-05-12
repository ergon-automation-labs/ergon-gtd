defmodule BotArmyGtd.Handlers.ConversationHandler do
  @moduledoc """
  Handles conversation-based requests to the GTD bot from other bots.

  Processes incoming `conv.request.gtd.*` messages by dispatching
  to intent-specific handlers and routing responses back through
  the Conversation Manager.

  ## Supported Intents

    - `task.query` — Query tasks by status/project
    - `task.count` — Count tasks matching filters
    - `context.summary` — Return active task/project/inbox summary
    - `inbox.add` — Create an inbox item
    - `gossip.*` — Casual icebreaker messages
  """

  require Logger

  @doc """
  Handle an incoming conversation request directed at the GTD bot.
  """
  def handle_request(envelope) do
    payload = envelope["payload"] || envelope
    conversation_id = payload["conversation_id"]
    from_bot = payload["from_bot"]
    message_type = payload["message_type"]
    body = payload["body"] || %{}

    case message_type do
      "query" ->
        handle_query(body, conversation_id, from_bot)

      "command" ->
        handle_command(body, conversation_id, from_bot)

      "gossip" ->
        handle_gossip(body, conversation_id, from_bot)

      _ ->
        Logger.debug("[ConvHandler] Unknown message_type from #{from_bot}: #{message_type}")
        :ok
    end
  end

  @doc """
  Handle an incoming mailbox message directed at the GTD bot.
  """
  def handle_mailbox(envelope) do
    payload = envelope["payload"] || envelope
    conversation_id = payload["conversation_id"]
    from_bot = payload["from_bot"]
    message_type = payload["message_type"]
    body = payload["body"] || %{}

    Logger.info("[ConvHandler] Mailbox from #{from_bot}: #{message_type} (#{conversation_id})")

    case message_type do
      "gossip" ->
        handle_gossip_mailbox(body, from_bot)

      "info" ->
        Logger.debug("[ConvHandler] Info from #{from_bot}: #{inspect(body)}")

      _ ->
        :ok
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Query Handlers
  # ───────────────────────────────────────────────────────────────────────────

  defp handle_query(body, conversation_id, from_bot) do
    intent = body["intent"]

    result =
      case intent do
        "task.query" -> query_tasks(body["params"] || %{})
        "task.count" -> count_tasks(body["params"] || %{})
        "context.summary" -> build_context_summary(body["params"] || %{})
        _ -> {:error, :unknown_intent}
      end

    case result do
      {:ok, data} ->
        BotArmyRuntime.NATS.Conversation.Manager.reply(
          conversation_id,
          "gtd",
          data,
          message_type: "result",
          from_bot: from_bot,
          conversation_complete: true
        )

      {:error, reason} ->
        BotArmyRuntime.NATS.Conversation.Manager.reply(
          conversation_id,
          "gtd",
          %{error: inspect(reason)},
          message_type: "error",
          from_bot: from_bot,
          conversation_complete: true
        )
    end
  end

  defp handle_command(body, conversation_id, from_bot) do
    intent = body["intent"]

    Logger.debug("[ConversationHandler] Command from #{from_bot}: #{intent}")

    result =
      case intent do
        "inbox.add" -> add_inbox_item(body["params"] || %{})
        _ -> {:error, :unknown_intent}
      end

    case result do
      {:ok, data} ->
        BotArmyRuntime.NATS.Conversation.Manager.reply(
          conversation_id,
          "gtd",
          data,
          message_type: "result",
          conversation_complete: true
        )

      {:error, reason} ->
        BotArmyRuntime.NATS.Conversation.Manager.reply(
          conversation_id,
          "gtd",
          %{error: inspect(reason)},
          message_type: "error",
          conversation_complete: true
        )
    end
  end

  defp handle_gossip(body, conversation_id, from_bot) do
    Logger.info("[ConvHandler] Gossip from #{from_bot}: #{inspect(body["message"])}")

    BotArmyRuntime.NATS.Conversation.Manager.reply(
      conversation_id,
      "gtd",
      %{response: "Thanks for checking in! All good here."},
      message_type: "result",
      conversation_complete: true
    )
  end

  defp handle_gossip_mailbox(body, from_bot) do
    Logger.info("[ConvHandler] Mailbox gossip from #{from_bot}: #{inspect(body["message"])}")
    :ok
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Intent Implementations
  # ───────────────────────────────────────────────────────────────────────────

  defp query_tasks(params) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

    tenant_id =
      params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    filters = %{
      "status" => params["status"],
      "labels" => params["labels"],
      "project_id" => params["project_id"]
    }

    case task_store.list_prioritized(tenant_id, filters) do
      {:ok, tasks} ->
        limit = min(params["limit"] || 20, 100)
        {:ok, %{"tasks" => Enum.take(tasks, limit), "count" => length(tasks)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp count_tasks(params) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

    tenant_id =
      params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    case task_store.list_prioritized(tenant_id, %{}) do
      {:ok, tasks} ->
        total = length(tasks)
        active = Enum.count(tasks, &(&1["status"] in ["active", "inbox"]))
        completed = Enum.count(tasks, &(&1["status"] == "completed"))

        {:ok, %{"total" => total, "active" => active, "completed" => completed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_context_summary(params) do
    tenant_id =
      params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)
    project_store = Application.get_env(:bot_army_gtd, :project_store, BotArmyGtd.ProjectStore)

    with {:ok, tasks} <- task_store.list_prioritized(tenant_id, %{}),
         {:ok, projects} <- project_store.list(tenant_id) do
      inbox_count = Enum.count(tasks, &(&1["status"] == "inbox"))
      active_count = Enum.count(tasks, &(&1["status"] == "active"))

      {:ok,
       %{
         "inbox_count" => inbox_count,
         "active_task_count" => active_count,
         "project_count" => length(projects),
         "total_task_count" => length(tasks)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_inbox_item(params) do
    task_store = Application.get_env(:bot_army_gtd, :task_store, BotArmyGtd.TaskStore)

    tenant_id =
      params["tenant_id"] || Application.get_env(:bot_army_gtd, :default_tenant_id, "default")

    title = params["title"] || params["text"]

    if title do
      task_store.create(%{
        "tenant_id" => tenant_id,
        "user_id" => params["user_id"] || "bot",
        "title" => title,
        "description" => params["description"],
        "project_id" => params["project_id"] || "_inbox",
        "status" => "inbox",
        "priority" => params["priority"] || "normal",
        "source" => params["source"] || "conversation"
      })
    else
      {:error, "title or text required"}
    end
  end
end
