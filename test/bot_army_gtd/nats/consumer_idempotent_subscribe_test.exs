defmodule BotArmyGtd.NATS.ConsumerIdempotentSubscribeTest do
  use ExUnit.Case, async: true
  @moduletag :nats

  alias BotArmyGtd.NATS.Consumer

  # Measured 2026-10-13: the air broker restart produced three
  # {:nats, :connected} / :reconnect rounds in ~2s. Each round re-subscribed all
  # 46 subjects, and the :disconnected handler had reset `subscriptions: []`, so
  # the next round had nothing to drop — the connection ended up holding 303
  # subscriptions (46 subjects × ~6.5) on a single cid. The sids must survive a
  # flap so the next connect can drop them before re-subscribing.
  test "a disconnect keeps the subscriptions so the next connect can drop them" do
    held = [%{subject: "gtd.task.list", sid: 1}, %{subject: "gtd.task.get", sid: 2}]

    {:noreply, next} =
      Consumer.handle_info({:nats, :disconnected}, %{
        subscriptions: held,
        reconnect_attempt: 0,
        conn: :some_conn,
        opts: []
      })

    assert next.subscriptions == held
    assert next.conn == nil
  end

  test "the connect path drops held subscriptions before it subscribes" do
    source = File.read!("lib/bot_army_gtd/nats/consumer.ex")

    assert String.contains?(source, "unsubscribe_all(conn, state.subscriptions)"),
           "handle_continue(:connect) must drop held subscriptions before subscribing"

    refute String.contains?(source, "%{state | subscriptions: [], conn: nil"),
           "a disconnect must not reset subscriptions — that is the duplication bug"
  end
end
