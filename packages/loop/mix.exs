defmodule Loop.MixProject do
  use Mix.Project

  def project do
    [
      app: :loop,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Loop.CLI, app: nil]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :inets, :ssl],
      mod: {Loop.Application, []}
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:websock_adapter, "~> 0.5"}
    ]
  end
end
