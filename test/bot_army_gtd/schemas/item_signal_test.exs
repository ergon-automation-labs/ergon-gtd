defmodule BotArmyGtd.Schemas.ItemSignalTest do
  use ExUnit.Case
  @moduletag :schemas

  alias BotArmyGtd.Schemas.ItemSignal

  @valid_attrs %{
    "item_type" => "task",
    "item_id" => Ecto.UUID.generate(),
    "signal_type" => "poll_vote",
    "signal_value" => 2.0,
    "source" => "poll_round:abc",
    "tenant_id" => Ecto.UUID.generate()
  }

  test "valid changeset with required fields" do
    changeset = ItemSignal.changeset(%ItemSignal{}, @valid_attrs)
    assert changeset.valid?
  end

  test "invalid without required fields" do
    changeset = ItemSignal.changeset(%ItemSignal{}, %{})
    refute changeset.valid?
  end

  test "item_type must be task, project, or goal" do
    invalid = ItemSignal.changeset(%ItemSignal{}, Map.put(@valid_attrs, "item_type", "widget"))
    refute invalid.valid?
  end
end
