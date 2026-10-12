defmodule Jido.Messaging.Signal.Identity do
  @moduledoc """
  Builds stable runtime context identities from instance and canonical room keys.

  An unresolved membership observation has no subject. This helper does not
  resolve provider keys or create canonical identities.
  """

  @doc "Returns the opaque source for a configured stable instance key."
  @spec instance_source(String.t()) :: String.t()
  def instance_source(instance_id), do: "urn:jido:messaging:instance:" <> encode(instance_id, 128)

  @doc "Returns the canonical room subject, or nil for an unresolved room."
  @spec room_subject(String.t() | nil) :: String.t() | nil
  def room_subject(nil), do: nil
  def room_subject(room_id), do: "room:" <> encode(room_id, 2_048)

  defp encode(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value), do: Base.url_encode64(value, padding: false), else: invalid_key()
  end

  defp encode(_value, _max_bytes), do: invalid_key()
  defp invalid_key, do: raise(ArgumentError, "expected a non-empty UTF-8 identity key within its byte limit")
end
