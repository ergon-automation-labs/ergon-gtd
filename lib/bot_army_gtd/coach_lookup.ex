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
  when it is done — it is a directory tree, not an index, so a whole-tree content search answers
  in about a minute. So it gets the longer of the two timeouts, and a timeout is reported as one.

  ## A whole-tree search is all-or-nothing, so we ask one folder at a time

  `para.fs.search` answers only when it has finished walking, and a search that times out returns
  *nothing at all* — not the matches it had already found. Measured 2026-10-16 on the deployed bot:
  a whole-tree content search for a common word takes **63s**, of which `resources` alone is over
  45s; `projects` is 6s, and `areas`, `archive` and `inbox` are under a second each.

  So this module asks for one folder at a time through the `scope` parameter and stops at the
  first folder that answers with something. That turns the common question into a ~6s answer, and
  — more importantly — it means a search that runs out of time still returns the folders it *did*
  search instead of losing all of them to one slow directory. `resources` is asked last because it
  is the one folder big enough to eat the whole budget on its own, so a miss ends with four of her
  five folders searched and a sentence naming the fifth, rather than with nothing.

  ## Failure is a fact, not a silence

  Every failure here returns `{:error, reason}` and the caller says "that could not be read just
  now" in the facts the model is given. An empty result is *not* a failure: "nothing matched" is
  a fact, and it is exactly the fact the model needs so it can say it found nothing rather than
  inventing something. What is *also* not allowed is reporting a search that covered four folders
  out of five as if it had covered them all — see `para_text/1`.
  """

  require Logger

  @docs_subject "internal_docs.search.hybrid"
  @docs_limit 3
  @docs_timeout_ms 20_000

  @para_subject "para.fs.search"
  @para_limit 8
  @para_timeout_ms 25_000

  # Her PARA folders, in the order they are worth searching: live work first, then the areas she
  # keeps, then her inbox (where a thought she has just captured would land), then the archive, and
  # last the one folder that is big enough on its own to spend the whole budget — see the moduledoc.
  # A name that is not a folder simply matches nothing and costs one round trip to find that out.
  @para_scopes ["projects", "areas", "inbox", "archive", "resources"]

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
    budget_ms = timeout(@para_timeout_ms, opts)
    deadline = System.monotonic_time(:millisecond) + budget_ms
    nothing = %{matches: [], searched: [], failure: nil}

    # The first folder is offered the whole budget; every folder after it is offered only what the
    # clock says is left of it, which is what keeps the whole look-up inside `budget_ms`.
    case search_scopes(@para_scopes, query, deadline, opts, nothing, budget_ms) do
      {:error, _reason} = error -> error
      collected -> para_text(collected)
    end
  end

  defp search_scopes([], _query, _deadline, _opts, collected, _remaining), do: collected

  defp search_scopes([scope | rest], query, deadline, opts, collected, remaining) do
    cond do
      # One folder that answers is enough: asking the rest would only add seconds to an answer
      # that is already in hand.
      collected.matches != [] ->
        collected

      remaining <= 0 ->
        %{collected | failure: collected.failure || :timeout}

      true ->
        case request(@para_subject, %{"query" => query, "scope" => scope}, remaining, opts) do
          {:ok, %{"matches" => matches}} when is_list(matches) ->
            collected = %{
              collected
              | matches: collected.matches ++ matches,
                searched: collected.searched ++ [scope]
            }

            search_scopes(rest, query, deadline, opts, collected, left(deadline))

          {:ok, other} ->
            {:error, {:unexpected_lookup_reply, other}}

          {:error, reason} ->
            # A folder that could not be read is not the end of the look-up: the folders after it
            # still get their turn with what is left of the budget, and the ones before it are
            # already in hand. The failure is remembered so that a search where *every* folder
            # failed is an error the caller can say out loud, and never a silent empty answer.
            collected = %{collected | failure: collected.failure || reason}
            search_scopes(rest, query, deadline, opts, collected, left(deadline))
        end
    end
  end

  defp left(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

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

  defp para_text(%{matches: []} = collected) do
    cond do
      collected.searched == [] ->
        # Not one folder answered, so "nothing matched" would be a claim this module cannot make.
        {:error, collected.failure || :timeout}

      collected.failure == nil ->
        {:ok, "Nothing in her PARA files matched those words."}

      true ->
        # Some folders were searched and came back empty, and the budget ran out before the rest.
        # Saying only "nothing matched" here would be a lie of omission, and the folder that went
        # unsearched is the one she would have wanted looked in.
        missing = @para_scopes -- collected.searched

        {:ok,
         "Nothing matched those words in her #{names(collected.searched)} — the search ran out of " <>
           "time before it finished #{names(missing)}."}
    end
  end

  defp para_text(%{matches: matches}) do
    # Matches speak for themselves: the path is what makes a PARA hit useful, and the model can
    # follow it up with a second question if it wants the folder that was not reached.
    {:ok,
     matches
     |> Enum.take(@para_limit)
     |> Enum.map_join("\n", &para_line/1)}
  end

  defp names([]), do: "none"
  defp names([one]), do: one
  defp names(many), do: Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)

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
