defmodule ElixirKit.Opener do
  @moduledoc """
  Tiny Elixir wrapper for the first real host capability vertical slice.

  This module stays intentionally small. It delegates to
  `ElixirKit.Bridge.call/4` over the existing brokered bridge path and sends
  the UTF-8 target string directly as the opaque request payload.

  Registration of the backing host capability is still explicit on the Rust
  side. In the example Tauri app that registration happens in
  `src-tauri/src/lib.rs`; this is not the later plugin/package split yet.
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
    case ElixirKit.Bridge.call(server, "opener.open", target, 5_000) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
