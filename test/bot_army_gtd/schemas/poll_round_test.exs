defmodule BotArmyGtd.Schemas.PollRoundTest do
  use ExUnit.Case
  @moduletag :schemas

  alias BotArmyGtd.Schemas.PollRound

  test "valid changeset with required fields" do
    changeset =
      PollRound.changeset(%PollRound{}, %{
        "name" => "Sprint priorities",
        "tenant_id" => Ecto.UUID.generate()
      })

    assert changeset.valid?
  end

  test "invalid without name" do
    changeset = PollRound.changeset(%PollRound{}, %{"tenant_id" => Ecto.UUID.generate()})
    refute changeset.valid?
  end

  test "invalid without tenant_id" do
    changeset = PollRound.changeset(%PollRound{}, %{"name" => "Test poll"})
    refute changeset.valid?
  end

  test "status must be open or closed" do
    valid =
      PollRound.changeset(%PollRound{}, %{
        "name" => "T",
        "tenant_id" => Ecto.UUID.generate(),
        "status" => "open"
      })

    assert valid.valid?

    invalid =
      PollRound.changeset(%PollRound{}, %{
        "name" => "T",
        "tenant_id" => Ecto.UUID.generate(),
        "status" => "draft"
      })

    refute invalid.valid?
  end

  test "vote_budget_per_bot must be positive" do
    invalid =
      PollRound.changeset(%PollRound{}, %{
        "name" => "T",
        "tenant_id" => Ecto.UUID.generate(),
        "vote_budget_per_bot" => 0
      })

    refute invalid.valid?

    valid =
      PollRound.changeset(%PollRound{}, %{
        "name" => "T",
        "tenant_id" => Ecto.UUID.generate(),
        "vote_budget_per_bot" => 5
      })

    assert valid.valid?
  end

  test "defaults" do
    changeset =
      PollRound.changeset(%PollRound{}, %{"name" => "T", "tenant_id" => Ecto.UUID.generate()})

    assert get_field(changeset, :status) == "open"
    assert get_field(changeset, :vote_budget_per_bot) == 3
  end

  defp get_field(changeset, field), do: Ecto.Changeset.get_field(changeset, field)
end
