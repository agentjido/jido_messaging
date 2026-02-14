defmodule JidoMessaging.Channels.WhatsAppTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Channels.WhatsApp

  describe "channel_type/0" do
    test "returns :whatsapp" do
      assert WhatsApp.channel_type() == :whatsapp
    end
  end

  describe "transform_incoming/1 with full webhook payload (string keys)" do
    test "transforms webhook payload with text message" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.HBgLMTU1NTEyMzQ1NjcVAgASGBQzQTRCNUY",
                      "timestamp" => "1706745600",
                      "type" => "text",
                      "text" => %{"body" => "Hello bot!"}
                    }
                  ],
                  "contacts" => [
                    %{
                      "profile" => %{"name" => "John Doe"},
                      "wa_id" => "15551234567"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.external_room_id == "15551234567"
      assert incoming.external_user_id == "15551234567"
      assert incoming.text == "Hello bot!"
      assert incoming.username == nil
      assert incoming.display_name == "John Doe"
      assert incoming.external_message_id == "wamid.HBgLMTU1NTEyMzQ1NjcVAgASGBQzQTRCNUY"
      assert incoming.timestamp == "1706745600"
      assert incoming.chat_type == :private
      assert incoming.chat_title == nil
    end

    test "transforms webhook payload without explicit type field" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15559876543",
                      "id" => "wamid.ABC123",
                      "timestamp" => "1706745601",
                      "text" => %{"body" => "Message without type"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.text == "Message without type"
      assert incoming.display_name == nil
    end

    test "handles webhook payload without contacts" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.XYZ",
                      "timestamp" => "1706745602",
                      "type" => "text",
                      "text" => %{"body" => "No contact info"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.display_name == nil
      assert incoming.text == "No contact info"
    end

    test "handles non-text message type" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.IMAGE",
                      "timestamp" => "1706745603",
                      "type" => "image",
                      "image" => %{"id" => "img123"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.text == nil
      assert incoming.external_message_id == "wamid.IMAGE"
      assert [%{kind: :image, url: "whatsapp://media/img123"}] = incoming.media
    end
  end

  describe "transform_incoming/1 with full webhook payload (atom keys)" do
    test "transforms struct-style webhook payload with text message" do
      payload = %{
        entry: [
          %{
            changes: [
              %{
                value: %{
                  messages: [
                    %{
                      from: "15551234567",
                      id: "wamid.STRUCT123",
                      timestamp: "1706745610",
                      type: "text",
                      text: %{body: "Hello from struct!"}
                    }
                  ],
                  contacts: [
                    %{
                      profile: %{name: "Jane Doe"},
                      wa_id: "15551234567"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.external_room_id == "15551234567"
      assert incoming.external_user_id == "15551234567"
      assert incoming.text == "Hello from struct!"
      assert incoming.username == nil
      assert incoming.display_name == "Jane Doe"
      assert incoming.external_message_id == "wamid.STRUCT123"
      assert incoming.timestamp == "1706745610"
      assert incoming.chat_type == :private
      assert incoming.chat_title == nil
    end

    test "handles struct payload without contacts" do
      payload = %{
        entry: [
          %{
            changes: [
              %{
                value: %{
                  messages: [
                    %{
                      from: "15559876543",
                      id: "wamid.NOCONTACT",
                      timestamp: "1706745611",
                      text: %{body: "Struct no contact"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.display_name == nil
      assert incoming.text == "Struct no contact"
    end

    test "handles struct payload with non-text message" do
      payload = %{
        entry: [
          %{
            changes: [
              %{
                value: %{
                  messages: [
                    %{
                      from: "15551234567",
                      id: "wamid.AUDIO",
                      timestamp: "1706745612",
                      type: "audio",
                      audio: %{id: "audio123"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.text == nil
      assert [%{kind: :audio, url: "whatsapp://media/audio123"}] = incoming.media
    end
  end

  describe "transform_incoming/1 with direct message format (string keys)" do
    test "transforms direct message with text" do
      message = %{
        "from" => "15551234567",
        "id" => "wamid.DIRECT123",
        "timestamp" => "1706745620",
        "type" => "text",
        "text" => %{"body" => "Direct message"}
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(message)
      assert incoming.external_room_id == "15551234567"
      assert incoming.external_user_id == "15551234567"
      assert incoming.text == "Direct message"
      assert incoming.username == nil
      assert incoming.display_name == nil
      assert incoming.external_message_id == "wamid.DIRECT123"
      assert incoming.timestamp == "1706745620"
      assert incoming.chat_type == :private
      assert incoming.chat_title == nil
    end

    test "transforms direct message without type field" do
      message = %{
        "from" => "15559876543",
        "id" => "wamid.NOTYPE",
        "timestamp" => "1706745621",
        "text" => %{"body" => "No type field"}
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(message)
      assert incoming.text == "No type field"
    end

    test "handles direct message without text content" do
      message = %{
        "from" => "15551234567",
        "id" => "wamid.NOTEXT",
        "timestamp" => "1706745622",
        "type" => "location",
        "location" => %{"latitude" => 40.7128, "longitude" => -74.006}
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(message)
      assert incoming.text == nil
      assert incoming.external_room_id == "15551234567"
    end
  end

  describe "transform_incoming/1 with direct message format (atom keys)" do
    test "transforms struct direct message with text" do
      message = %{
        from: "15551234567",
        id: "wamid.STRUCTDIRECT",
        timestamp: "1706745630",
        type: "text",
        text: %{body: "Struct direct message"}
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(message)
      assert incoming.external_room_id == "15551234567"
      assert incoming.external_user_id == "15551234567"
      assert incoming.text == "Struct direct message"
      assert incoming.username == nil
      assert incoming.display_name == nil
      assert incoming.external_message_id == "wamid.STRUCTDIRECT"
      assert incoming.timestamp == "1706745630"
      assert incoming.chat_type == :private
    end

    test "transforms struct direct message without type field" do
      message = %{
        from: "15559876543",
        id: "wamid.STRUCTNOTYPE",
        timestamp: "1706745631",
        text: %{body: "Struct no type"}
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(message)
      assert incoming.text == "Struct no type"
    end

    test "handles struct direct message without text" do
      message = %{
        from: "15551234567",
        id: "wamid.STRUCTNOTEXT",
        timestamp: "1706745632",
        type: "sticker"
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(message)
      assert incoming.text == nil
    end
  end

  describe "transform_incoming/1 error cases" do
    test "returns error for unsupported payload format" do
      assert {:error, :unsupported_webhook_payload} = WhatsApp.transform_incoming("invalid")
    end

    test "returns error for empty map" do
      assert {:error, :unsupported_webhook_payload} = WhatsApp.transform_incoming(%{})
    end

    test "returns error for map without recognized keys" do
      assert {:error, :unsupported_webhook_payload} =
               WhatsApp.transform_incoming(%{"unknown" => "data"})
    end

    test "returns error for nil input" do
      assert {:error, :unsupported_webhook_payload} = WhatsApp.transform_incoming(nil)
    end

    test "returns error for list input" do
      assert {:error, :unsupported_webhook_payload} = WhatsApp.transform_incoming([])
    end

    test "returns error for entry without changes" do
      payload = %{"entry" => [%{"id" => "123"}]}
      assert {:error, :unsupported_webhook_payload} = WhatsApp.transform_incoming(payload)
    end

    test "returns error for changes without value" do
      payload = %{"entry" => [%{"changes" => [%{"field" => "messages"}]}]}
      assert {:error, :unsupported_webhook_payload} = WhatsApp.transform_incoming(payload)
    end

    test "returns error for value without messages" do
      payload = %{"entry" => [%{"changes" => [%{"value" => %{"statuses" => []}}]}]}
      assert {:error, :unsupported_webhook_payload} = WhatsApp.transform_incoming(payload)
    end
  end

  describe "contact name extraction" do
    test "extracts name from contact with profile" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.CONTACT1",
                      "timestamp" => "1706745640",
                      "type" => "text",
                      "text" => %{"body" => "Test"}
                    }
                  ],
                  "contacts" => [
                    %{
                      "profile" => %{"name" => "Contact Name"},
                      "wa_id" => "15551234567"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.display_name == "Contact Name"
    end

    test "returns nil when contact has no profile" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.NOPROFILE",
                      "timestamp" => "1706745641",
                      "type" => "text",
                      "text" => %{"body" => "Test"}
                    }
                  ],
                  "contacts" => [
                    %{"wa_id" => "15551234567"}
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.display_name == nil
    end

    test "extracts name from struct contact with profile" do
      payload = %{
        entry: [
          %{
            changes: [
              %{
                value: %{
                  messages: [
                    %{
                      from: "15551234567",
                      id: "wamid.STRUCTCONTACT",
                      timestamp: "1706745642",
                      type: "text",
                      text: %{body: "Test"}
                    }
                  ],
                  contacts: [
                    %{
                      profile: %{name: "Struct Contact"},
                      wa_id: "15551234567"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.display_name == "Struct Contact"
    end
  end

  describe "text content extraction" do
    test "extracts text from message with type field" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.TYPED",
                      "timestamp" => "1706745650",
                      "type" => "text",
                      "text" => %{"body" => "Typed text message"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.text == "Typed text message"
    end

    test "extracts text from message without type field" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.UNTYPED",
                      "timestamp" => "1706745651",
                      "text" => %{"body" => "Untyped text message"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.text == "Untyped text message"
    end

    test "returns nil for non-text message types" do
      for type <- ["image", "audio", "video", "document", "sticker", "location"] do
        payload = %{
          "entry" => [
            %{
              "changes" => [
                %{
                  "value" => %{
                    "messages" => [
                      %{
                        "from" => "15551234567",
                        "id" => "wamid.#{type}",
                        "timestamp" => "1706745652",
                        "type" => type
                      }
                    ]
                  }
                }
              ]
            }
          ]
        }

        assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
        assert incoming.text == nil, "Expected nil text for message type: #{type}"
      end
    end
  end

  describe "multiple messages in payload" do
    test "processes only the first message when multiple are present" do
      payload = %{
        "entry" => [
          %{
            "changes" => [
              %{
                "value" => %{
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "id" => "wamid.FIRST",
                      "timestamp" => "1706745660",
                      "type" => "text",
                      "text" => %{"body" => "First message"}
                    },
                    %{
                      "from" => "15559876543",
                      "id" => "wamid.SECOND",
                      "timestamp" => "1706745661",
                      "type" => "text",
                      "text" => %{"body" => "Second message"}
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      assert {:ok, incoming} = WhatsApp.transform_incoming(payload)
      assert incoming.external_message_id == "wamid.FIRST"
      assert incoming.text == "First message"
    end
  end
end
