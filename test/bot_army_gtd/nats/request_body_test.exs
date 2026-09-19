defmodule BotArmyGtd.NATS.RequestBodyTest do
  use ExUnit.Case, async: true

  @moduletag :nats

  alias BotArmyGtd.NATS.RequestBody

  describe "plain JSON (what bot_army_claude_bridge sends)" do
    test "becomes an envelope-shaped message with the payload intact" do
      # The bridge's TaskManager.do_create/2 sends exactly this shape.
      body =
        Jason.encode!(%{
          "tenant_id" => "tenant-1",
          "title" => "Log incident: Timeout in gtd",
          "description" => "3 matches",
          "context" => "inbox",
          "priority" => "high",
          "labels" => ["sre", "log-incident"]
        })

      assert {:ok, message} = RequestBody.decode(body)
      assert message["payload"]["title"] == "Log incident: Timeout in gtd"
      assert message["payload"]["priority"] == "high"
      assert message["payload"]["labels"] == ["sre", "log-incident"]
      # The pipeline (TaskHandler/Tenant) reads these from the top level.
      assert message["tenant_id"] == "tenant-1"
    end

    test "a plain body without a title is still rejected" do
      assert {:error, _} = RequestBody.decode(Jason.encode!(%{"priority" => "high"}))
      assert {:error, _} = RequestBody.decode(Jason.encode!(%{"title" => ""}))
    end
  end

  describe "envelope-shaped bodies" do
    test "an envelope's title-in-payload is never mistaken for a plain body" do
      # If the schema-validating decode fails (e.g. no schemas on this host),
      # the plain-body fallback must not accept an envelope as if it were flat:
      # the title is inside "payload", and this body has no title of its own.
      envelope =
        Jason.encode!(%{
          "event" => "gtd.task.create",
          "event_id" => "11111111-1111-1111-1111-111111111111",
          "payload" => %{"title" => "Log incident: Timeout in gtd"}
        })

      assert {:error, _} = RequestBody.decode(envelope)
    end
  end

  describe "junk" do
    test "non-JSON and non-objects are errors, not crashes" do
      assert {:error, _} = RequestBody.decode("not json")
      assert {:error, _} = RequestBody.decode("[1,2,3]")
      assert {:error, _} = RequestBody.decode("")
      assert {:error, _} = RequestBody.decode(nil)
    end
  end
end
