defmodule BotArmyGtd.Schemas.PollVoteTest do
  use ExUnit.Case
  @moduletag :schemas

  alias BotArmyGtd.Schemas.PollVote

  @valid_attrs %{
    "poll_id" => Ecto.UUID.generate(),
    "voter_type" => "bot",
    "voter_id" => "gtd_bot",
    "item_type" => "task",
    "item_id" => Ecto.UUID.generate(),
    "votes" => 2
  }

  test "valid changeset with required fields" do
    changeset = PollVote.changeset(%PollVote{}, @valid_attrs)
    assert changeset.valid?
  end

  test "invalid without required fields" do
    changeset = PollVote.changeset(%PollVote{}, %{})
    refute changeset.valid?
  end

  test "voter_type must be bot or human" do
    valid = PollVote.changeset(%PollVote{}, Map.put(@valid_attrs, "voter_type", "human"))
    assert valid.valid?

    invalid = PollVote.changeset(%PollVote{}, Map.put(@valid_attrs, "voter_type", "alien"))
    refute invalid.valid?
  end

  test "item_type must be task, project, or goal" do
    for t <- ["task", "project", "goal"] do
      changeset = PollVote.changeset(%PollVote{}, Map.put(@valid_attrs, "item_type", t))
      assert changeset.valid?
    end

    invalid = PollVote.changeset(%PollVote{}, Map.put(@valid_attrs, "item_type", "widget"))
    refute invalid.valid?
  end

  test "votes must be positive" do
    invalid = PollVote.changeset(%PollVote{}, Map.put(@valid_attrs, "votes", 0))
    refute invalid.valid?

    valid = PollVote.changeset(%PollVote{}, Map.put(@valid_attrs, "votes", 3))
    assert valid.valid?
  end
end
