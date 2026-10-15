defmodule Jido.Messaging.Persistence.Payload do
  @moduledoc false

  # Format v1 is the existing, unwrapped Erlang record term. Do not change
  # record module names or fields without the upgrade contract in
  # docs/stored-record-compatibility.md. C4 adds no database migration.

  @doc "Encodes the existing record term without an envelope or field changes."
  @spec encode(term()) :: binary()
  def encode(record), do: :erlang.term_to_binary(record)

  @doc "Reads format v1 with the adapter's existing Erlang decoder options."
  @spec decode(binary(), [:safe | :used]) :: term()
  def decode(payload, options \\ []), do: :erlang.binary_to_term(payload, options)
end
