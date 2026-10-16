defmodule BotArmyGtd.LlmReplyTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyGtd.LlmReply

  describe "text/1" do
    test "reads the completion, response, content and nested data.text shapes" do
      assert LlmReply.text(%{"completion" => "hello"}) == {:ok, "hello"}
      assert LlmReply.text(%{"response" => "hi there"}) == {:ok, "hi there"}
      assert LlmReply.text(%{"content" => "the job's words"}) == {:ok, "the job's words"}
      assert LlmReply.text(%{"data" => %{"text" => "nested"}}) == {:ok, "nested"}
    end

    test "an empty answer is not an answer" do
      assert LlmReply.text(%{"completion" => ""}) == {:error, :invalid_response}
      assert LlmReply.text(%{"response" => ""}) == {:error, :invalid_response}
      assert LlmReply.text(%{"content" => ""}) == {:error, :invalid_response}
    end

    test "a shape this bot does not know is refused, not guessed at" do
      assert LlmReply.text(%{"foo" => "bar"}) == {:error, :invalid_response}
      assert LlmReply.text("just a string") == {:error, :invalid_response}
      assert LlmReply.text(nil) == {:error, :invalid_response}
    end
  end

  describe "decode/1" do
    test "decodes a JSON body and reads its text" do
      assert LlmReply.decode(Jason.encode!(%{"completion" => "notes filed"})) ==
               {:ok, "notes filed"}
    end

    test "a body that is not JSON is an error, not a crash" do
      assert {:error, _} = LlmReply.decode("not json")
    end
  end

  describe "read/1" do
    test "reads every shape the reply hop carries" do
      assert LlmReply.read({:ok, %{body: ~s({"completion":"a"})}}) == {:ok, "a"}
      assert LlmReply.read({:ok, ~s({"completion":"b"})}) == {:ok, "b"}
      assert LlmReply.read({:ok, %{"response" => "c"}}) == {:ok, "c"}
    end

    test "carries a failed hop and a timeout through as errors" do
      assert LlmReply.read({:error, :no_responders}) == {:error, :no_responders}
      assert LlmReply.read({:timeout, 20_000}) == {:error, :timeout}
    end

    test "a shape the hop should not have sent is an error, not a crash" do
      assert LlmReply.read(:nonsense) == {:error, {:unexpected_llm_reply, :nonsense}}
    end
  end
end
