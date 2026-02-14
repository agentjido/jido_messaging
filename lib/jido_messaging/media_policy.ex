defmodule JidoMessaging.MediaPolicy do
  @moduledoc """
  Deterministic media normalization and bounded policy checks.

  This module is used by ingest and outbound media paths to:

  - normalize media payloads into canonical content structs
  - enforce bounded type/size/count limits
  - apply deterministic unsupported-media fallback/reject behavior
  """

  alias JidoMessaging.Capabilities
  alias JidoMessaging.Content.{Audio, File, Image, Video}

  @supported_kinds [:image, :audio, :video, :file]

  @default_max_items 4
  @default_max_item_bytes 10_000_000
  @default_max_total_bytes 20_000_000
  @default_unsupported_policy :reject
  @default_on_policy_violation :reject
  @default_fallback_text "[media omitted]"

  @typedoc "Supported canonical media kinds."
  @type media_kind :: :image | :audio | :video | :file

  @typedoc "Outbound unsupported-media policy."
  @type unsupported_policy :: :reject | :fallback_text

  @typedoc "Inbound/outbound policy result metadata."
  @type metadata :: %{
          required(:accepted) => [map()],
          required(:rejected) => [map()],
          required(:count) => non_neg_integer(),
          required(:total_bytes) => non_neg_integer(),
          required(:policy) => map()
        }

  @doc """
  Resolves effective media policy config.

  Config precedence:

  1. defaults
  2. `config :jido_messaging, :media_policy, ...`
  3. runtime overrides (keyword/map)
  """
  @spec config(keyword() | map()) :: keyword()
  def config(overrides \\ []) do
    defaults = [
      max_items: @default_max_items,
      max_item_bytes: @default_max_item_bytes,
      max_total_bytes: @default_max_total_bytes,
      allow: @supported_kinds,
      unsupported_policy: @default_unsupported_policy,
      on_policy_violation: @default_on_policy_violation,
      fallback_text: @default_fallback_text
    ]

    defaults
    |> Keyword.merge(normalize_opts(Application.get_env(:jido_messaging, :media_policy, [])))
    |> Keyword.merge(normalize_opts(overrides))
    |> sanitize_config()
  end

  @doc """
  Normalizes inbound media list into canonical content blocks.

  Returns either:

  - `{:ok, content_blocks, metadata}`
  - `{:error, {:media_policy_denied, reason}, metadata}`
  """
  @spec normalize_inbound(term(), keyword() | map()) ::
          {:ok, [struct()], metadata()}
          | {:error, {:media_policy_denied, atom()}, metadata()}
  def normalize_inbound(media_payload, opts \\ []) do
    cfg = config(opts)
    entries = media_payload |> normalize_media_list() |> Enum.with_index()

    {accepted_entries, accepted_meta, rejected_meta, total_bytes} =
      Enum.reduce(entries, {[], [], [], 0}, fn {raw_entry, idx}, {accepted, accepted_info, rejected, running_total} ->
        case normalize_media_entry(raw_entry) do
          {:ok, entry} ->
            evaluate_entry(entry, idx, running_total, cfg, accepted, accepted_info, rejected)

          {:error, reason} ->
            rejected_entry = %{index: idx, reason: reason}
            {accepted, accepted_info, [rejected_entry | rejected], running_total}
        end
      end)

    metadata =
      %{
        accepted: Enum.reverse(accepted_meta),
        rejected: Enum.reverse(rejected_meta),
        count: length(accepted_entries),
        total_bytes: total_bytes,
        policy: metadata_policy(cfg)
      }

    content = accepted_entries |> Enum.reverse() |> Enum.map(&to_content_block/1)
    has_rejections? = metadata.rejected != []

    case {has_rejections?, cfg[:on_policy_violation]} do
      {true, :reject} ->
        first_reason = metadata.rejected |> List.first() |> Map.fetch!(:reason)
        {:error, {:media_policy_denied, first_reason}, metadata}

      _ ->
        {:ok, content, metadata}
    end
  end

  @doc """
  Preflights outbound media payload for policy/capability/callback checks.

  Returns one of:

  - `{:ok, media_payload, metadata}` - send/edit media via channel media callback
  - `{:fallback_text, text, metadata}` - deterministic text fallback path
  - `{:error, reason, metadata}` - deterministic reject path
  """
  @spec prepare_outbound(map(), module(), :send_media | :edit_media, keyword() | map()) ::
          {:ok, map(), metadata()}
          | {:fallback_text, String.t(), metadata()}
          | {:error, term(), metadata()}
  def prepare_outbound(media_payload, channel_module, operation, opts \\ [])
      when is_map(media_payload) and is_atom(channel_module) and operation in [:send_media, :edit_media] do
    cfg = config(opts)

    with {:ok, entry} <- normalize_media_entry(media_payload),
         {:ok, _entry, size_bytes} <- validate_entry(entry, 0, 0, cfg) do
      causes = unsupported_causes(channel_module, entry.kind, operation)

      if causes == [] do
        metadata = success_metadata(entry, size_bytes, cfg)
        {:ok, to_outbound_media_payload(entry), metadata}
      else
        metadata = reject_metadata(entry.kind, causes, cfg)
        maybe_fallback_text(media_payload, channel_module, metadata, cfg, entry.kind, causes)
      end
    else
      {:error, reason} ->
        metadata = reject_metadata(media_kind(media_payload), [reason], cfg)

        if policy_reason?(reason) do
          {:error, {:media_policy_denied, reason}, metadata}
        else
          {:error, reason, metadata}
        end
    end
  end

  defp evaluate_entry(entry, idx, running_total, cfg, accepted, accepted_info, rejected) do
    case validate_entry(entry, idx, running_total, cfg) do
      {:ok, validated, size_bytes} ->
        accepted_entry_meta = accepted_entry_metadata(validated, size_bytes)

        {
          [validated | accepted],
          [accepted_entry_meta | accepted_info],
          rejected,
          running_total + size_bytes
        }

      {:error, reason} ->
        rejected_entry = %{index: idx, reason: reason, kind: entry.kind}
        {accepted, accepted_info, [rejected_entry | rejected], running_total}
    end
  end

  defp validate_entry(entry, idx, running_total, cfg) do
    size_bytes = payload_size_bytes(entry)

    cond do
      idx >= cfg[:max_items] ->
        {:error, :max_items_exceeded}

      entry.kind not in cfg[:allow] ->
        {:error, :unsupported_kind}

      is_nil(entry.url) and is_nil(entry.data) ->
        {:error, :missing_payload}

      invalid_media_type?(entry.kind, entry.media_type) ->
        {:error, :invalid_media_type}

      size_bytes > cfg[:max_item_bytes] ->
        {:error, :max_item_bytes_exceeded}

      running_total + size_bytes > cfg[:max_total_bytes] ->
        {:error, :max_total_bytes_exceeded}

      true ->
        {:ok, entry, size_bytes}
    end
  end

  defp maybe_fallback_text(media_payload, channel_module, metadata, cfg, kind, causes) do
    policy = cfg[:unsupported_policy]
    channel_caps = Capabilities.channel_capabilities(channel_module)
    fallback_text = media_payload[:fallback_text] || media_payload["fallback_text"] || cfg[:fallback_text]

    cond do
      policy != :fallback_text ->
        {:error, {:unsupported_media, kind, causes}, metadata}

      :text not in channel_caps ->
        {:error, {:unsupported_media, kind, Enum.uniq(causes ++ [:missing_text_capability])}, metadata}

      not (is_binary(fallback_text) and String.trim(fallback_text) != "") ->
        {:error, {:unsupported_media, kind, Enum.uniq(causes ++ [:missing_fallback_text])}, metadata}

      true ->
        fallback_metadata =
          metadata
          |> Map.put(:fallback, true)
          |> Map.put(:fallback_policy, :fallback_text)
          |> Map.put(:fallback_reason, :unsupported_media)

        {:fallback_text, fallback_text, fallback_metadata}
    end
  end

  defp success_metadata(entry, size_bytes, cfg) do
    %{
      accepted: [accepted_entry_metadata(entry, size_bytes)],
      rejected: [],
      count: 1,
      total_bytes: size_bytes,
      policy: metadata_policy(cfg),
      fallback: false
    }
  end

  defp reject_metadata(kind, causes, cfg) do
    %{
      accepted: [],
      rejected: [%{index: 0, reason: List.first(causes), kind: kind, causes: causes}],
      count: 0,
      total_bytes: 0,
      policy: metadata_policy(cfg),
      fallback: false
    }
  end

  defp metadata_policy(cfg) do
    %{
      max_items: cfg[:max_items],
      max_item_bytes: cfg[:max_item_bytes],
      max_total_bytes: cfg[:max_total_bytes],
      allow: cfg[:allow],
      unsupported_policy: cfg[:unsupported_policy],
      on_policy_violation: cfg[:on_policy_violation]
    }
  end

  defp normalize_media_entry(entry) when is_map(entry) do
    kind = media_kind(entry)

    normalized = %{
      kind: kind,
      url: fetch_string(entry, [:url, :uri, :file_url]),
      data: fetch_string(entry, [:data, :base64]),
      media_type: fetch_string(entry, [:media_type, :mime_type, :mimetype]),
      filename: fetch_string(entry, [:filename, :name]),
      size_bytes: fetch_integer(entry, [:size_bytes, :size, :file_size, :filesize]),
      duration: fetch_integer(entry, [:duration, :duration_seconds]),
      width: fetch_integer(entry, [:width]),
      height: fetch_integer(entry, [:height]),
      thumbnail_url: fetch_string(entry, [:thumbnail_url, :thumb_url]),
      alt_text: fetch_string(entry, [:alt_text, :caption, :description]),
      transcript: fetch_string(entry, [:transcript, :caption])
    }

    if kind in @supported_kinds do
      {:ok, normalized}
    else
      {:error, :unsupported_kind}
    end
  end

  defp normalize_media_entry(_), do: {:error, :invalid_media_payload}

  defp to_content_block(%{kind: :image} = media) do
    %Image{
      url: media.url,
      data: media.data,
      media_type: media.media_type,
      alt_text: media.alt_text,
      width: media.width,
      height: media.height
    }
  end

  defp to_content_block(%{kind: :audio} = media) do
    %Audio{
      url: media.url,
      data: media.data,
      media_type: media.media_type,
      duration: media.duration,
      transcript: media.transcript
    }
  end

  defp to_content_block(%{kind: :video} = media) do
    %Video{
      url: media.url,
      data: media.data,
      media_type: media.media_type,
      duration: media.duration,
      width: media.width,
      height: media.height,
      thumbnail_url: media.thumbnail_url
    }
  end

  defp to_content_block(%{kind: :file} = media) do
    %File{
      url: media.url,
      data: media.data,
      filename: media.filename,
      media_type: media.media_type,
      size: payload_size_bytes(media)
    }
  end

  defp to_outbound_media_payload(media) do
    media
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp accepted_entry_metadata(entry, size_bytes) do
    %{
      kind: entry.kind,
      media_type: entry.media_type,
      size_bytes: size_bytes,
      has_data: not is_nil(entry.data),
      has_url: not is_nil(entry.url)
    }
  end

  defp payload_size_bytes(media) do
    cond do
      is_integer(media.size_bytes) and media.size_bytes >= 0 ->
        media.size_bytes

      is_binary(media.data) ->
        byte_size(media.data)

      true ->
        0
    end
  end

  defp invalid_media_type?(_kind, nil), do: false
  defp invalid_media_type?(_kind, ""), do: false
  defp invalid_media_type?(:image, media_type), do: not String.starts_with?(media_type, "image/")
  defp invalid_media_type?(:audio, media_type), do: not String.starts_with?(media_type, "audio/")
  defp invalid_media_type?(:video, media_type), do: not String.starts_with?(media_type, "video/")
  defp invalid_media_type?(:file, _media_type), do: false

  defp normalize_media_list(payload) when is_list(payload), do: payload
  defp normalize_media_list(payload) when is_map(payload), do: [payload]
  defp normalize_media_list(_payload), do: []

  defp media_kind(payload) when is_map(payload) do
    payload
    |> fetch_kind([:kind, :type])
    |> normalize_kind()
  end

  defp media_kind(_payload), do: nil

  defp fetch_kind(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp normalize_kind(kind) when kind in @supported_kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "image" -> :image
      "audio" -> :audio
      "video" -> :video
      "file" -> :file
      _ -> nil
    end
  end

  defp normalize_kind(_), do: nil

  defp fetch_string(map, keys) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) || Map.get(map, to_string(key)) end)
    |> normalize_string()
  end

  defp fetch_integer(map, keys) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) || Map.get(map, to_string(key)) end)
    |> normalize_integer()
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp normalize_integer(value) when is_integer(value) and value >= 0, do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_opts(opts) when is_list(opts), do: opts
  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_opts(_opts), do: []

  defp sanitize_config(config) do
    config
    |> Keyword.update(:max_items, @default_max_items, &sanitize_positive_integer(&1, @default_max_items))
    |> Keyword.update(:max_item_bytes, @default_max_item_bytes, fn value ->
      sanitize_positive_integer(value, @default_max_item_bytes)
    end)
    |> Keyword.update(:max_total_bytes, @default_max_total_bytes, fn value ->
      sanitize_positive_integer(value, @default_max_total_bytes)
    end)
    |> Keyword.update(:allow, @supported_kinds, &sanitize_allow/1)
    |> Keyword.update(:unsupported_policy, @default_unsupported_policy, &sanitize_unsupported_policy/1)
    |> Keyword.update(:on_policy_violation, @default_on_policy_violation, &sanitize_on_policy_violation/1)
    |> Keyword.update(:fallback_text, @default_fallback_text, &sanitize_fallback_text/1)
  end

  defp sanitize_positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp sanitize_positive_integer(_value, fallback), do: fallback

  defp sanitize_allow(allow) when is_list(allow) do
    allow
    |> Enum.map(&normalize_kind/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> @supported_kinds
      normalized -> normalized
    end
  end

  defp sanitize_allow(_), do: @supported_kinds

  defp sanitize_unsupported_policy(:reject), do: :reject
  defp sanitize_unsupported_policy(:fallback_text), do: :fallback_text
  defp sanitize_unsupported_policy(_), do: @default_unsupported_policy

  defp sanitize_on_policy_violation(:reject), do: :reject
  defp sanitize_on_policy_violation(:drop), do: :drop
  defp sanitize_on_policy_violation(_), do: @default_on_policy_violation

  defp sanitize_fallback_text(value) when is_binary(value) and value != "", do: value
  defp sanitize_fallback_text(_), do: @default_fallback_text

  defp unsupported_causes(channel_module, kind, operation) do
    channel_caps = Capabilities.channel_capabilities(channel_module)
    causes = []

    causes =
      if kind in channel_caps do
        causes
      else
        [:missing_capability | causes]
      end

    callback_cause =
      case operation do
        :send_media ->
          if function_exported?(channel_module, :send_media, 3), do: nil, else: :missing_send_media_callback

        :edit_media ->
          if function_exported?(channel_module, :edit_media, 4), do: nil, else: :missing_edit_media_callback
      end

    causes =
      if is_nil(callback_cause) do
        causes
      else
        [callback_cause | causes]
      end

    causes |> Enum.reverse() |> Enum.uniq()
  end

  defp policy_reason?(reason) do
    reason in [
      :unsupported_kind,
      :missing_payload,
      :invalid_media_type,
      :max_item_bytes_exceeded,
      :max_total_bytes_exceeded,
      :max_items_exceeded,
      :invalid_media_payload
    ]
  end
end
