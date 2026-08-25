defmodule BotArmyGtd.LeaderMonitor do
  @moduledoc """
  Thin wrapper around `BotArmyLibraryRuntime.LeaderElection` for GTD's
  air/mini leader-standby designation.

  Previously ran its own heartbeat listener, which never actually worked:
  it subscribed to `system.health.gtd` (nothing publishes there — the real
  fleet heartbeat is the generic `system.health`) and had no `handle_info`
  clause to convert a received NATS message into its own `:heartbeat_received`
  event. See `BotArmyLibraryRuntime.LeaderElection`'s moduledoc for the fix
  and the manual force-leader/force-standby override this brings.

  `task_store.ex` / `project_store.ex` write-gating is unaffected — same
  `leader?/0` public API as before.
  """

  require Logger

  @service "gtd"

  def leader?, do: BotArmyLibraryRuntime.LeaderElection.leader?(@service)

  def get_status, do: BotArmyLibraryRuntime.LeaderElection.get_status(@service)

  @doc "Called by LeaderElection's on_role_change callback."
  def role_changed(role) do
    Logger.warning("[LeaderMonitor] GTD role changed to #{role}")
  end
end
