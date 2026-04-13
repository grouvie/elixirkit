defmodule ElixirKit.Clipboard do
  @moduledoc """
  Tiny Elixir wrapper for the `clipboard` host capability.

  Requests and success responses use the shared JSON body helpers layered over
  the existing brokered bridge path. Registration of the backing host
  capability remains explicit on the Rust side.
  """

  alias ElixirKit.Bridge
  alias ElixirKit.Bridge.Protocol

  @type read_text_result() :: {:ok, String.t()} | {:error, term()}
  @type write_text_result() :: :ok | {:error, term()}

  @doc """
  Reads text from the host clipboard.
  """
  @spec read_text() :: read_text_result()
  def read_text do
    read_text(Bridge)
  end

  @doc false
  @spec read_text(atom()) :: read_text_result()
  def read_text(server) when is_atom(server) do
    with {:ok, body} <- Protocol.encode_json_body(%{}),
         {:ok, response} <- Bridge.call(server, "clipboard.read_text", body, 5_000),
         {:ok, %{"text" => text}} when is_binary(text) <- Protocol.decode_json_body(response) do
      {:ok, text}
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_response, other}}
    end
  end

  @doc """
  Writes text to the host clipboard.
  """
  @spec write_text(String.t()) :: write_text_result()
  def write_text(text) when is_binary(text) do
    write_text(Bridge, text)
  end

  @doc false
  @spec write_text(atom(), String.t()) :: write_text_result()
  def write_text(server, text) when is_atom(server) and is_binary(text) do
    with {:ok, body} <- Protocol.encode_json_body(%{"text" => text}),
         {:ok, response} <- Bridge.call(server, "clipboard.write_text", body, 5_000),
         {:ok, %{}} <- Protocol.decode_json_body(response) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_response, other}}
    end
  end
end
