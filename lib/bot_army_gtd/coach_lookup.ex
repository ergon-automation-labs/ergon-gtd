defmodule BotArmyGtd.CoachLookup do
  @moduledoc """
  The one look-up the coach is allowed: her notes, or her own files.

  The two places her words are not in the GTD database are the internal-docs corpus (the project
  docs and repository notes) and PARA (her own folders). Both are too big to put in front of a
  model on every question, so the model may ask for one search instead, and this module runs it.

  ## Why these two subjects, and not the bridge façades

  `internal_docs.search.hybrid` is the internal-docs bot's own request/reply: it answers a
  `%{"query" => ..., "limit" => ...}` in one hop with the results already assembled. The
  `bridge.internal_docs.query` façade in front of it is job-shaped — it accepts the request and
  hands back a `job_id` — which would turn one look-up into a second asynchronous wait on top of
  the first. The coach's budget is not big enough for two of those, and this code runs inside a
  bot, not a surface: the direct subject is the honest client of the docs bot's own contract.

  `para.fs.search` is the PARA bot's facade over her files. It walks the filesystem and answers
  when it is done — twelve seconds is normal for it, because the corpus is a directory tree and
  not an index. So it gets the longer of the two timeouts, and a timeout is reported as one.

  ## Failure is a fact, not a silence

  Every failure here returns `{:error, reason}` and the caller says "that could not be read just
  now" in the facts the model is given. An empty result is *not* a failure: "nothing matched" is
  a fact, and it is exactly the fact the model needs so it can say it found nothing rather than
  inventing something.
  """

  require Logger

  @docs_subject "internal_docs.search.hybrid"
  @docs_limit 3
  @docs_timeout_ms 20_000

  @para_subject "para.fs.search"
  @para_limit 8
  @para_timeout_ms 25_000

  @excerpt_chars 240

  @doc """
  Run one look-up. `source` is `"docs"` or `"para"` — the two words the model may write.

  Returns `{:ok, text}` with the findings already in words, or `{:error, reason}` when the
  search itself could not be run.
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(source, query, opts \\ [])

  def run("docs", query, opts) when is_binary(query), do: docs(query, opts)
  def run("para", query, opts) when is_binary(query), do: para(query, opts)
  def run(source, _query, _opts), do: {:error, {:unknown_lookup_source, source}}

  defp docs(query, opts) do
    case request(
           @docs_subject,
           %{"query" => query, "limit" => @docs_limit},
           @docs_timeout_ms,
           opts
         ) do
      {:ok, %{"results" => results}} when is_list(results) -> {:ok, docs_text(results)}
      {:ok, other} -> {:error, {:unexpected_lookup_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp para(query, opts) do
    case request(@para_subject, %{"query" => query}, @para_timeout_ms, opts) do
      {:ok, %{"matches" => matches}} when is_list(matches) -> {:ok, para_text(matches)}
      {:ok, other} -> {:error, {:unexpected_lookup_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- putting it in words ----------------------------------------------------

  defp docs_text([]), do: "Nothing in the project docs matched those words."

  defp docs_text(results) do
    results
    |> Enum.take(@docs_limit)
    |> Enum.map_join("\n", &docs_line/1)
  end

  defp docs_line(result) do
    metadata = result["metadata"] || %{}
    heading = result["heading"] || metadata["name"] || metadata["path"] || "a document"
    where = if is_binary(metadata["path"]), do: " (#{metadata["path"]})", else: ""

    "#{heading}#{where}: #{excerpt(result["content"], @excerpt_chars)}"
  end

  defp para_text([]), do: "Nothing in her PARA files matched those words."

  defp para_text(matches) do
    matches
    |> Enum.take(@para_limit)
    |> Enum.map_join("\n", &para_line/1)
  end

  defp para_line(match) do
    # The path is what makes a PARA hit useful: it says *where* in her own folders this lives,
    # which is what she needs to go and look. The excerpt is only there when there is one.
    path = match["path"] || "a file"

    case excerpt(match["excerpt"], @excerpt_chars) do
      "" -> path
      excerpt -> "#{path}: #{excerpt}"
    end
  end

  # -- the hop ----------------------------------------------------------------

  defp request(subject, payload, default_timeout_ms, opts) do
    publisher(opts).request(subject, payload, timeout_ms: timeout(default_timeout_ms, opts))
  rescue
    e -> {:error, {:lookup_raised, Exception.message(e)}}
  catch
    # A Gnat call to a connection that is not there *exits*; rescuing alone would miss it.
    kind, reason -> {:error, {:lookup_crashed, kind, reason}}
  end

  # The caller may hand over what is left of its own deadline, and that always wins when it is
  # the smaller of the two. The look-up never gets more than its own default.
  defp timeout(default_timeout_ms, opts) do
    case Keyword.get(opts, :timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> min(ms, default_timeout_ms)
      _other -> default_timeout_ms
    end
  end

  # Injectable so a test can drive both look-ups with no broker. A caller may pass `:publisher`
  # itself; otherwise it is the fleet one.
  defp publisher(opts) do
    Keyword.get(opts, :publisher) ||
      Application.get_env(
        :bot_army_gtd,
        :coach_chat_publisher,
        BotArmyLibraryRuntime.NATS.Publisher
      )
  end

  defp excerpt(value, limit) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp excerpt(_value, _limit), do: ""
end
