defmodule BotArmyGtd.MixProject do
  use Mix.Project

  def project do
    [
      app: :bot_army_gtd,
      version: "0.7.154",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        gtd_bot: [
          applications: [bot_army_gtd: :permanent],
          validate_compile_env: false
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BotArmyGtd.Application, []}
    ]
  end

  defp deps do
    [
      {:bot_army_library_core, path: "../bot_army_library_core"},
      {:bot_army_library_runtime, path: "../bot_army_library_runtime"},
      {:bot_army_library_learning, path: "../bot_army_library_learning"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:logger_json, "~> 5.1"},
      {:elixir_uuid, "~> 1.2"},

      # Development/Test
      {:ex_doc, "~> 0.30", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test]},
      {:excoveralls, "~> 0.17", only: :test},
      {:mox, "~> 1.0", only: :test}
    ]
    |> add_optional_aggregator()
  end

  defp add_optional_aggregator(deps) do
    if System.get_env("GTD_AGGREGATOR_ENABLED") == "true" do
      deps ++ [{:bot_army_aggregator, path: "../../bot_army_aggregator"}]
    else
      deps
    end
  end
end
