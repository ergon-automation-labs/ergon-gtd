defmodule BotArmyGtd.NATS.JobBellRouteTest do
  use ExUnit.Case
  @moduletag :nats

  alias BotArmyGtd.{JobBell, NATS.Consumer}

  # The llm bot's completion event carries a job id and nothing else. The consumer's only job on
  # it is to ring the local bell; the waiting process reads the words from the llm bot's store.
  # These tests prove that route without a broker: `route_message/1` is the same function the
  # GenServer calls for a decoded message.

  test "a completion event rings the bell for that job" do
    JobBell.watch("job-route-1")

    Consumer.route_message(%{
      "event" => "llm.job.completed",
      "payload" => %{"job_id" => "job-route-1"}
    })

    assert_receive {:job_bell, "job-route-1"}
  after
    JobBell.unwatch("job-route-1")
  end

  test "a completion event for another job does not ring mine" do
    JobBell.watch("job-route-2")

    Consumer.route_message(%{
      "event" => "llm.job.completed",
      "payload" => %{"job_id" => "job-route-other"}
    })

    refute_receive {:job_bell, "job-route-2"}, 20
  after
    JobBell.unwatch("job-route-2")
  end

  test "a completion event with no job id does not crash the consumer" do
    assert Consumer.route_message(%{"event" => "llm.job.completed", "payload" => %{}}) == :ok
    assert Consumer.route_message(%{"event" => "llm.job.completed"}) == :ok
  end

  test "both the bell and the coach are on the leader's subscription list" do
    served = Consumer.served_subjects(true)
    assert "gtd.coach.chat" in served
    assert "events.llm.job.completed" in served
  end

  test "a standby answers neither, so a demoted node never speaks for a leader-less fleet" do
    standby = Consumer.served_subjects(false)
    refute "gtd.coach.chat" in standby
    refute "events.llm.job.completed" in standby
  end
end
