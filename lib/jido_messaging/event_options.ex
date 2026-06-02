defmodule Jido.Messaging.EventOptions do
  @moduledoc """
  Normalizes user-facing event option keys for messaging command and presence APIs.
  """

  @event_keys %{
    "adapter_event_type" => :adapter_event_type,
    "bridge_id" => :bridge_id,
    "causation_id" => :causation_id,
    "channel" => :channel,
    "channel_type" => :channel_type,
    "chat_type" => :chat_type,
    "correlation_id" => :correlation_id,
    "dataschema" => :dataschema,
    "delivery_external_room_id" => :delivery_external_room_id,
    "external_message_id" => :external_message_id,
    "external_room_id" => :external_room_id,
    "external_thread_id" => :external_thread_id,
    "instance_id" => :instance_id,
    "message_id" => :message_id,
    "payload_kind" => :payload_kind,
    "target_kind" => :target_kind,
    "thread_id" => :thread_id
  }

  @command_keys Map.merge(@event_keys, %{
                  "legacy_event" => :legacy_event,
                  "metadata" => :metadata,
                  "presence" => :presence,
                  "reason" => :reason,
                  "session_id" => :session_id,
                  "source" => :source
                })

  @presence_keys Map.merge(@command_keys, %{
                   "heartbeat_ms" => :heartbeat_ms,
                   "notify" => :notify,
                   "presence_pid" => :presence_pid,
                   "prune_ms" => :prune_ms,
                   "signal_opts" => :signal_opts,
                   "track_pid" => :track_pid,
                   "ttl_ms" => :ttl_ms
                 })

  @spec normalize(keyword() | map() | term(), :event | :command | :presence) :: keyword()
  @doc """
  Returns a keyword list containing only recognized options for the selected keyspace.

  Atom keys pass through unchanged. String keys are converted to their canonical
  atom form when they are known for the `:event`, `:command`, or `:presence`
  keyspace.
  """
  def normalize(opts, keyspace \\ :event)

  def normalize(opts, keyspace) when is_list(opts) do
    Enum.flat_map(opts, &normalize_option_pair(&1, keyspace))
  end

  def normalize(opts, keyspace) when is_map(opts) do
    Enum.flat_map(opts, &normalize_option_pair(&1, keyspace))
  end

  def normalize(_opts, _keyspace), do: []

  defp normalize_option_pair({key, value}, keyspace) do
    case normalize_option_key(key, keyspace) do
      nil -> []
      key -> [{key, value}]
    end
  end

  defp normalize_option_pair(_other, _keyspace), do: []

  defp normalize_option_key(key, _keyspace) when is_atom(key), do: key
  defp normalize_option_key(key, keyspace) when is_binary(key), do: Map.get(keys(keyspace), key)
  defp normalize_option_key(_key, _keyspace), do: nil

  defp keys(:event), do: @event_keys
  defp keys(:command), do: @command_keys
  defp keys(:presence), do: @presence_keys
  defp keys(_unknown), do: @event_keys
end
