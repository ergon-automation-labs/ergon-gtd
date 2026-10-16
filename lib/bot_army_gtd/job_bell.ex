defmodule BotArmyGtd.JobBell do
  @moduledoc """
  The llm bot's bell, and the processes waiting to hear it.

  A backgrounded (`async`) LLM job is answered by a local model whose duration is a property of
  the model — a minute or more — so the GTD coach waits for it instead of asking. There are two
  ways to learn a job finished: keep asking (`llm.job.status`), or be told. The llm bot tells us
  on `events.llm.job.completed`, carrying a job id and a status and **nothing else**. The words
  are fetched afterwards by id, which is the whole point: a completion event that carried the
  answer would spray it across every bot on the bus.

  This module is the local half — a duplicate-key registry, one entry per waiting process. A
  waiter registers the job id and blocks in `receive`:

      JobBell.watch(job_id)
      receive do
        {:job_bell, ^job_id} -> :it_is_done
      after
        wait_ms -> :ask_instead
      end

  A bell is a **wake-up, never a proof**: the waiter reads `llm.job.status` afterwards, because
  the store is what is true. And a bell that never comes is survivable by design — the waiter
  still asks on its own cadence, so an llm bot older than the async path behaves as it did
  before the bell existed.

  The subscription that rings this is leader-gated like every other GTD subject (see
  `BotArmyGtd.NATS.Consumer`), which is exactly right: `gtd.coach.chat` is served by the leader
  alone, so the only process that ever waits on a bell lives there.
  """

  require Logger

  @registry __MODULE__

  @doc "Supervisor child: a registry that allows one entry per waiting process."
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: @registry)
  end

  @doc """
  Registers the calling process as waiting for `job_id`.

  A registry that is not running is not an error: it is a slower waiter. This returns
  `{:error, :no_registry}` and the caller polls as it always did.
  """
  @spec watch(String.t()) :: :ok | {:error, :no_registry}
  def watch(job_id) when is_binary(job_id) do
    case Registry.register(@registry, job_id, nil) do
      {:ok, _key} -> :ok
      {:error, _reason} -> {:error, :no_registry}
    end
  rescue
    ArgumentError -> {:error, :no_registry}
  catch
    :exit, _reason -> {:error, :no_registry}
  end

  @doc "Stops waiting. Safe to call when `watch/1` was refused, or twice."
  @spec unwatch(String.t()) :: :ok
  def unwatch(job_id) when is_binary(job_id) do
    Registry.unregister(@registry, job_id)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Wakes every process waiting on this job. Called by the consumer when a bell arrives, so the
  ring comes through the same door as every other message.
  """
  @spec ring(String.t()) :: :ok
  def ring(job_id) when is_binary(job_id) do
    Registry.dispatch(@registry, job_id, fn waiters ->
      Enum.each(waiters, fn {pid, _value} -> send(pid, {:job_bell, job_id}) end)
    end)

    :ok
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end
end
