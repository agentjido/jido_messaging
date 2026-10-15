defmodule Jido.Messaging.Signal.RoomMessageAdded do
  @moduledoc """
  Typed fact definition for `jido.messaging.room.message_added`.

  Data uses the protocol version 1 string-key schema. Canonical room subject; thread identity is data.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :fact,
    type: "jido.messaging.room.message_added",
    dataschema: "urn:jido:messaging:schema:room_message_added:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.map(
        %{
          "message" =>
            Zoi.map(
              %{
                "id" => Zoi.string() |> Zoi.min(1),
                "room_id" => Zoi.string() |> Zoi.min(1),
                "text" => Zoi.string() |> Zoi.optional(),
                "sender" =>
                  Zoi.map(
                    %{
                      "id" => Zoi.string() |> Zoi.min(1),
                      "username" => Zoi.string() |> Zoi.optional(),
                      "display_name" => Zoi.string() |> Zoi.optional(),
                      "is_bot" => Zoi.boolean() |> Zoi.optional(),
                      "is_self" => Zoi.boolean() |> Zoi.optional()
                    },
                    unrecognized_keys: :error
                  )
                  |> Zoi.optional(),
                "thread_id" =>
                  Zoi.union([
                    Zoi.string() |> Zoi.min(1),
                    Zoi.null()
                  ])
                  |> Zoi.optional(),
                "reply_to_id" =>
                  Zoi.union([
                    Zoi.string() |> Zoi.min(1),
                    Zoi.null()
                  ])
                  |> Zoi.optional(),
                "media" =>
                  Zoi.array(
                    Zoi.map(
                      %{
                        "kind" => Zoi.enum(["image", "audio", "video", "file"]),
                        "resource_ref" =>
                          Zoi.map(
                            %{
                              "id" => Zoi.string() |> Zoi.min(1),
                              "scope" => Zoi.enum(["call"]),
                              "binding_id" => Zoi.string() |> Zoi.min(1),
                              "kind" => Zoi.enum(["file", "media", "stream", "card", "modal", "result"])
                            },
                            unrecognized_keys: :error
                          ),
                        "name" => Zoi.string() |> Zoi.optional(),
                        "media_type" => Zoi.string() |> Zoi.optional(),
                        "caption" => Zoi.string() |> Zoi.optional()
                      },
                      unrecognized_keys: :error
                    )
                  )
                  |> Zoi.optional(),
                "timestamp" => Zoi.string() |> Zoi.optional(),
                "status" =>
                  Zoi.enum([
                    "sending",
                    "sent",
                    "delivered",
                    "read",
                    "failed",
                    "received",
                    "pending",
                    "updated",
                    "deleted"
                  ])
                  |> Zoi.optional(),
                "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
              },
              unrecognized_keys: :error
            )
            |> Zoi.optional(),
          "message_id" => Zoi.string() |> Zoi.min(1),
          "room_id" => Zoi.string() |> Zoi.min(1),
          "thread_id" =>
            Zoi.union([
              Zoi.string() |> Zoi.min(1),
              Zoi.null()
            ])
            |> Zoi.optional(),
          "reply_to_id" =>
            Zoi.union([
              Zoi.string() |> Zoi.min(1),
              Zoi.null()
            ])
            |> Zoi.optional(),
          "sender_id" => Zoi.string() |> Zoi.min(1),
          "text" => Zoi.string() |> Zoi.optional(),
          "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional(),
          "status" =>
            Zoi.enum(["sending", "sent", "delivered", "read", "failed", "received", "pending", "updated", "deleted"])
            |> Zoi.optional(),
          "external_room_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "external_message_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "bridge_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "resource_ref" =>
            Zoi.map(
              %{
                "id" => Zoi.string() |> Zoi.min(1),
                "scope" => Zoi.enum(["call"]),
                "binding_id" => Zoi.string() |> Zoi.min(1),
                "kind" => Zoi.enum(["result"])
              },
              unrecognized_keys: :error
            )
            |> Zoi.optional()
        },
        unrecognized_keys: :error
      )
end
