defmodule JidoMessaging.Plugin do
  @moduledoc """
  Channel plugin metadata struct.

  Represents a registered channel plugin with its metadata, capabilities,
  and optional adapter implementations.

  ## Fields

    * `:id` - Unique atom identifier (e.g., `:telegram`, `:discord`)
    * `:channel_module` - The module implementing `JidoMessaging.Channel`
    * `:label` - Human-readable display name (e.g., "Telegram")
    * `:capabilities` - List of supported capabilities (e.g., `[:text, :image, :streaming]`)
    * `:adapters` - Map of adapter type to module (e.g., `%{mentions: MyMentionsAdapter}`)

  ## Example

      %Plugin{
        id: :telegram,
        channel_module: JidoMessaging.Channels.Telegram,
        label: "Telegram",
        capabilities: [:text, :image, :streaming],
        adapters: %{
          mentions: JidoMessaging.Channels.Telegram.Mentions,
          threading: JidoMessaging.Channels.Telegram.Threading
        }
      }
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.atom(),
              channel_module: Zoi.module(),
              label: Zoi.string(),
              capabilities: Zoi.array(Zoi.atom()) |> Zoi.default([]),
              adapters: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for Plugin"
  def schema, do: @schema

  @doc """
  Creates a new Plugin from a channel module.

  Automatically extracts capabilities if the channel implements the callback.

  ## Parameters

    * `channel_module` - Module implementing `JidoMessaging.Channel`
    * `opts` - Optional overrides:
      * `:id` - Override the channel type as the ID
      * `:label` - Override the default label
      * `:adapters` - Map of adapter type to module

  ## Examples

      Plugin.from_channel(JidoMessaging.Channels.Telegram)
      # => %Plugin{id: :telegram, label: "Telegram", ...}

      Plugin.from_channel(MyChannel, label: "My Custom Channel", adapters: %{mentions: MyMentions})
  """
  @spec from_channel(module(), keyword()) :: t()
  def from_channel(channel_module, opts \\ []) do
    id = Keyword.get(opts, :id, channel_module.channel_type())
    label = Keyword.get(opts, :label, humanize_channel_type(id))
    adapters = Keyword.get(opts, :adapters, %{})

    capabilities =
      if function_exported?(channel_module, :capabilities, 0) do
        channel_module.capabilities()
      else
        [:text]
      end

    struct!(__MODULE__, %{
      id: id,
      channel_module: channel_module,
      label: label,
      capabilities: capabilities,
      adapters: adapters
    })
  end

  @doc """
  Checks if the plugin supports a specific capability.

  ## Examples

      Plugin.has_capability?(telegram_plugin, :streaming)
      # => true
  """
  @spec has_capability?(t(), atom()) :: boolean()
  def has_capability?(%__MODULE__{capabilities: capabilities}, capability) do
    capability in capabilities
  end

  @doc """
  Gets an adapter module for a specific adapter type.

  ## Examples

      Plugin.get_adapter(telegram_plugin, :mentions)
      # => JidoMessaging.Channels.Telegram.Mentions
  """
  @spec get_adapter(t(), atom()) :: module() | nil
  def get_adapter(%__MODULE__{adapters: adapters}, adapter_type) do
    Map.get(adapters, adapter_type)
  end

  defp humanize_channel_type(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
