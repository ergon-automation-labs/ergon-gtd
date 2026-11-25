defmodule BotArmyGtd.NATS.DecodeErrorTest do
  use ExUnit.Case, async: true
  @moduletag :nats

  alias BotArmyGtd.NATS.DecodeError

  # Measured 2026-11-25 on deployed 0.9.2: `gtd.task.complete` was sent
  #   {"event_id": "evt-1", "payload": {"task_id": "…"}}
  # and the answer was `{"code":"decode_error","error":"Invalid message format"}`
  # while the bot knew exactly what was missing. The next request was a guess.
  test "a missing-field error names the fields and prints the envelope to send" do
    message =
      DecodeError.message(
        "gtd.task.complete",
        {:missing_required_fields,
         ["event", "schema_version", "timestamp", "source", "source_node", "triggered_by"]},
        door: "bridge.task.complete",
        payload: ~s({"task_id": "<uuid>"})
      )

    for field <- ~w(event schema_version timestamp source source_node triggered_by) do
      assert message =~ field
    end

    # The envelope the subject actually accepts.
    assert message =~ ~s("event": "gtd.task.complete")
    assert message =~ ~s("event_id": "<uuid>")
    assert message =~ ~s("payload": {"task_id": "<uuid>"})

    # And the door that does the wrapping for you.
    assert message =~ "bridge.task.complete"
  end

  test "a type error says which field was wrong, not just that decoding failed" do
    message =
      DecodeError.message("gtd.task.create", {:invalid_field_type, "payload", "object"}, [])

    assert message =~ ~s(envelope field "payload" must be object)
    assert message =~ ~s("event": "gtd.task.create")
  end

  test "a non-JSON body says so, with the reason" do
    message = DecodeError.message("gtd.task.update", {:json_decode_error, :unexpected_byte}, [])

    assert message =~ "the body is not JSON"
    assert message =~ "unexpected_byte"
  end

  test "reply/3 answers ok:false with code decode_error and the same diagnosis" do
    reply =
      "gtd.project.update"
      |> DecodeError.reply({:missing_required_fields, ["event"]},
        door: "bridge.project.update",
        payload: ~s({"project_id": "<uuid>"})
      )
      |> Jason.decode!()

    assert reply["ok"] == false
    assert reply["code"] == "decode_error"
    assert reply["error"] =~ ~s("event": "gtd.project.update")
    assert reply["error"] =~ "bridge.project.update"
  end

  test "the reply echoes the sender of the rejected message" do
    message =
      DecodeError.message(
        "gtd.task.complete",
        {:missing_required_fields, ["event", "schema_version"]},
        received:
          ~s({"event_id":"evt-9","source":"bot_army_sre","source_node":"mini","triggered_by":"incident-loop","payload":{"task_id":"nope"}})
      )

    assert message =~ "Received from source=bot_army_sre source_node=mini triggered_by=incident-loop"
    assert message =~ "event_id=evt-9"
  end

  test "a message that names no sender is called out, not silently echoed" do
    message =
      DecodeError.message(
        "gtd.task.complete",
        {:missing_required_fields, ["event"]},
        received: ~s({"event_id":"evt-10","payload":{"task_id":"nope"}})
      )

    assert message =~ "does not name its sender"
    assert message =~ "event_id=evt-10"
  end

  test "a body that is not JSON is echoed raw and labelled" do
    message =
      DecodeError.message("gtd.task.create", {:json_decode_error, :unexpected_byte},
        received: "title=learn elixir"
      )

    assert message =~ "Received (not JSON): title=learn elixir"
  end

  test "a huge body is truncated so the reply stays readable" do
    message =
      DecodeError.message("gtd.task.create", {:missing_required_fields, ["event"]},
        received: ~s({"source":"x","description":"#{String.duplicate("a", 5_000)}"})
      )

    assert String.length(message) < 1_500
    assert message =~ "…"
  end

  test "an unknown decode failure still carries the raw reason" do
    message = DecodeError.message("gtd.task.create", {:schema_not_found, "core/task"}, [])
    assert message =~ "not installed on this node"
    assert message =~ "core/task"
  end
end
