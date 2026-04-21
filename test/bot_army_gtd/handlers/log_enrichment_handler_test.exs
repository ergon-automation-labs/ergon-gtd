defmodule BotArmyGtd.Handlers.LogEnrichmentHandlerTest do
  use ExUnit.Case
  @moduletag :handlers
  import Mox

  setup :verify_on_exit!

  alias BotArmyGtd.Handlers.LogEnrichmentHandler

  describe "request_enrichment/1" do
    test "returns :ok with valid entry" do
      entry = %{
        "id" => "entry-123",
        "body" => "Spent 2 hours debugging the NATS reconnect issue."
      }

      assert LogEnrichmentHandler.request_enrichment(entry) == :ok
    end

    test "returns :ok non-fatally with nil body" do
      entry = %{
        "id" => "entry-123",
        "body" => nil
      }

      assert LogEnrichmentHandler.request_enrichment(entry) == :ok
    end

    test "returns :ok non-fatally with missing id key" do
      entry = %{
        "body" => "Some log entry"
      }

      assert LogEnrichmentHandler.request_enrichment(entry) == :ok
    end
  end

  describe "handle_enriched/1" do
    test "happy path: marks entry as enriched and publishes event" do
      entry_id = "entry-123"

      structured_data = %{
        "duration_minutes" => 120,
        "energy_level" => "high",
        "sentiment" => "positive"
      }

      updated_entry = %{
        "id" => entry_id,
        "body" => "Spent 2 hours debugging.",
        "enriched" => true,
        "structured_data" => structured_data
      }

      BotArmyGtd.MockLogEntryStore
      |> expect(:mark_enriched, fn ^entry_id, ^structured_data ->
        {:ok, updated_entry}
      end)

      message = %{
        "payload" => %{
          "log_entry_id" => entry_id,
          "structured_data" => structured_data
        }
      }

      assert LogEnrichmentHandler.handle_enriched(message) == :ok
    end

    test "correctly extracts log_entry_id and structured_data from payload" do
      entry_id = "entry-456"

      structured_data = %{
        "sentiment" => "neutral"
      }

      updated_entry = %{
        "id" => entry_id,
        "structured_data" => structured_data,
        "enriched" => true
      }

      BotArmyGtd.MockLogEntryStore
      |> expect(:mark_enriched, fn id, data ->
        assert id == entry_id
        assert data == structured_data
        {:ok, updated_entry}
      end)

      message = %{
        "payload" => %{
          "log_entry_id" => entry_id,
          "structured_data" => structured_data,
          "other_field" => "ignored"
        }
      }

      assert LogEnrichmentHandler.handle_enriched(message) == :ok
    end

    test "returns :ok when log_entry_id is missing (no mark_enriched call)" do
      message = %{
        "payload" => %{
          "structured_data" => %{"sentiment" => "positive"}
        }
      }

      assert LogEnrichmentHandler.handle_enriched(message) == :ok
    end

    test "returns :ok when log_entry_id is nil (no mark_enriched call)" do
      message = %{
        "payload" => %{
          "log_entry_id" => nil,
          "structured_data" => %{"sentiment" => "positive"}
        }
      }

      assert LogEnrichmentHandler.handle_enriched(message) == :ok
    end

    test "returns :ok when structured_data is missing (no mark_enriched call)" do
      message = %{
        "payload" => %{
          "log_entry_id" => "entry-123"
        }
      }

      assert LogEnrichmentHandler.handle_enriched(message) == :ok
    end

    test "returns :ok non-fatally when store fails" do
      entry_id = "entry-789"

      structured_data = %{
        "energy_level" => "low"
      }

      BotArmyGtd.MockLogEntryStore
      |> expect(:mark_enriched, fn ^entry_id, ^structured_data ->
        {:error, :database_error}
      end)

      message = %{
        "payload" => %{
          "log_entry_id" => entry_id,
          "structured_data" => structured_data
        }
      }

      assert LogEnrichmentHandler.handle_enriched(message) == :ok
    end

    test "stores partial LLM output as-is (only sentiment field)" do
      entry_id = "entry-partial"

      structured_data = %{
        "sentiment" => "positive"
      }

      updated_entry = %{
        "id" => entry_id,
        "structured_data" => structured_data
      }

      BotArmyGtd.MockLogEntryStore
      |> expect(:mark_enriched, fn id, data ->
        assert id == entry_id
        assert data == %{"sentiment" => "positive"}
        {:ok, updated_entry}
      end)

      message = %{
        "payload" => %{
          "log_entry_id" => entry_id,
          "structured_data" => %{"sentiment" => "positive"}
        }
      }

      assert LogEnrichmentHandler.handle_enriched(message) == :ok
    end
  end
end
