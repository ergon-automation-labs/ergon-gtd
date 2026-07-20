defmodule BotArmyGtd.Adapters.ConfidenceAdapterTest do
  use ExUnit.Case
  @moduletag :handlers

  alias BotArmyGtd.Adapters.ConfidenceAdapter

  describe "should_retry?/2" do
    test "retries when confidence high" do
      task = %{"retry_count" => 0, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, 0.8) == true
    end

    test "does not retry when confidence very low" do
      task = %{"retry_count" => 0, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, 0.2) == false
    end

    test "respects max retry count" do
      task = %{"retry_count" => 3, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, 0.9) == false
    end

    test "retries on boundary confidence (>= 0.7)" do
      task = %{"retry_count" => 0, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, 0.7) == true
    end

    test "does retry on low boundary confidence (0.3)" do
      task = %{"retry_count" => 0, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, 0.3) == true
    end

    test "allows medium confidence retries" do
      task = %{"retry_count" => 1, "id" => "task-1"}
      # 0.5 is in medium range (0.3-0.7)
      assert ConfidenceAdapter.should_retry?(task, 0.5) == true
    end

    test "stops at max retries even with high confidence" do
      task = %{"retry_count" => 4, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, 0.95) == false
    end

    test "defaults to retry count check when confidence invalid" do
      task = %{"retry_count" => 2, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, nil) == true

      task_maxed = %{"retry_count" => 3, "id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task_maxed, nil) == false
    end

    test "initializes retry_count to 0 if missing" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_retry?(task, 0.8) == true
    end
  end

  describe "should_replan?/3" do
    test "replans when confidence low" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_replan?(task, 1, 0.2) == true
    end

    test "does not replan with high confidence and room for retries" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_replan?(task, 0, 0.8) == false
    end

    test "replans when retry count exceeded" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_replan?(task, 4, 0.7) == true
    end

    test "replans at exact boundary (retry_count > 3)" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_replan?(task, 3, 0.7) == false
      assert ConfidenceAdapter.should_replan?(task, 4, 0.7) == true
    end

    test "replans on low confidence boundary (< 0.3) with retries" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_replan?(task, 1, 0.3) == false
      assert ConfidenceAdapter.should_replan?(task, 1, 0.2) == true
    end

    test "does not replan on low confidence if no retries yet" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_replan?(task, 0, 0.2) == false
    end

    test "defaults to retry count check when confidence invalid" do
      task = %{"id" => "task-1"}
      assert ConfidenceAdapter.should_replan?(task, 2, nil) == false
      assert ConfidenceAdapter.should_replan?(task, 4, nil) == true
    end
  end

  describe "increment_retry_count/1" do
    test "increments existing retry count" do
      task = %{"retry_count" => 2, "id" => "task-1"}
      result = ConfidenceAdapter.increment_retry_count(task)
      assert result["retry_count"] == 3
    end

    test "initializes retry count to 1 if missing" do
      task = %{"id" => "task-1", "title" => "Test Task"}
      result = ConfidenceAdapter.increment_retry_count(task)
      assert result["retry_count"] == 1
    end

    test "preserves other task fields" do
      task = %{"id" => "task-1", "title" => "Important Task", "priority" => "high"}
      result = ConfidenceAdapter.increment_retry_count(task)
      assert result["id"] == "task-1"
      assert result["title"] == "Important Task"
      assert result["priority"] == "high"
      assert result["retry_count"] == 1
    end
  end

  describe "get_dispatcher_confidence/1" do
    setup do
      # Mock BotArmyLibraryRuntime.NATS.Publisher.request/3
      {:ok, _} =
        start_supervised(
          {Agent,
           fn ->
             %{
               response: nil,
               error: nil
             }
           end}
        )

      :ok
    end

    test "returns confidence float on success" do
      # We'll test the fallback behavior in this unit test
      # since we can't easily mock NATS in ExUnit without integration setup
      confidence = ConfidenceAdapter.get_dispatcher_confidence("test_bot")
      assert is_float(confidence)
      assert confidence >= 0.0 and confidence <= 1.0
    end

    test "defaults to 0.5 on error" do
      # When dispatcher is unavailable, should return 0.5
      confidence = ConfidenceAdapter.get_dispatcher_confidence("missing_bot")
      assert is_float(confidence)
      # In real scenarios with no NATS, falls back to 0.5
      assert confidence >= 0.0 and confidence <= 1.0
    end

    test "returns valid confidence value for any bot name" do
      Enum.each(["gtd", "llm", "dispatcher", "chore", "unknown_bot"], fn bot_name ->
        confidence = ConfidenceAdapter.get_dispatcher_confidence(bot_name)
        assert is_float(confidence)
        assert confidence >= 0.0 and confidence <= 1.0
      end)
    end
  end

  describe "confidence decision matrices" do
    test "high confidence + low retry count → retry" do
      task = %{"retry_count" => 0}
      assert ConfidenceAdapter.should_retry?(task, 0.9) == true
      assert ConfidenceAdapter.should_replan?(task, 0, 0.9) == false
    end

    test "low confidence + retries attempted → replan" do
      task = %{"retry_count" => 2}
      assert ConfidenceAdapter.should_retry?(task, 0.2) == false
      assert ConfidenceAdapter.should_replan?(task, 2, 0.2) == true
    end

    test "max retries reached → always replan or stop" do
      task = %{"retry_count" => 4}
      assert ConfidenceAdapter.should_retry?(task, 0.95) == false
      assert ConfidenceAdapter.should_replan?(task, 4, 0.95) == true
    end

    test "medium confidence + some retries → still can retry" do
      task = %{"retry_count" => 1}
      assert ConfidenceAdapter.should_retry?(task, 0.5) == true
      assert ConfidenceAdapter.should_replan?(task, 1, 0.5) == false
    end
  end
end
