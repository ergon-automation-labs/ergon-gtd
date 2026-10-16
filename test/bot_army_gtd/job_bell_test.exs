defmodule BotArmyGtd.JobBellTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.JobBell

  # The registry is started by the application (it is the local half of the llm bot's bell), so
  # these tests use the real one and clean up after themselves.

  test "ringing wakes every process waiting on that job" do
    JobBell.watch("job-a")
    JobBell.ring("job-a")
    assert_receive {:job_bell, "job-a"}
  after
    JobBell.unwatch("job-a")
  end

  test "a waiter stops hearing once it stops waiting" do
    JobBell.watch("job-b")
    JobBell.unwatch("job-b")
    JobBell.ring("job-b")
    refute_receive {:job_bell, "job-b"}, 20
  end

  test "a ring for a job nobody is waiting on is harmless" do
    assert JobBell.ring("job-nobody") == :ok
  end

  test "a ring for one job does not wake the waiter of another" do
    JobBell.watch("job-c")
    JobBell.ring("job-d")
    refute_receive {:job_bell, "job-c"}, 20
  after
    JobBell.unwatch("job-c")
  end

  test "every waiter on the same job hears the same ring" do
    test_pid = self()

    waiters =
      for _ <- 1..3 do
        spawn_link(fn ->
          JobBell.watch("job-many")
          send(test_pid, {:waiting, self()})

          receive do
            {:job_bell, "job-many"} -> send(test_pid, :rung)
          after
            1_000 -> send(test_pid, :never_rung)
          end
        end)
      end

    Enum.each(waiters, fn _ -> assert_receive {:waiting, _pid}, 500 end)
    JobBell.ring("job-many")
    Enum.each(waiters, fn _ -> assert_receive :rung, 500 end)
  end
end
