defmodule ElixirKitClipboard.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/livebook-dev/elixirkit"

  def project do
    [
      app: :elixirkit_clipboard,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: deps(),
      description: "Elixir wrapper for ElixirKit clipboard capability",
      package: package(),
      docs: docs()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ["lib", "mix.exs", "README.md"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url
    ]
  end

  defp deps do
    [
      {:elixirkit, path: "../.."},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false, warn_if_outdated: true},
      {:makeup_syntect, ">= 0.0.0", only: :dev}
    ]
  end
end
