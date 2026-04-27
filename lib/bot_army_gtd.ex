defmodule BotArmyGtd do
  @moduledoc """
  BotArmyGtd is the GTD (Getting Things Done) bot implementation.

  Handles task management, inbox processing, and project organization
  within the Bot Army ecosystem.

  ## Schemas

  Message schemas are defined in `bot_army_schemas_gtd` and deployed to:
  `/etc/bot_army/schemas/gtd/`

  The bot consumes messages from NATS subjects like:
  - `gtd.inbox.add` - Add item to inbox
  - `gtd.task.create` - Create task
  - `gtd.project.update` - Update project
  """

  @version Mix.Project.config()[:version]

  def version do
    @version
  end
end
