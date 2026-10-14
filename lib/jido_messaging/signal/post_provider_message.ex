defmodule Jido.Messaging.Signal.PostProviderMessage do
  @moduledoc """
  Typed command definition for `jido.messaging.command.post_provider_message`.

  Data uses the protocol version 1 string-key schema. Canonical room subject for room_id, or absent for a non-room request.
  """

  use Jido.Chat.Signal.Definition,
    owner: :messaging,
    kind: :command,
    type: "jido.messaging.command.post_provider_message",
    dataschema: "urn:jido:messaging:schema:command_post_provider_message:1",
    default_source: "urn:jido:messaging:producer:local",
    schema:
      Zoi.map(
        %{
          "request_id" => Zoi.string() |> Zoi.min(1),
          "room_id" => Zoi.string() |> Zoi.min(1),
          "content" =>
            Zoi.union([
              Zoi.map(
                %{
                  "kind" => Zoi.enum(["text", "markdown"]),
                  "text" => Zoi.string()
                },
                unrecognized_keys: :error
              ),
              Zoi.map(
                %{
                  "kind" => Zoi.enum(["card", "stream", "media"]),
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
                  "fallback_text" => Zoi.string() |> Zoi.optional(),
                  "caption" => Zoi.string() |> Zoi.optional()
                },
                unrecognized_keys: :error
              )
            ]),
          "thread_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "reply_to_id" => Zoi.string() |> Zoi.min(1) |> Zoi.optional(),
          "format" => Zoi.enum(["plain", "markdown", "html"]) |> Zoi.optional(),
          "bridge_id" => Zoi.string() |> Zoi.min(1)
        },
        unrecognized_keys: :error
      )
end
