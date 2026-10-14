defmodule Jido.Messaging.Signal.OperationCompleted do
  @moduledoc """
  Typed result definition for `jido.messaging.operation.completed`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room operations; absence is permitted for non-room operations.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :result,
    type: "jido.messaging.operation.completed",
    dataschema: "urn:jido:messaging:schema:operation_completed:1",
    default_source: "urn:jido:messaging:instance:aW5zdGFuY2UvYWxwaGE",
    schema:
      Zoi.union([
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.send_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.send_file"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.post_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.edit_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.delete_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.start_typing"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.fetch_metadata"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "name" => Zoi.string() |> Zoi.optional(),
                    "kind" => Zoi.enum(["direct", "group", "channel", "thread", "unknown"]) |> Zoi.optional(),
                    "topic" => Zoi.string() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.fetch_thread"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "room_id" => Zoi.string() |> Zoi.min(1),
                    "parent_message_id" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ])
                      |> Zoi.optional(),
                    "name" => Zoi.string() |> Zoi.optional(),
                    "delivery_room_ref" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ])
                      |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.fetch_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.get_user"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "username" => Zoi.string() |> Zoi.optional(),
                    "display_name" => Zoi.string() |> Zoi.optional(),
                    "is_bot" => Zoi.boolean() |> Zoi.optional(),
                    "is_self" => Zoi.boolean() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.fetch_subject"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "kind" => Zoi.enum(["conversation", "thread", "message"]),
                    "room_id" => Zoi.string() |> Zoi.min(1),
                    "title" => Zoi.string() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.get_thread_participants"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "participants" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "id" => Zoi.string() |> Zoi.min(1),
                            "username" => Zoi.string() |> Zoi.optional(),
                            "display_name" => Zoi.string() |> Zoi.optional(),
                            "is_bot" => Zoi.boolean() |> Zoi.optional(),
                            "is_self" => Zoi.boolean() |> Zoi.optional()
                          },
                          strict: true
                        )
                      ),
                    "complete" => Zoi.boolean(),
                    "scope" => Zoi.enum(["conversation", "thread", "observed"]),
                    "next_cursor" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ])
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.mark_as_read"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.fetch_media"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
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
                      strict: true
                    )
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.add_reaction"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.remove_reaction"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.post_ephemeral"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.post_channel_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.stream"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.open_modal"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
                    "opened" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.load_options"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "options" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "label" => Zoi.string(),
                            "value" => Zoi.string(),
                            "description" => Zoi.string() |> Zoi.optional(),
                            "url" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
                        )
                      ),
                    "option_groups" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "label" => Zoi.string(),
                            "options" =>
                              Zoi.array(
                                Zoi.map(
                                  %{
                                    "label" => Zoi.string(),
                                    "value" => Zoi.string(),
                                    "description" => Zoi.string() |> Zoi.optional(),
                                    "url" => Zoi.string() |> Zoi.optional()
                                  },
                                  strict: true
                                )
                              )
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "complete" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.fetch_messages"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "messages" =>
                      Zoi.array(
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
                                strict: true
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
                                        strict: true
                                      ),
                                    "name" => Zoi.string() |> Zoi.optional(),
                                    "media_type" => Zoi.string() |> Zoi.optional(),
                                    "caption" => Zoi.string() |> Zoi.optional()
                                  },
                                  strict: true
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
                          strict: true
                        )
                      ),
                    "next_cursor" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ]),
                    "complete" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.fetch_channel_messages"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "messages" =>
                      Zoi.array(
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
                                strict: true
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
                                        strict: true
                                      ),
                                    "name" => Zoi.string() |> Zoi.optional(),
                                    "media_type" => Zoi.string() |> Zoi.optional(),
                                    "caption" => Zoi.string() |> Zoi.optional()
                                  },
                                  strict: true
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
                          strict: true
                        )
                      ),
                    "next_cursor" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ]),
                    "complete" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.list_threads"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "threads" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "id" => Zoi.string() |> Zoi.min(1),
                            "room_id" => Zoi.string() |> Zoi.min(1),
                            "parent_message_id" =>
                              Zoi.union([
                                Zoi.string() |> Zoi.min(1),
                                Zoi.null()
                              ])
                              |> Zoi.optional(),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "delivery_room_ref" =>
                              Zoi.union([
                                Zoi.string() |> Zoi.min(1),
                                Zoi.null()
                              ])
                              |> Zoi.optional()
                          },
                          strict: true
                        )
                      ),
                    "next_cursor" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ]),
                    "complete" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.open_thread"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "room_id" => Zoi.string() |> Zoi.min(1),
                    "parent_message_id" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ])
                      |> Zoi.optional(),
                    "name" => Zoi.string() |> Zoi.optional(),
                    "delivery_room_ref" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ])
                      |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["provider.open_dm"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "name" => Zoi.string() |> Zoi.optional(),
                    "kind" => Zoi.enum(["direct", "group", "channel", "thread", "unknown"]) |> Zoi.optional(),
                    "topic" => Zoi.string() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["post_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
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
                  strict: true
                ),
                Zoi.map(
                  %{
                    "resource_ref" =>
                      Zoi.map(
                        %{
                          "id" => Zoi.string() |> Zoi.min(1),
                          "scope" => Zoi.enum(["call"]),
                          "binding_id" => Zoi.string() |> Zoi.min(1),
                          "kind" => Zoi.enum(["result"])
                        },
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["create_room"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "id" => Zoi.string() |> Zoi.min(1),
                  "name" => Zoi.string() |> Zoi.optional(),
                  "kind" => Zoi.enum(["direct", "group", "channel", "thread", "unknown"]) |> Zoi.optional(),
                  "topic" => Zoi.string() |> Zoi.optional()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["participant_joined"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["participant_left"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["set_presence"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["set_typing"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["add_room_reaction"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["remove_room_reaction"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["mark_delivered"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["mark_read"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.map(
                %{
                  "acknowledged" => Zoi.boolean()
                },
                strict: true
              )
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["route_outbound"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
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
                          strict: true
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
                          strict: true
                        )
                      )
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.fetch_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "timestamp" => Zoi.string() |> Zoi.optional(),
                    "status" =>
                      Zoi.enum(["sent", "received", "updated", "deleted", "pending", "failed"]) |> Zoi.optional(),
                    "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.fetch_channel_messages"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "messages" =>
                      Zoi.array(
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
                                strict: true
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
                                        strict: true
                                      ),
                                    "name" => Zoi.string() |> Zoi.optional(),
                                    "media_type" => Zoi.string() |> Zoi.optional(),
                                    "caption" => Zoi.string() |> Zoi.optional()
                                  },
                                  strict: true
                                )
                              )
                              |> Zoi.optional(),
                            "timestamp" => Zoi.string() |> Zoi.optional(),
                            "status" =>
                              Zoi.enum(["sent", "received", "updated", "deleted", "pending", "failed"])
                              |> Zoi.optional(),
                            "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
                          },
                          strict: true
                        )
                      ),
                    "next_cursor" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ]),
                    "complete" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.fetch_thread"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "room_id" => Zoi.string() |> Zoi.min(1),
                    "parent_message_id" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ])
                      |> Zoi.optional(),
                    "name" => Zoi.string() |> Zoi.optional(),
                    "delivery_room_ref" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ])
                      |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.fetch_thread_messages"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "messages" =>
                      Zoi.array(
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
                                strict: true
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
                                        strict: true
                                      ),
                                    "name" => Zoi.string() |> Zoi.optional(),
                                    "media_type" => Zoi.string() |> Zoi.optional(),
                                    "caption" => Zoi.string() |> Zoi.optional()
                                  },
                                  strict: true
                                )
                              )
                              |> Zoi.optional(),
                            "timestamp" => Zoi.string() |> Zoi.optional(),
                            "status" =>
                              Zoi.enum(["sent", "received", "updated", "deleted", "pending", "failed"])
                              |> Zoi.optional(),
                            "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
                          },
                          strict: true
                        )
                      ),
                    "next_cursor" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ]),
                    "complete" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.list_threads"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "threads" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "id" => Zoi.string() |> Zoi.min(1),
                            "room_id" => Zoi.string() |> Zoi.min(1),
                            "parent_message_id" =>
                              Zoi.union([
                                Zoi.string() |> Zoi.min(1),
                                Zoi.null()
                              ])
                              |> Zoi.optional(),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "delivery_room_ref" =>
                              Zoi.union([
                                Zoi.string() |> Zoi.min(1),
                                Zoi.null()
                              ])
                              |> Zoi.optional()
                          },
                          strict: true
                        )
                      ),
                    "next_cursor" =>
                      Zoi.union([
                        Zoi.string() |> Zoi.min(1),
                        Zoi.null()
                      ]),
                    "complete" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.lookup_participant"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "username" => Zoi.string() |> Zoi.optional(),
                    "display_name" => Zoi.string() |> Zoi.optional(),
                    "is_bot" => Zoi.boolean() |> Zoi.optional(),
                    "is_self" => Zoi.boolean() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.lookup_user"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "username" => Zoi.string() |> Zoi.optional(),
                    "display_name" => Zoi.string() |> Zoi.optional(),
                    "is_bot" => Zoi.boolean() |> Zoi.optional(),
                    "is_self" => Zoi.boolean() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.fetch_channel_metadata"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1),
                    "name" => Zoi.string() |> Zoi.optional(),
                    "kind" => Zoi.enum(["direct", "group", "channel", "thread", "unknown"]) |> Zoi.optional(),
                    "topic" => Zoi.string() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.post_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "timestamp" => Zoi.string() |> Zoi.optional(),
                    "status" =>
                      Zoi.enum(["sent", "received", "updated", "deleted", "pending", "failed"]) |> Zoi.optional(),
                    "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.post_channel_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "timestamp" => Zoi.string() |> Zoi.optional(),
                    "status" =>
                      Zoi.enum(["sent", "received", "updated", "deleted", "pending", "failed"]) |> Zoi.optional(),
                    "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.send_direct_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "timestamp" => Zoi.string() |> Zoi.optional(),
                    "status" =>
                      Zoi.enum(["sent", "received", "updated", "deleted", "pending", "failed"]) |> Zoi.optional(),
                    "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.start_typing"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.edit_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
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
                        strict: true
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
                                strict: true
                              ),
                            "name" => Zoi.string() |> Zoi.optional(),
                            "media_type" => Zoi.string() |> Zoi.optional(),
                            "caption" => Zoi.string() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "timestamp" => Zoi.string() |> Zoi.optional(),
                    "status" =>
                      Zoi.enum(["sent", "received", "updated", "deleted", "pending", "failed"]) |> Zoi.optional(),
                    "role" => Zoi.enum(["user", "assistant", "system", "tool"]) |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.delete_message"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.add_reaction"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.remove_reaction"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "acknowledged" => Zoi.boolean()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.ensure_subscription"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
                    "active" => Zoi.boolean() |> Zoi.optional(),
                    "items" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "id" => Zoi.string() |> Zoi.min(1),
                            "active" => Zoi.boolean() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "acknowledged" => Zoi.boolean() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.list_subscriptions"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
                    "active" => Zoi.boolean() |> Zoi.optional(),
                    "items" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "id" => Zoi.string() |> Zoi.min(1),
                            "active" => Zoi.boolean() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "acknowledged" => Zoi.boolean() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        ),
        Zoi.map(
          %{
            "operation" => Zoi.enum(["tool.delete_subscription"]),
            "request_id" => Zoi.string() |> Zoi.min(1),
            "bridge_id" => Zoi.string() |> Zoi.min(1),
            "result" =>
              Zoi.union([
                Zoi.map(
                  %{
                    "id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
                    "active" => Zoi.boolean() |> Zoi.optional(),
                    "items" =>
                      Zoi.array(
                        Zoi.map(
                          %{
                            "id" => Zoi.string() |> Zoi.min(1),
                            "active" => Zoi.boolean() |> Zoi.optional()
                          },
                          strict: true
                        )
                      )
                      |> Zoi.optional(),
                    "acknowledged" => Zoi.boolean() |> Zoi.optional()
                  },
                  strict: true
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
                        strict: true
                      )
                  },
                  strict: true
                )
              ])
          },
          strict: true
        )
      ])
end
