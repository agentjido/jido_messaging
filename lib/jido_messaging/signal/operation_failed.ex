defmodule Jido.Messaging.Signal.OperationFailed do
  @moduledoc """
  Typed result definition for `jido.messaging.operation.failed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room operations; absence is permitted for non-room operations.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :result,
    type: "jido.messaging.operation.failed",
    dataschema: "urn:jido:messaging:schema:operation_failed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.union([
        Zoi.map(
          %{
            "operation" =>
              Zoi.enum([
                "provider.send_message",
                "provider.send_file",
                "provider.post_message",
                "provider.edit_message",
                "provider.delete_message",
                "provider.start_typing",
                "provider.fetch_metadata",
                "provider.fetch_thread",
                "provider.fetch_message",
                "provider.get_user",
                "provider.fetch_subject",
                "provider.get_thread_participants",
                "provider.mark_as_read",
                "provider.fetch_media",
                "provider.add_reaction",
                "provider.remove_reaction",
                "provider.post_ephemeral",
                "provider.post_channel_message",
                "provider.stream",
                "provider.open_modal",
                "provider.load_options",
                "provider.fetch_messages",
                "provider.fetch_channel_messages",
                "provider.list_threads",
                "provider.open_thread",
                "provider.open_dm",
                "post_message",
                "create_room",
                "participant_joined",
                "participant_left",
                "set_presence",
                "set_typing",
                "add_room_reaction",
                "remove_room_reaction",
                "mark_delivered",
                "mark_read"
              ]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "code" =>
              Zoi.enum([
                "unsupported",
                "provider_failure",
                "invalid_provider_result",
                "resource_expired",
                "resource_cancelled",
                "resource_failure",
                "authorization_denied",
                "authorization_store_failed",
                "persistence_failed",
                "observation_failed"
              ]),
            "retryable" => Zoi.boolean()
          },
          unrecognized_keys: :error
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["route_outbound"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "code" =>
              Zoi.enum([
                "unsupported",
                "provider_failure",
                "invalid_provider_result",
                "resource_expired",
                "resource_cancelled",
                "resource_failure",
                "authorization_denied",
                "authorization_store_failed",
                "persistence_failed",
                "observation_failed"
              ]),
            "retryable" => Zoi.boolean(),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "attempted" => Zoi.integer() |> Zoi.gte(0),
                    "delivery_mode" => Zoi.enum(["best_effort", "primary", "broadcast"]),
                    "delivered" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "bridge_id" => Zoi.string() |> Zoi.min(1),
                            "message_id" => Zoi.string() |> Zoi.min(1),
                            "attempts" => Zoi.integer() |> Zoi.gte(1)
                          },
                          unrecognized_keys: :error
                        )
                      ),
                    "failed" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "bridge_id" => Zoi.string() |> Zoi.min(1),
                            "code" =>
                              Zoi.enum([
                                "provider_failure",
                                "unsupported",
                                "authorization_denied",
                                "persistence_failed"
                              ]),
                            "retryable" => Zoi.boolean(),
                            "attempts" => Zoi.integer() |> Zoi.gte(1)
                          },
                          unrecognized_keys: :error
                        )
                      )
                  },
                  unrecognized_keys: :error
                ),
                Zoi.map(
                  %{
                    "resource_ref" =>
                      Zoi.map(
                        %{
                          "id" => Zoi.string() |> Zoi.min(1),
                          "scope" => Zoi.enum(["call"]),
                          "binding_id" => Zoi.string() |> Zoi.min(1),
                          "kind" => Zoi.enum(["file", "media", "stream", "card", "modal", "result"])
                        },
                        unrecognized_keys: :error
                      )
                  },
                  unrecognized_keys: :error
                )
              ])
              |> Zoi.optional()
          },
          unrecognized_keys: :error
        ),
        Zoi.map(
          %{
            "operation" =>
              Zoi.enum([
                "tool.fetch_message",
                "tool.fetch_channel_messages",
                "tool.fetch_thread",
                "tool.fetch_thread_messages",
                "tool.list_threads",
                "tool.lookup_participant",
                "tool.lookup_user",
                "tool.fetch_channel_metadata",
                "tool.post_message",
                "tool.post_channel_message",
                "tool.send_direct_message",
                "tool.start_typing",
                "tool.edit_message",
                "tool.delete_message",
                "tool.add_reaction",
                "tool.remove_reaction",
                "tool.ensure_subscription",
                "tool.list_subscriptions",
                "tool.delete_subscription"
              ]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "code" =>
              Zoi.enum([
                "policy_denied",
                "approval_required",
                "out_of_scope",
                "authorization_denied",
                "authorization_store_failed",
                "unsupported_operation",
                "provider_error",
                "not_found",
                "ambiguous",
                "missing_runtime_context",
                "missing_target",
                "missing_bridge_id",
                "missing_channel_id",
                "bridge_not_found",
                "bridge_disabled",
                "target_mismatch",
                "missing_scope",
                "invalid_scope",
                "workspace_scope_required",
                "invalid_policy",
                "invalid_provider_result",
                "resource_expired",
                "observation_failed",
                "workspace_scope_not_explicit"
              ]),
            "retryable" => Zoi.boolean()
          },
          unrecognized_keys: :error
        )
      ])
end
