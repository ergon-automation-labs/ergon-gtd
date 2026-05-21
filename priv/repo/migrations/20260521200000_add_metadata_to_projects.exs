defmodule BotArmyGTD.Repo.Migrations.AddMetadataToProjects do
  use Ecto.Migration

  def up do
    alter table(:projects) do
      add(:metadata, :map, default: %{})
    end
  end

  def down do
    alter table(:projects) do
      remove(:metadata)
    end
  end
end
