defmodule BotArmyGtd.Decomposition.Registry do
  @moduledoc """
  Handles the discovery of relevant bot capabilities from the Bot Army registry
  to provide context for task decomposition.
  """

  require Logger

  @doc """
  Fetch a snapshot of capabilities relevant to the given query.
  """
  def get_relevant_capabilities(query_text) do
    query_down = String.downcase(query_text)

    case GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        request_body = Jason.encode!(%{"include_subjects" => true})

        case Gnat.request(conn, "bot_army.registry.bots.list", request_body,
               receive_timeout: 3_000
             ) do
          {:ok, response} ->
            response.body
            |> Jason.decode()
            |> format_registry_snapshot(query_down)

          {:error, reason} ->
            Logger.debug("Registry snapshot unavailable: #{inspect(reason)}")
            ""
        end

      {:error, reason} ->
        Logger.debug("NATS connection unavailable for registry snapshot: #{inspect(reason)}")
        ""
    end
  end

  defp format_registry_snapshot({:ok, %{"ok" => true, "data" => data}}, query_text) do
    bots =
      case data do
        %{"bots" => list} when is_list(list) -> list
        list when is_list(list) -> list
        _ -> []
      end

    bots
    |> Enum.filter(&registry_bot_relevant?(&1, query_text))
    |> Enum.take(8)
    |> Enum.map(&format_registry_bot/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_registry_snapshot(_decode_result, _query_text), do: ""

  defp registry_bot_relevant?(bot, query_text) do
    text_blob =
      [Map.get(bot, "name", ""), Map.get(bot, "bot_name", ""), Map.get(bot, "description", "")]
      |> Kernel.++(extract_subject_names(bot))
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(String.split(query_text, ~r/\s+/, trim: true), fn token ->
      String.length(token) > 2 and String.contains?(text_blob, token)
    end)
  end

  defp extract_subject_names(bot) do
    case Map.get(bot, "subjects") do
      subjects when is_list(subjects) ->
        Enum.map(subjects, fn
          %{"subject" => subject} -> subject
          subject when is_binary(subject) -> subject
          _ -> ""
        end)

      _ ->
        []
    end
  end

  defp format_registry_bot(bot) do
    name = Map.get(bot, "name") || Map.get(bot, "bot_name") || "unknown_bot"

    subjects =
      bot
      |> extract_subject_names()
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(6)
      |> Enum.join(", ")

    if subjects == "" do
      ""
    else
      "- #{name}: #{subjects}"
    end
  end
end
