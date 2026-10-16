defmodule BotArmyGtd.CoachChatTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.CoachChat

  defp project(id, name, extra \\ %{}) do
    Map.merge(%{"id" => id, "name" => name, "status" => "active"}, extra)
  end

  defp task(title, project_id, extra \\ %{}) do
    Map.merge(%{"title" => title, "project_id" => project_id, "status" => "active"}, extra)
  end

  describe "system_prompt/0" do
    test "refuses invention, writes and decisions on her behalf" do
      prompt = CoachChat.system_prompt()

      assert prompt =~ "invent one"
      assert prompt =~ "You only read"
      assert prompt =~ "the change has to be made by her"
      assert prompt =~ "Do not decide what she should work on next"
      assert prompt =~ ~s(LOOKUP docs "the words to search for")
      assert prompt =~ ~s(LOOKUP para "the words to search for")
      assert prompt =~ "You get one look-up"
    end
  end

  describe "facts/1" do
    test "names the projects, groups the tasks under them, and counts the inbox" do
      context = %{
        today: "2026-10-16",
        projects: {:ok, [project("p1", "Fleet Manageability")]},
        tasks: {:ok, [task("Renew the domain", "p1"), task("Loose thing", nil)]},
        inbox: {:ok, [%{"title" => "idea", "created_at" => "2026-09-21T10:00:00Z"}]}
      }

      facts = CoachChat.facts(context)

      assert facts =~ "TODAY\n2026-10-16"
      assert facts =~ "HER PROJECTS — 1 active"
      assert facts =~ "Fleet Manageability"
      assert facts =~ "Renew the domain"
      assert facts =~ "no project"
      assert facts =~ "Loose thing"
      assert facts =~ "HER INBOX — 1 captured"
      assert facts =~ "idea"
      assert facts =~ "2026-09-21"
    end

    test "a store that did not answer is said out loud, never left out" do
      facts =
        %{today: "2026-10-16", projects: :unreadable, tasks: :unreadable, inbox: :unreadable}
        |> CoachChat.facts()

      assert facts =~ "HER PROJECTS — could not be read just now"
      assert facts =~ "HER OPEN TASKS — could not be read just now"
      assert facts =~ "HER INBOX — could not be read just now"
      assert facts =~ "Do not say what she has or has not got"
    end

    test "empty reads are facts, and read differently from a failed one" do
      facts =
        CoachChat.facts(%{
          today: "2026-10-16",
          projects: {:ok, []},
          tasks: {:ok, []},
          inbox: {:ok, []}
        })

      assert facts =~ "she has none active"
      assert facts =~ "she has none."
      assert facts =~ "nothing waiting to be decided"
      refute facts =~ "could not be read"
    end

    test "without project names the tasks are listed rather than grouped under an invented heading" do
      facts =
        CoachChat.facts(%{
          today: "2026-10-16",
          projects: :unreadable,
          tasks: {:ok, [task("Renew the domain", "p1")]},
          inbox: {:ok, []}
        })

      assert facts =~ "- Renew the domain"
      refute facts =~ "a project not listed above"
    end

    test "a long list is capped and says so, so a cap never reads as the whole list" do
      tasks = for n <- 1..50, do: task("task #{n}", "p1")

      facts =
        CoachChat.facts(%{
          today: "2026-10-16",
          projects: {:ok, [project("p1", "Big")]},
          tasks: {:ok, tasks},
          inbox: {:ok, []}
        })

      assert facts =~ "50 open"
      assert facts =~ "showing 40 of them"
      refute facts =~ "task 45"
    end

    test "the oldest inbox item is the one named first" do
      inbox = [
        %{"title" => "newer", "created_at" => "2026-10-10T00:00:00Z"},
        %{"title" => "older", "created_at" => "2026-01-01T00:00:00Z"}
      ]

      facts =
        CoachChat.facts(%{
          today: "2026-10-16",
          projects: {:ok, []},
          tasks: {:ok, []},
          inbox: {:ok, inbox}
        })

      assert :binary.match(facts, "older") |> elem(0) < :binary.match(facts, "newer") |> elem(0)
    end
  end

  describe "prompt/2 and followup/4" do
    test "her words travel untouched, and the facts travel with them" do
      context = %{today: "2026-10-16", projects: {:ok, []}, tasks: {:ok, []}, inbox: {:ok, []}}
      prompt = CoachChat.prompt("where did I put the tax thing?", context)

      assert prompt =~ ~s(Her question: where did I put the tax thing?)
      assert prompt =~ "TODAY"
      assert prompt =~ "▲"
    end

    test "the follow-up quotes the model's own line back and rules out a second look-up" do
      context = %{today: "2026-10-16", projects: {:ok, []}, tasks: {:ok, []}, inbox: {:ok, []}}

      followup =
        CoachChat.followup(
          "where is the tax thing?",
          context,
          ~s(LOOKUP para "tax"),
          "- personal_os/taxes/2025.md: the 2025 return"
        )

      assert followup =~ ~s(LOOKUP para "tax")
      assert followup =~ "the 2025 return"
      assert followup =~ "You may not look\nanything else up"
    end
  end

  describe "lookup/1" do
    test "reads the two directives the model may write" do
      assert CoachChat.lookup(~s(LOOKUP docs "cable row")) == {:lookup, "docs", "cable row"}
      assert CoachChat.lookup(~s(  LOOKUP para  "tax 2025"  )) == {:lookup, "para", "tax 2025"}
      assert CoachChat.lookup("LOOKUP PARA \"tax\"") == {:lookup, "para", "tax"}
    end

    test "prose is an answer, even when a directive is appended to it" do
      assert CoachChat.lookup("You have three projects open.\n") == :none
      assert CoachChat.lookup("You have three projects open.\nLOOKUP docs \"x\"") == :none
    end

    test "anything else is not a directive" do
      assert CoachChat.lookup(nil) == :none
      assert CoachChat.lookup("") == :none
      assert CoachChat.lookup("look up the docs please") == :none
      assert CoachChat.lookup(~s(LOOKUP memory "x")) == :none
      assert CoachChat.lookup(~s(LOOKUP docs x)) == :none
    end
  end

  describe "clean/1" do
    test "a stray directive never reaches her page" do
      assert CoachChat.clean("You have three projects open.\nLOOKUP docs \"x\"") ==
               "You have three projects open."
    end

    test "an answer with no directive is left exactly as it was" do
      assert CoachChat.clean("  You have three projects open.  ") ==
               "You have three projects open."
    end

    test "an answer that was only a directive cleans to nothing, so the caller can refuse it" do
      assert CoachChat.clean(~s(LOOKUP para "tax")) == ""
    end

    test "a non-binary is handed back rather than crashing" do
      assert CoachChat.clean(nil) == nil
    end
  end
end
