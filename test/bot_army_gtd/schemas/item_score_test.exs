defmodule BotArmyGtd.Schemas.ItemScoreTest do
  use ExUnit.Case
  @moduletag :schemas

  alias BotArmyGtd.Schemas.ItemScore

  @valid_attrs %{
    "item_type" => "task",
    "item_id" => Ecto.UUID.generate(),
    "tenant_id" => Ecto.UUID.generate()
  }

  test "valid changeset with required fields" do
    changeset = ItemScore.changeset(%ItemScore{}, @valid_attrs)
    assert changeset.valid?
  end

  test "invalid without required fields" do
    changeset = ItemScore.changeset(%ItemScore{}, %{})
    refute changeset.valid?
  end

  test "defaults" do
    changeset = ItemScore.changeset(%ItemScore{}, @valid_attrs)
    assert Ecto.Changeset.get_field(changeset, :why_next_score) == 0.0
    assert Ecto.Changeset.get_field(changeset, :score_version) == "v1"
  end

  test "item_type must be task, project, or goal" do
    invalid = ItemScore.changeset(%ItemScore{}, Map.put(@valid_attrs, "item_type", "widget"))
    refute invalid.valid?
  end
end
