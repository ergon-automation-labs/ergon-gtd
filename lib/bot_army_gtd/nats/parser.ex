defmodule BotArmyGtd.NATS.Parser do
  @moduledoc """
  Utility for parsing NATS request payloads into domain-compatible parameters.
  """

  def parse_task_list_params(body) do
    case Jason.decode(body) do
      {:ok, params} ->
        tid = extract_tenant_id(params)
        lim = min(params["limit"] || 100, 500)
        off = min(params["offset"] || 0, 10000)
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

  def parse_search_params(body) do
    case Jason.decode(body) do
      {:ok, params} ->
        tid = extract_tenant_id_or_default(params["tenant_id"])
        q = params["query"] || ""
        f = Map.get(params, "filters", %{})
        p = %{
          "limit" => min(params["limit"] || 50, 500),
          "offset" => min(params["offset"] || 0, 10000),
          "sort" => params["sort"],
          "order" => params["order"]
        }
        {tid, q, f, p}

      _ ->
        {Application.get_env(:bot_army_gtd, :default_tenant_id, "default"), "", %{},
         %{"limit" => 50, "offset" => 0}}
    end
  end

  def extract_tenant_id(params) do
    case params["tenant_id"] do
      t when is_binary(t) and t != "" -> t
      _ -> Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
    end
  end

  defp extract_tenant_id_or_default(tenant_id) when is_binary(tenant_id) and tenant_id != "" do
    tenant_id
  end
  defp extract_tenant_id_or_default(_) do
    Application.get_env(:bot_army_gtd, :default_tenant_id, "default")
  end

  def decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, params} -> params
      {:error, _} -> %{}
    end
  end
  def decode_body(body) when is_map(body), do: body
  def decode_body(_), do: %{}
end
