defmodule Mesh.MixProject do
  use Mix.Project

  @source_url "https://github.com/eigr/mesh"
  @version "0.1.3"

  def project do
    [
      app: :mesh,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Mesh",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:libcluster, "~> 3.3"},
      {:benchee, "~> 1.3", only: :dev},
      {:ex_doc, "~> 0.34", only: [:dev, :docs], runtime: false}
    ]
  end

  defp description do
    """
    Capability-based distributed actor system for Elixir with automatic sharding
    and built-in clustering support.
    """
  end

  defp package do
    %{
      maintainers: ["Adriano Santos"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    }
  end

  defp docs do
    [
      main: "Mesh",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "docs/guides/getting_started/quickstart.livemd",
        "docs/guides/getting_started/clustering.md",
        "docs/guides/advanced/processes.md",
        "docs/guides/advanced/sharding.md"
      ],
      groups_for_modules: [
        "Public API": [
          Mesh,
          Mesh.Supervisor
        ],
        Actors: [
          Mesh.Actors.ActorSystem,
          Mesh.Actors.ActorOwner,
          Mesh.Actors.ActorOwnerSupervisor,
          Mesh.Actors.ActorSupervisor,
          Mesh.Actors.ActorTable
        ],
        Sharding: [
          Mesh.Shards.ShardConfig,
          Mesh.Shards.ShardRouter
        ],
        Clustering: [
          Mesh.Cluster.Capabilities,
          Mesh.Cluster.Membership
        ]
      ],
      groups_for_extras: [
        "Getting Started": ~r"^docs/guides/getting_started/",
        Advanced: ~r"^docs/guides/advanced/"
      ]
    ]
  end
end
