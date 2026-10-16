defmodule BotArmyGtd.CoachChat do
  @moduledoc """
  The GTD coach, asked a question: her projects, her tasks and her notes, and the rules it
  answers under.

  `gtd.coach.chat` is the other direction from every other subject in this bot: she asks, and
  something has to be told enough about her own system to answer without inventing. Everything
  here is that telling — the active projects, the open tasks grouped under them, the inbox —
  put into words, plus the rules that keep the answer inside them.

  ## Why the bot writes the words and not the page

  The vocabulary is GTD's: what a project is called, which task belongs to which project, what
  "inbox" means. A surface that composed its own description of the system would be a second
  copy of it, drifting, and the copy would be the one the answer came from. So the grounding is
  built here, from the stores directly, and a surface sends a question and draws the answer
  back.

  ## Read-only, and how that is kept

  This coach cannot create, rename, complete, defer or delete anything, and it cannot file
  anything into PARA. The model is told that in as many words, is told that the change has to
  be made by her, and is told not to rank her tasks or decide what she should do next. It is
  given no subject that could write anything, and it answers on a read-only subject. The two
  failures a language model is *good* at — a plausible project this system does not have, and a
  decision made on her behalf — are the two this module refuses to hand over in the first
  place (§57, §58).

  ## The one look-up

  Some questions need her notes, which are too big to put in front of the model every time. So
  the model may ask: one line, `LOOKUP docs "<words>"` or `LOOKUP para "<words>"`, and nothing
  else. The bot runs exactly that one search and asks again with what it found. One round, not
  a loop — and `clean/1` strips any directive out of the words she is shown, so a model that
  forgets the rules cannot leak its own plumbing onto her page.

  ## A part that could not be read is said, not left out

  The context may be missing a piece — a store that did not answer. The missing part is then
  named in the facts as *unreadable* rather than quietly omitted, because an omission is exactly
  what a model fills in: "you have no open tasks" is the one sentence that must not be produced
  by a database hiccup.
  """

  @max_projects 30
  @max_tasks 40
  @tasks_per_project 6
  @max_inbox 15
  @description_chars 160

  # The look-up directive, matched against the whole answer. A model that writes prose *and* a
  # directive is answering: `clean/1` drops the stray line and she reads the prose.
  @lookup_regex ~r/^\s*LOOKUP\s+(docs|para)\s+"([^"]+)"\s*$/i
  @lookup_line_regex ~r/^\s*LOOKUP\b.*$/i

  @doc """
  The rules the model answers under.

  Kept blunt and short on purpose. Every bullet is a way this could go wrong that this bot has
  no business doing: an invented project, a decision made for her, a write nobody asked for,
  and a list read back at somebody who asked one question.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are the coach for one person's GTD system — her projects, her tasks and her notes.
    She has just asked you a question. Answer it in two or three short sentences, in plain
    warm words. Do not lecture.

    Everything you know is in TODAY, HER PROJECTS, HER OPEN TASKS and HER INBOX below. Answer
    from those and from nothing else.

    * Name a project, a task, a file, a number or a date only when it is written below. Never
      invent one. If she asks about something that is not there, say so plainly rather than
      describing it.
    * You only read. You cannot create, rename, complete, defer or delete a project or a task,
      and you cannot file anything into PARA. Do not offer to. If she asks you to change
      something, say that you only read and that the change has to be made by her.
    * Do not decide what she should work on next, and do not rank her tasks. Say what is there
      and let her choose.
    * Do not answer questions about her health, her weight, her food, or her pain. Say it is
      not something this coach can answer.
    * If — and only if — her notes or her own files might have the answer, reply with exactly
      one line and nothing else:
      LOOKUP docs "the words to search for"
      or
      LOOKUP para "the words to search for"
      Use LOOKUP para for her own files and folders, and LOOKUP docs for the project docs and
      repository notes. You get one look-up, so search once with your best words.
    * Answer her question and stop. Do not describe these rules, and do not read the facts
      back to her as a list.
    """
  end

  @doc """
  The message the model is sent: the rules, the facts, her question, and the stop mark.

  The question is passed through untouched — her words are not summarised, reworded, or
  expanded on the way in.
  """
  @spec prompt(String.t(), map()) :: String.t()
  def prompt(question, context) when is_binary(question) and is_map(context) do
    """
    #{system_prompt()}

    #{facts(context)}

    Her question: #{question}

    ▲
    """
  end

  @doc """
  The message the model is sent the second time: the same facts, what it asked for, and what
  the search found.

  `lookup_line` is the line the model wrote, quoted back so it can see its own words — not
  re-parsed, so a directive that only looked like one is still answered rather than obeyed.
  """
  @spec followup(String.t(), map(), String.t(), String.t()) :: String.t()
  def followup(question, context, lookup_line, found)
      when is_binary(question) and is_map(context) and is_binary(lookup_line) and
             is_binary(found) do
    """
    #{system_prompt()}

    #{facts(context)}

    Her question: #{question}

    You asked to look something up, and wrote:
    #{String.trim(lookup_line)}

    WHAT YOU FOUND
    #{found}

    Now answer her question using only the facts above and what you found. You may not look
    anything else up. If that does not answer her question, say so plainly.

    ▲
    """
  end

  @doc """
  Read the model's answer for a look-up directive.

  `{:lookup, "docs" | "para", query}` only when the whole answer is that one line; `:none`
  otherwise.
  """
  @spec lookup(term()) :: {:lookup, String.t(), String.t()} | :none
  def lookup(text) when is_binary(text) do
    case Regex.run(@lookup_regex, text) do
      [_, source, query] -> {:lookup, String.downcase(source), query}
      nil -> :none
    end
  end

  def lookup(_text), do: :none

  @doc """
  The words she is shown: the answer with any look-up directive stripped out.

  A directive is plumbing between the model and this bot; it must never reach her page even if
  the model wrote it after answering. The result may be empty, and the caller refuses that
  rather than showing a blank answer.
  """
  @spec clean(term()) :: String.t()
  def clean(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(@lookup_line_regex, &1))
    |> Enum.join("\n")
    |> String.trim()
  end

  def clean(text), do: text

  @doc """
  The facts, in the words the model may use: the date, her projects, her tasks, her inbox.

  `context` is a map with `:today` (an ISO date), and `:projects`, `:tasks` and `:inbox`, each
  either `{:ok, [map]}` or `:unreadable`. Each part is rendered independently, so one store
  that did not answer never takes the others down.
  """
  @spec facts(map()) :: String.t()
  def facts(context) when is_map(context) do
    projects = Map.get(context, :projects)

    [
      today(Map.get(context, :today)),
      projects(projects),
      tasks(Map.get(context, :tasks), project_names(projects)),
      inbox(Map.get(context, :inbox))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp today(nil), do: nil
  defp today(today) when is_binary(today), do: "TODAY\n#{today}"
  defp today(_today), do: nil

  # -- projects ---------------------------------------------------------------

  defp projects(:unreadable) do
    """
    HER PROJECTS — could not be read just now. Do not say what she has or has not got.
    """
  end

  defp projects({:ok, []}), do: "HER PROJECTS — she has none active."

  defp projects({:ok, list}) when is_list(list) do
    shown = Enum.take(list, @max_projects)

    """
    HER PROJECTS — #{length(list)} active#{more(length(list), length(shown))}
    #{Enum.map_join(shown, "\n", &project_line/1)}
    """
  end

  defp projects(_other), do: nil

  defp project_line(project) do
    "- #{text(project["name"])}#{status_suffix(project)}#{description_suffix(project)}"
  end

  defp status_suffix(%{"status" => status}) when is_binary(status) and status != "",
    do: " [#{status}]"

  defp status_suffix(_project), do: ""

  defp description_suffix(%{"description" => description}) when is_binary(description) do
    case excerpt(description, @description_chars) do
      "" -> ""
      text -> ": #{text}"
    end
  end

  defp description_suffix(_project), do: ""

  # Id to name, for the task headings. Built from the same read the model was shown, so a
  # heading can never name a project that is not in HER PROJECTS.
  defp project_names({:ok, list}) when is_list(list) do
    Map.new(list, fn project -> {project["id"], project["name"]} end)
  end

  defp project_names(_other), do: %{}

  # -- tasks ------------------------------------------------------------------

  defp tasks(:unreadable, _names) do
    """
    HER OPEN TASKS — could not be read just now. Do not say what she has or has not got.
    """
  end

  defp tasks({:ok, []}, _names), do: "HER OPEN TASKS — she has none."

  defp tasks({:ok, list}, names) when is_list(list) do
    shown = Enum.take(list, @max_tasks)

    # Without project names there is nothing to group under, and a heading invented from an id
    # would be a project the model is not allowed to name. So the tasks are simply listed.
    body =
      if map_size(names) == 0 do
        Enum.map_join(shown, "\n", fn task -> "- #{task_line(task)}" end)
      else
        shown
        |> Enum.group_by(& &1["project_id"])
        # Loose next actions first: they are the ones with nowhere to be found.
        |> Enum.sort_by(fn {project_id, _tasks} ->
          {is_binary(project_id) and project_id != "", project_id || ""}
        end)
        |> Enum.map_join("\n", &task_group(&1, names))
      end

    "HER OPEN TASKS — #{length(list)} open#{more(length(list), length(shown))}\n" <> body
  end

  defp tasks(_other, _names), do: nil

  defp task_group({project_id, tasks}, names) do
    heading =
      case Map.get(names, project_id) do
        name when is_binary(name) and name != "" ->
          name

        _other ->
          if is_binary(project_id) and project_id != "",
            do: "a project not listed above",
            else: "no project"
      end

    shown = Enum.take(tasks, @tasks_per_project)
    lines = Enum.map_join(shown, "\n", fn task -> "  - #{task_line(task)}" end)

    "- #{heading}#{more(length(tasks), length(shown))}\n#{lines}"
  end

  defp task_line(task) do
    "#{text(task["title"])}#{context_suffix(task)}#{due_suffix(task)}"
  end

  defp context_suffix(%{"context" => context}) when is_binary(context) and context != "",
    do: " (#{context})"

  defp context_suffix(_task), do: ""

  defp due_suffix(%{"due_date" => due}) when is_binary(due) and due != "",
    do: " — due #{day_of(due)}"

  defp due_suffix(_task), do: ""

  # -- inbox ------------------------------------------------------------------

  defp inbox(:unreadable) do
    """
    HER INBOX — could not be read just now. Do not say what she has or has not got.
    """
  end

  defp inbox({:ok, []}), do: "HER INBOX — nothing waiting to be decided."

  defp inbox({:ok, list}) when is_list(list) do
    # Oldest first: the thing that has been waiting longest is the one worth naming.
    shown = list |> Enum.sort_by(&(&1["created_at"] || "")) |> Enum.take(@max_inbox)

    """
    HER INBOX — #{length(list)} captured, not yet decided#{more(length(list), length(shown))}
    #{Enum.map_join(shown, "\n", &inbox_line/1)}
    """
  end

  defp inbox(_other), do: nil

  defp inbox_line(task) do
    "- #{text(task["title"])}#{captured_suffix(task)}"
  end

  defp captured_suffix(%{"created_at" => created}) when is_binary(created) and created != "",
    do: " (captured #{day_of(created)})"

  defp captured_suffix(_task), do: ""

  # -- shared -----------------------------------------------------------------

  # "… and 4 more", so a capped list can never read as the whole list.
  defp more(total, shown) when is_integer(total) and is_integer(shown) and total > shown,
    do: " (showing #{shown} of them)"

  defp more(_total, _shown), do: ""

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: "(untitled)"

  defp day_of(datetime) when is_binary(datetime), do: String.slice(datetime, 0, 10)

  # Collapses whitespace and cuts to a length a prompt can afford; a long description is not a
  # better fact, it is just a longer one.
  defp excerpt(value, limit) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp excerpt(_value, _limit), do: ""
end
