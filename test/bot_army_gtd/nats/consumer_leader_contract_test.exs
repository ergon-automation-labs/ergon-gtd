defmodule BotArmyGtd.NATS.ConsumerLeaderContractTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyGtd.NATS.Consumer

  # GTD runs on two hosts (air primary, mini standby) against one shared broker.
  # While both subscribed to every subject, a request-reply reached BOTH and the
  # FIRST reply won -- the standby's instant refusal beat the leader's database
  # write, so callers were told a landed write had failed. A standby now subscribes
  # to nothing: it cannot answer what it must not serve, so there is no race to
  # lose. See docs/LEADER_ELECTION.md.
  test "a standby serves no subjects at all" do
    assert Consumer.served_subjects(false) == []
  end

  test "the leader serves the GTD command surface" do
    subjects = Consumer.served_subjects(true)

    for subject <- [
          "gtd.inbox.add",
          "gtd.task.create",
          "gtd.task.update",
          "gtd.task.get",
          "gtd.task.list",
          "gtd.task.complete",
          "gtd.project.list",
          "gtd.health"
        ] do
      assert subject in subjects, "#{subject} must be served by the leader"
    end

    assert length(subjects) == 46
  end

  test "promotion subscribes to what is served but not already held" do
    assert Consumer.subjects_to_subscribe(true, []) == Consumer.served_subjects(true)

    held = ["gtd.task.update"]
    to_add = Consumer.subjects_to_subscribe(true, held)

    refute "gtd.task.update" in to_add
    assert "gtd.task.get" in to_add
    assert length(to_add) == 45
  end

  test "a standby subscribes to nothing, so promotion only ever adds" do
    assert Consumer.subjects_to_subscribe(false, []) == []
  end

  test "demotion drops every subscription and promotion drops none" do
    subscriptions = [
      %{subject: "gtd.task.update", sid: 1},
      %{subject: "gtd.task.get", sid: 2}
    ]

    assert Consumer.subjects_to_unsubscribe(true, subscriptions) == []
    assert Consumer.subjects_to_unsubscribe(false, subscriptions) == subscriptions
  end

  test "role_changed/1 is a no-op when the consumer is not running" do
    refute Process.whereis(Consumer)
    assert Consumer.role_changed(:primary) == :ok
  end

  test "role_changed/1 delivers the transition to the running consumer" do
    # The consumer is a GenServer named after its module; stand in for it.
    Process.register(self(), Consumer)
    assert Consumer.role_changed(:standby) == :ok
    assert_received {:role_changed, :standby}
  end
end
