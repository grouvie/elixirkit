defmodule ElixirKit.Window do
  @moduledoc """
  Tiny Elixir wrapper for the `window` host capability.

  This module keeps the existing brokered bridge path and uses the shared JSON
  body helpers for request and success-response payloads. Registration remains
  explicit on the Rust side.
  """

  alias ElixirKit.Bridge
  alias ElixirKit.Bridge.Protocol

  @type window_info() :: %{label: String.t(), title: String.t()}
  @type list_result() :: {:ok, [window_info()]} | {:error, term()}
  @type set_title_result() :: :ok | {:error, term()}

  @doc """
  Lists known host windows.
  """
  @spec list() :: list_result()
  def list do
    list(Bridge)
  end

  @doc false
  @spec list(atom()) :: list_result()
  def list(server) when is_atom(server) do
    with {:ok, body} <- Protocol.encode_json_body(%{}),
         {:ok, response} <- Bridge.call(server, "window.list", body, 5_000),
         {:ok, %{"windows" => windows}} when is_list(windows) <-
           Protocol.decode_json_body(response),
         {:ok, normalized} <- normalize_windows(windows) do
      {:ok, normalized}
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_response, other}}
    end
  end

  @doc """
  Sets the title for the given window label.
  """
  @spec set_title(String.t(), String.t()) :: set_title_result()
  def set_title(label, title) when is_binary(label) and is_binary(title) do
    set_title(Bridge, label, title)
  end

  @doc false
  @spec set_title(atom(), String.t(), String.t()) :: set_title_result()
  def set_title(server, label, title)
      when is_atom(server) and is_binary(label) and is_binary(title) do
    with {:ok, body} <- Protocol.encode_json_body(%{"label" => label, "title" => title}),
         {:ok, response} <- Bridge.call(server, "window.set_title", body, 5_000),
         {:ok, %{}} <- Protocol.decode_json_body(response) do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:invalid_response, other}}
    end
  end

  defp normalize_windows(windows) do
    Enum.reduce_while(windows, {:ok, []}, fn window, {:ok, acc} ->
      case window do
        %{"label" => label, "title" => title} when is_binary(label) and is_binary(title) ->
          {:cont, {:ok, [%{label: label, title: title} | acc]}}

        other ->
          {:halt, {:error, {:invalid_response, other}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end
end
