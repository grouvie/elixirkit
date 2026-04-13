defmodule ElixirKit.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/livebook-dev/elixirkit"
  @capability_packages ~w(elixirkit_opener elixirkit_clipboard elixirkit_window)

  def project do
    [
      app: :elixirkit,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      docs: docs()
    ]
  end

  def cli do
    [preferred_envs: ["test.all": :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      description: "Run Elixir from Rust/Tauri apps and exchange messages over PubSub.",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/elixirkit/changelog.html"
      },
      files: [
        "lib",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "LICENSE*",
        "license*",
        "CHANGELOG.md",
        "elixirkit_rs/Cargo.toml",
        "elixirkit_rs/src"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "guides/tauri.md"]
    ]
  end

  defp aliases do
    [
      docs: ["docs.root", "docs.rs", "docs.packages"],
      "docs.root": &docs_root/1,
      "docs.rs": &docs_rs/1,
      "docs.packages": &docs_packages/1,
      "test.all": &test_all/1,
      "test.packages": [
        "cmd --cd packages/elixirkit_opener mix deps.get",
        "cmd --cd packages/elixirkit_opener mix test",
        "cmd --cd packages/elixirkit_clipboard mix deps.get",
        "cmd --cd packages/elixirkit_clipboard mix test",
        "cmd --cd packages/elixirkit_window mix deps.get",
        "cmd --cd packages/elixirkit_window mix test"
      ],
      "test.rs": [
        "cmd cargo fmt --all --check",
        "cmd cargo check --workspace",
        "cmd cargo test --workspace",
        "cmd cargo clippy --workspace --all-targets -- -D warnings"
      ],
      "test.examples": [
        "cmd ./examples/cli_script.rs",
        "cmd --cd examples/tauri_project mix deps.get",
        "cmd --cd examples/tauri_project mix test"
      ]
    ]
  end

  defp test_all(args) do
    Mix.Task.run("test", args)
    Mix.Task.run("test.packages")
    Mix.Task.run("test.rs")
    Mix.Task.run("test.examples")
    validate_versions()
  end

  defp validate_versions do
    {output, 0} =
      System.cmd("cargo", ["pkgid", "--manifest-path", "#{__DIR__}/elixirkit_rs/Cargo.toml"])

    cargo_version = output |> String.trim() |> String.split("@") |> List.last()

    if cargo_version != @version do
      Mix.raise("""
      version mismatch:

      mix.exs:    #{@version}
      Cargo.toml: #{cargo_version}
      """)
    end
  end

  defp docs_root(_) do
    readme = File.read!("README.md")
    File.write!("README.md", String.replace(readme, "https://hexdocs.pm/elixirkit/", ""))

    Mix.Task.run("compile")

    try do
      Mix.Task.run("docs")
    after
      File.write!("README.md", readme)
    end
  end

  defp docs_packages(_) do
    packages_output_dir = Path.join([__DIR__, "doc", "packages"])
    File.rm_rf!(packages_output_dir)
    File.mkdir_p!(packages_output_dir)

    Enum.each(@capability_packages, fn package ->
      package_dir = Path.join([__DIR__, "packages", package])
      package_output_dir = Path.join(packages_output_dir, package)

      case System.cmd("mix", ["docs"], cd: package_dir, into: IO.stream(), stderr_to_stdout: true) do
        {_, 0} ->
          File.cp_r!(Path.join(package_dir, "doc"), package_output_dir)

        {_, status} ->
          Mix.raise("package docs failed for #{package} with exit code #{status}")
      end
    end)
  end

  defp docs_rs(_) do
    case Mix.shell().cmd("cargo doc --no-deps --workspace") do
      0 ->
        File.rm_rf!("doc/rs")
        File.cp_r!("target/doc", "doc/rs")

      status ->
        Mix.raise("cargo doc failed with exit code #{status}")
    end
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, ">= 0.0.0", only: :dev, warn_if_outdated: true},
      {:makeup_syntect, ">= 0.0.0", only: :dev}
    ]
  end
end
