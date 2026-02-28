defmodule Jido.Messaging.BridgePlugin do
  @moduledoc """
  Adapter bridge metadata struct.

  Represents a registered adapter bridge with its metadata, capabilities,
  and optional adapter implementations.

  ## Fields

    * `:id` - Unique atom identifier (e.g., `:telegram`, `:discord`)
    * `:adapter_module` - The module implementing `Jido.Chat.Adapter`
    * `:label` - Human-readable display name (e.g., "Telegram Adapter")
    * `:capabilities` - List of supported capabilities (e.g., `[:text, :image, :streaming]`)
    * `:adapters` - Map of adapter type to module (e.g., `%{mentions: MyMentionsAdapter}`)

  ## Example

      %BridgePlugin{
        id: :telegram,
        adapter_module: MyApp.TelegramAdapter,
        label: "Telegram Adapter",
        capabilities: [:text, :typing],
        adapters: %{}
      }
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.atom(),
              adapter_module: Zoi.module(),
              label: Zoi.string(),
              capabilities: Zoi.array(Zoi.atom()) |> Zoi.default([]),
              adapters: Zoi.map() |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for BridgePlugin"
  def schema, do: @schema

  @doc """
  Creates a new BridgePlugin from an adapter module.

  Automatically extracts capabilities from `Jido.Messaging.AdapterBridge`.

  ## Parameters

    * `adapter_module` - Module implementing `Jido.Chat.Adapter`
    * `opts` - Optional overrides:
      * `:id` - Override the channel type as the ID
      * `:label` - Override the default label
      * `:adapters` - Map of adapter type to module

  ## Examples

      BridgePlugin.from_adapter(MyApp.TelegramAdapter)
      # => %BridgePlugin{id: :telegram, label: "Telegram", ...}

      BridgePlugin.from_adapter(MyAdapter, label: "My Custom Adapter")
  """
  @spec from_adapter(module(), keyword()) :: t()
  def from_adapter(adapter_module, opts \\ []) do
    id = Keyword.get(opts, :id, Jido.Messaging.AdapterBridge.channel_type(adapter_module))
    label = Keyword.get(opts, :label, humanize_channel_type(id))
    adapters = Keyword.get(opts, :adapters, %{})

    capabilities = Jido.Messaging.AdapterBridge.capabilities(adapter_module)

    struct!(__MODULE__, %{
      id: id,
      adapter_module: adapter_module,
      label: label,
      capabilities: capabilities,
      adapters: adapters
    })
  end

  @doc """
  Checks if the plugin supports a specific capability.

  ## Examples

      BridgePlugin.has_capability?(telegram_plugin, :streaming)
      # => true
  """
  @spec has_capability?(t(), atom()) :: boolean()
  def has_capability?(%__MODULE__{capabilities: capabilities}, capability) do
    capability in capabilities
  end

  @doc """
  Gets an adapter module for a specific adapter type.

  ## Examples

      BridgePlugin.get_adapter(telegram_plugin, :mentions)
      # => MyApp.TelegramMentionsAdapter
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
