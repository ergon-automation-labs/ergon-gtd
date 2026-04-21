defmodule BotArmyGtd.ReviewSchedulerTest do
  @moduledoc """
  Tests for ReviewScheduler - periodic discovery of decompositions due for review.
  """

  use ExUnit.Case, async: true
  @moduletag :scheduler

  alias BotArmyGtd.ReviewScheduler

  setup do
    # Configure tests to use the mock
    Application.put_env(:bot_army_gtd, :decomposition_store, BotArmyGtd.DecompositionStoreMock)
    :ok
  end

  describe "get_due/0" do
    test "returns empty list when no decompositions" do
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, []}
      end)

      {:ok, due} = ReviewScheduler.get_due()
      assert due == []
    end

    test "filters decompositions with status != completed" do
      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -1, :day)

      decompositions = [
        %{
          "id" => "decomp1",
          "status" => "in_progress",
          "due_at" => DateTime.to_iso8601(yesterday)
        },
        %{
          "id" => "decomp2",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(yesterday)
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, due} = ReviewScheduler.get_due()
      assert length(due) == 1
      assert Enum.at(due, 0)["id"] == "decomp2"
    end

    test "filters decompositions with due_at > now" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 1, :day)
      past = DateTime.add(now, -1, :day)

      decompositions = [
        %{
          "id" => "future",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(future)
        },
        %{
          "id" => "past",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(past)
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, due} = ReviewScheduler.get_due()
      assert length(due) == 1
      assert Enum.at(due, 0)["id"] == "past"
    end

    test "sorts by due_at ascending" do
      now = DateTime.utc_now()
      one_day_ago = DateTime.add(now, -1, :day)
      two_days_ago = DateTime.add(now, -2, :day)

      decompositions = [
        %{
          "id" => "decomp1",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(one_day_ago)
        },
        %{
          "id" => "decomp2",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(two_days_ago)
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, due} = ReviewScheduler.get_due()
      assert length(due) == 2
      # Two days ago should come before one day ago
      assert Enum.at(due, 0)["id"] == "decomp2"
      assert Enum.at(due, 1)["id"] == "decomp1"
    end

    test "returns error when store fails" do
      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:error, :database_error}
      end)

      assert {:error, :database_error} = ReviewScheduler.get_due()
    end
  end

  describe "get_upcoming/1" do
    test "returns decompositions due in next N days" do
      now = DateTime.utc_now()
      tomorrow = DateTime.add(now, 1, :day)
      three_days = DateTime.add(now, 3, :day)
      ten_days = DateTime.add(now, 10, :day)

      decompositions = [
        %{
          "id" => "tomorrow",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(tomorrow)
        },
        %{
          "id" => "three_days",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(three_days)
        },
        %{
          "id" => "ten_days",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(ten_days)
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, upcoming} = ReviewScheduler.get_upcoming(7)
      assert length(upcoming) == 2
      ids = Enum.map(upcoming, & &1["id"])
      assert "tomorrow" in ids
      assert "three_days" in ids
      assert "ten_days" not in ids
    end

    test "excludes decompositions with status != completed" do
      now = DateTime.utc_now()
      tomorrow = DateTime.add(now, 1, :day)

      decompositions = [
        %{
          "id" => "in_progress",
          "status" => "in_progress",
          "due_at" => DateTime.to_iso8601(tomorrow)
        },
        %{
          "id" => "completed",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(tomorrow)
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, upcoming} = ReviewScheduler.get_upcoming(7)
      assert length(upcoming) == 1
      assert Enum.at(upcoming, 0)["id"] == "completed"
    end

    test "sorts by due_at ascending" do
      now = DateTime.utc_now()
      day1 = DateTime.add(now, 1, :day)
      day3 = DateTime.add(now, 3, :day)

      decompositions = [
        %{
          "id" => "day3",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(day3)
        },
        %{
          "id" => "day1",
          "status" => "completed",
          "due_at" => DateTime.to_iso8601(day1)
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, upcoming} = ReviewScheduler.get_upcoming(7)
      assert Enum.at(upcoming, 0)["id"] == "day1"
      assert Enum.at(upcoming, 1)["id"] == "day3"
    end
  end

  describe "datetime parsing" do
    test "handles nil due_at" do
      decompositions = [
        %{
          "id" => "decomp1",
          "status" => "completed",
          "due_at" => nil
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, due} = ReviewScheduler.get_due()
      assert due == []
    end

    test "parses ISO8601 datetime strings" do
      now = DateTime.utc_now()
      yesterday = DateTime.add(now, -1, :day)
      iso_string = DateTime.to_iso8601(yesterday)

      decompositions = [
        %{
          "id" => "decomp1",
          "status" => "completed",
          "due_at" => iso_string
        }
      ]

      default_tenant_id = BotArmyCore.Tenant.default_tenant_id()

      Mox.expect(BotArmyGtd.DecompositionStoreMock, :list, fn ^default_tenant_id ->
        {:ok, decompositions}
      end)

      {:ok, due} = ReviewScheduler.get_due()
      assert length(due) == 1
    end
  end
end
