defmodule BotArmyGtd.TaskIntakeGuard do
  @moduledoc false

  require Logger

  @placeholder_event_ids MapSet.new([
                           "parse-event-id",
                           "original-parse-request-id"
                         ])

  @explicit_test_ids MapSet.new([
                       "test-task-id",
                       "decompose-task-id"
                     ])

  @numbered_task_or_inbox ~r/^(task|inbox)-\d+$/

  def log_caller_metadata(action, message) when is_map(message) do
    meta = caller_metadata(message)

    Logger.info(
      "#{action} caller metadata: " <>
        "event_id=#{meta.event_id} " <>
        "source=#{meta.source} " <>
        "source_node=#{meta.source_node} " <>
        "triggered_by=#{meta.triggered_by} " <>
        "tenant_id=#{meta.tenant_id} " <>
        "user_id=#{meta.user_id}"
    )
  end

  def suspicious_test_data?(message, payload) when is_map(message) and is_map(payload) do
    # Only reject suspected test data when the config flag is enabled (test env)
    # This prevents legitimate data in dev/prod from being silently rejected
    if test_data_rejection_enabled?() do
      source_node = to_string(message["source_node"] || "")

      nonode_source? = source_node == "nonode@nohost"

      suspicious_event? = placeholder_id?(message["event_id"])
      suspicious_trigger? = placeholder_id?(payload["triggered_by_event_id"])

      suspicious_payload_identifier? =
        [payload["id"], payload["task_id"], payload["inbox_item_id"]]
        |> Enum.any?(&suspicious_identifier?/1)

      nonode_source? and
        (suspicious_event? or suspicious_trigger? or suspicious_payload_identifier?)
    else
      false
    end
  end

  def suspicious_test_data?(_, _), do: false

  def suspicious_outbound_created_event?(event) when is_map(event) do
    if test_data_rejection_enabled?() do
      event["event"] == "gtd.task.created" and
        to_string(event["source_node"] || "") == "nonode@nohost" and
        outbound_created_payload_suspicious?(event["payload"])
    else
      false
    end
  end

  def suspicious_outbound_created_event?(_), do: false

  def caller_metadata(message) when is_map(message) do
    %{
      event_id: value_or_unknown(message["event_id"]),
      source: value_or_unknown(message["source"]),
      source_node: value_or_unknown(message["source_node"]),
      triggered_by: value_or_unknown(message["triggered_by"]),
      tenant_id: value_or_unknown(message["tenant_id"]),
      user_id: value_or_unknown(message["user_id"])
    }
  end

  defp placeholder_id?(value) when is_binary(value),
    do: MapSet.member?(@placeholder_event_ids, value)

  defp placeholder_id?(_), do: false

  defp suspicious_identifier?(value) when is_binary(value) do
    MapSet.member?(@explicit_test_ids, value) or Regex.match?(@numbered_task_or_inbox, value)
  end

  defp suspicious_identifier?(_), do: false

  defp outbound_created_payload_suspicious?(payload) when is_map(payload) do
    task = payload["task"]

    suspicious_trigger? = placeholder_id?(payload["triggered_by_event_id"])

    suspicious_task_id? =
      case task do
        task_map when is_map(task_map) ->
          [task_map["id"], task_map["inbox_item_id"]]
          |> Enum.any?(&suspicious_identifier?/1)

        _ ->
          false
      end

    blank_task_shape? =
      case task do
        task_map when is_map(task_map) ->
          title = task_map["title"]
          id = task_map["id"]
          blank_title? = is_nil(title) or (is_binary(title) and String.trim(title) == "")
          missing_id? = is_nil(id) or (is_binary(id) and String.trim(id) == "")
          blank_title? or missing_id?

        _ ->
          true
      end

    suspicious_trigger? or suspicious_task_id? or blank_task_shape?
  end

  defp outbound_created_payload_suspicious?(_), do: true

  defp value_or_unknown(nil), do: "unknown"
  defp value_or_unknown(""), do: "unknown"
  defp value_or_unknown(value), do: to_string(value)

  defp test_data_rejection_enabled? do
    Application.get_env(:bot_army_gtd, :reject_test_data, false)
  end
end
