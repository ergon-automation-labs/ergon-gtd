defmodule BotArmyGtd.Repo.Migrations.AddLabelsToProjects do
  use Ecto.Migration

  def change do
    # Add labels as an array for filtering and categorization
    add(:labels, {:array, :string}, default: [])

    # Add index for labels filtering
    create(index(:projects, ["labels"], using: :gin))
  end
end
