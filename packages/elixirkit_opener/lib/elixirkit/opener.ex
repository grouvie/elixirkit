defmodule ElixirKit.Opener do
  @moduledoc """
  Tiny Elixir wrapper for the `opener` host capability.

  This module stays intentionally small. It delegates to the existing
  brokered bridge call path and uses the shared JSON body helpers for its
  request and success-response payloads.

  Registration of the backing host capability is still explicit on the Rust
  side. In the example Tauri app that registration happens in
  `src-tauri/src/lib.rs`, now through the extracted
  `tauri-plugin-elixir-opener` helper crate.
  """

  @type open_result() :: :ok | {:error, term()}

  @doc """
  Requests that the host open the given target string.
  """
  @spec open(String.t()) :: open_result()
  def open(target) when is_binary(target) do
    open(ElixirKit.Bridge, target)
  end

  @doc false
  @spec open(atom(), String.t()) :: open_result()
  def open(server, target) when is_atom(server) and is_binary(target) do
    with {:ok, body} <- ElixirKit.Bridge.Protocol.encode_json_body(%{"target" => target}),
         {:ok, response} <- ElixirKit.Bridge.call(server, "opener.open", body, 5_000),
         {:ok, %{}} <- ElixirKit.Bridge.Protocol.decode_json_body(response) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_response, other}}
    end
  end
end
