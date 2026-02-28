defmodule Jido.Messaging.BridgeManifestBootstrapTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Messaging.BridgeRegistry

  @manifest_event [:jido_messaging, :bridge_registry, :manifest, :load]
  @bootstrap_event [:jido_messaging, :bridge_registry, :bootstrap]

  defmodule TelegramChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :telegram

    @impl true
    def capabilities, do: [:text, :image, :streaming]

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule DiscordChannel do
    @behaviour Jido.Chat.Adapter

    @impl true
    def channel_type, do: :discord

    @impl true
    def capabilities, do: [:text, :reactions]

    @impl true
    def transform_incoming(_raw), do: {:error, :not_implemented}

    @impl true
    def send_message(_room_id, _text, _opts), do: {:error, :not_implemented}
  end

  defmodule BootstrapMessaging do
    use Jido.Messaging, persistence: Jido.Messaging.Persistence.ETS
  end

  setup do
    BridgeRegistry.clear()
    :ok
  end

  describe "bootstrap_from_manifests/1" do
    test "registers valid manifests with deterministic precedence" do
      manifest_dir = create_manifest_dir()

      discord_manifest_path =
        write_manifest(manifest_dir, "01_discord.json", %{
          "manifest_version" => 1,
          "id" => "discord",
          "adapter_module" => Atom.to_string(DiscordChannel),
          "label" => "Discord"
        })

      telegram_manifest_path =
        write_manifest(manifest_dir, "02_telegram.json", %{
          "manifest_version" => 1,
          "id" => "telegram",
          "adapter_module" => Atom.to_string(TelegramChannel),
          "label" => "Telegram Base"
        })

      telegram_override_path =
        write_manifest(manifest_dir, "03_telegram_override.json", %{
          "manifest_version" => 1,
          "id" => "telegram",
          "adapter_module" => Atom.to_string(TelegramChannel),
          "label" => "Telegram Override"
        })

      assert {:ok, result} =
               BridgeRegistry.bootstrap_from_manifests(
                 manifest_paths: [discord_manifest_path, telegram_manifest_path, telegram_override_path],
                 collision_policy: :prefer_last,
                 clear_existing?: true
               )

      assert result.registered_bridge_ids == [:discord, :telegram]
      assert length(result.degraded_diagnostics) == 0
      assert length(result.collision_diagnostics) == 1

      assert [%{bridge_id: :telegram, policy: :prefer_last, winning_path: ^telegram_override_path}] =
               result.collision_diagnostics

      assert BridgeRegistry.get_bridge(:telegram).label == "Telegram Override"
      assert BridgeRegistry.get_bridge(:discord).label == "Discord"
    end

    test "fails fast with typed diagnostics for malformed required plugin manifests" do
      manifest_dir = create_manifest_dir()

      malformed_required_manifest =
        write_manifest(manifest_dir, "telegram_required.json", %{
          "manifest_version" => 1,
          "id" => "telegram",
          "adapter_module" => "No.Such.Adapter.Module",
          "label" => "Broken Telegram"
        })

      assert {:error, {:fatal_required_bridge_error, diagnostic}} =
               BridgeRegistry.bootstrap_from_manifests(
                 manifest_paths: [malformed_required_manifest],
                 required_bridges: [:telegram],
                 clear_existing?: true
               )

      assert diagnostic.policy == :fatal_required_bridge_error
      assert diagnostic.type == :unknown_adapter_module
      assert diagnostic.bridge_id == :telegram
      assert diagnostic.path == malformed_required_manifest
      assert BridgeRegistry.list_bridges() == []
    end

    test "degrades optional malformed manifests with warning and telemetry" do
      manifest_dir = create_manifest_dir()

      valid_discord_manifest =
        write_manifest(manifest_dir, "discord_valid.json", %{
          "manifest_version" => 1,
          "id" => "discord",
          "adapter_module" => Atom.to_string(DiscordChannel),
          "label" => "Discord"
        })

      malformed_optional_manifest =
        write_invalid_manifest(manifest_dir, "optional_invalid.json", ~s({"manifest_version":1,))

      handler_id = "bridge-manifest-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [@manifest_event, @bootstrap_event],
          fn event, measurements, metadata, pid ->
            send(pid, {:bridge_manifest_telemetry, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      warning_log =
        capture_log(fn ->
          assert {:ok, result} =
                   BridgeRegistry.bootstrap_from_manifests(
                     manifest_paths: [valid_discord_manifest, malformed_optional_manifest],
                     collision_policy: :prefer_last,
                     clear_existing?: true
                   )

          assert result.registered_bridge_ids == [:discord]

          assert [%{policy: :degraded_optional_bridge_error, path: ^malformed_optional_manifest}] =
                   result.degraded_diagnostics
        end)

      assert warning_log =~ "Optional bridge manifest degraded"
      assert BridgeRegistry.get_bridge(:discord).label == "Discord"
      assert BridgeRegistry.get_bridge(:telegram) == nil

      assert_receive {:bridge_manifest_telemetry, @manifest_event, %{count: 1},
                      %{policy: :degraded_optional_bridge_error, path: ^malformed_optional_manifest}}
    end

    test "supports deterministic prefer_first collision policy" do
      manifest_dir = create_manifest_dir()

      first_manifest =
        write_manifest(manifest_dir, "01_telegram_first.json", %{
          "manifest_version" => 1,
          "id" => "telegram",
          "adapter_module" => Atom.to_string(TelegramChannel),
          "label" => "First Label"
        })

      second_manifest =
        write_manifest(manifest_dir, "02_telegram_second.json", %{
          "manifest_version" => 1,
          "id" => "telegram",
          "adapter_module" => Atom.to_string(TelegramChannel),
          "label" => "Second Label"
        })

      assert {:ok, result} =
               BridgeRegistry.bootstrap_from_manifests(
                 manifest_paths: [first_manifest, second_manifest],
                 collision_policy: :prefer_first,
                 clear_existing?: true
               )

      assert result.registered_bridge_ids == [:telegram]
      assert BridgeRegistry.get_bridge(:telegram).label == "First Label"

      assert [%{policy: :prefer_first, winning_path: ^first_manifest, discarded_path: ^second_manifest}] =
               result.collision_diagnostics
    end

    test "startup bootstrap fails fast when required plugin manifests are invalid" do
      manifest_dir = create_manifest_dir()

      original_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, original_trap_exit) end)

      malformed_required_manifest =
        write_manifest(manifest_dir, "required_invalid.json", %{
          "manifest_version" => 1,
          "id" => "telegram",
          "adapter_module" => "No.Such.Adapter.Module",
          "label" => "Broken Required BridgePlugin"
        })

      assert {:error, reason} =
               BootstrapMessaging.start_link(
                 bridge_manifest_paths: [malformed_required_manifest],
                 required_bridges: [:telegram],
                 bridge_collision_policy: :prefer_last
               )

      assert fatal_required_bridge_startup_failure?(reason)
    end
  end

  defp create_manifest_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "jido-bridge-manifests-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp write_manifest(dir, file_name, manifest) do
    manifest_path = Path.join(dir, file_name)
    File.write!(manifest_path, Jason.encode!(manifest))
    manifest_path
  end

  defp write_invalid_manifest(dir, file_name, contents) do
    manifest_path = Path.join(dir, file_name)
    File.write!(manifest_path, contents)
    manifest_path
  end

  defp fatal_required_bridge_startup_failure?(
         {:shutdown, {:failed_to_start_child, _child, {:fatal_required_bridge_error, _diagnostic}}}
       ),
       do: true

  defp fatal_required_bridge_startup_failure?(
         {:failed_to_start_child, _child, {:fatal_required_bridge_error, _diagnostic}}
       ),
       do: true

  defp fatal_required_bridge_startup_failure?({:bad_return, {:stop, {:fatal_required_bridge_error, _diagnostic}}}),
    do: true

  defp fatal_required_bridge_startup_failure?(
         {:bad_return, {_module, :init, {:stop, {:fatal_required_bridge_error, _diagnostic}}}}
       ),
       do: true

  defp fatal_required_bridge_startup_failure?(_reason), do: false
end
