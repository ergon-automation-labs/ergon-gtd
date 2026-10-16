defmodule BotArmyGtd.HouseholdDayTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyGtd.HouseholdDay

  setup do
    previous = Application.get_env(:bot_army_gtd, :household_today)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bot_army_gtd, :household_today, previous),
        else: Application.delete_env(:bot_army_gtd, :household_today)
    end)

    :ok
  end

  test "today/0 answers a Date, and takes the pinned day when one is set" do
    Application.put_env(:bot_army_gtd, :household_today, fn -> ~D[2026-02-03] end)

    assert HouseholdDay.today() == ~D[2026-02-03]
  end

  test "today/0 is the host's own day, not a day derived from an offset" do
    Application.delete_env(:bot_army_gtd, :household_today)

    {date, _time} = :calendar.local_time()

    assert HouseholdDay.today() == Date.from_erl!(date)
  end

  test "offset_hours/0 reads a whole number of hours from the host" do
    assert is_integer(HouseholdDay.offset_hours())
    assert HouseholdDay.offset_hours() == div(HouseholdDay.offset_seconds(), 3_600)
  end

  test "local_date/1 shifts a stored UTC wall time into the house's day" do
    offset = HouseholdDay.offset_seconds()

    # The instant the house's midnight happened, in UTC wall time, is the day the house
    # began minus the offset: a timestamp written 23:30 local on the 15th is 05:30 UTC on
    # the 16th when the house is six hours behind, and it must be counted on the 15th.
    midnight_local_15 = NaiveDateTime.new!(~D[2026-06-15], ~T[00:00:00])
    just_before = NaiveDateTime.add(midnight_local_15, -60, :second)
    utc_before = NaiveDateTime.add(just_before, -offset, :second)

    assert HouseholdDay.local_date(utc_before) == ~D[2026-06-14]

    just_after = NaiveDateTime.add(midnight_local_15, 60, :second)
    utc_after = NaiveDateTime.add(just_after, -offset, :second)

    assert HouseholdDay.local_date(utc_after) == ~D[2026-06-15]
  end

  test "local_date/1 accepts a DateTime too, because checkouts are written with one" do
    datetime = DateTime.from_naive!(~N[2026-06-15 12:00:00], "Etc/UTC")
    naive = ~N[2026-06-15 12:00:00]

    assert HouseholdDay.local_date(datetime) == HouseholdDay.local_date(naive)
  end
end
