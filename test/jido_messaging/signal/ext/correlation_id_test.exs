defmodule JidoMessaging.Signal.Ext.CorrelationIdTest do
  use ExUnit.Case, async: true

  alias JidoMessaging.Signal.Ext.CorrelationId

  setup_all do
    # Ensure the extension is registered before tests run
    CorrelationId.ensure_registered()
    :ok
  end

  describe "namespace/0" do
    test "returns correlationid" do
      assert CorrelationId.namespace() == "correlationid"
    end
  end

  describe "schema/0" do
    test "defines id as required string" do
      schema = CorrelationId.schema()
      assert Keyword.has_key?(schema, :id)
      assert schema[:id][:type] == :string
      assert schema[:id][:required] == true
    end
  end

  describe "validate_data/1" do
    test "validates data with id" do
      assert {:ok, %{id: "corr_123"}} = CorrelationId.validate_data(%{id: "corr_123"})
    end

    test "rejects data without id" do
      assert {:error, _reason} = CorrelationId.validate_data(%{})
    end
  end

  describe "to_attrs/1" do
    test "converts map to attrs format with namespace key" do
      assert %{"correlationid" => %{"id" => "corr_abc"}} = CorrelationId.to_attrs(%{id: "corr_abc"})
    end

    test "converts string directly" do
      assert %{"correlationid" => %{"id" => "corr_xyz"}} = CorrelationId.to_attrs("corr_xyz")
    end
  end

  describe "from_attrs/1" do
    test "extracts data from correlationid key with string keys" do
      attrs = %{"correlationid" => %{"id" => "corr_123"}}
      assert %{id: "corr_123"} = CorrelationId.from_attrs(attrs)
    end

    test "extracts data from correlationid key with atom keys" do
      attrs = %{correlationid: %{id: "corr_456"}}
      assert %{id: "corr_456"} = CorrelationId.from_attrs(attrs)
    end

    test "returns nil when correlationid key is missing" do
      assert nil == CorrelationId.from_attrs(%{})
    end

    test "returns nil when correlationid has unexpected structure" do
      assert nil == CorrelationId.from_attrs(%{"correlationid" => "not_a_map"})
    end
  end

  describe "extension registration" do
    test "extension is registered with the signal registry at runtime" do
      # The extension should be registered when the module is loaded
      # and the registry is running
      assert {:ok, CorrelationId} = Jido.Signal.Ext.Registry.get("correlationid")
    end
  end

  describe "signal integration" do
    test "creates signal with correlationid extension" do
      {:ok, signal} =
        Jido.Signal.new(
          "test.event",
          %{foo: "bar"},
          source: "/test",
          correlationid: %{id: "corr_test123"}
        )

      # Extension data is stored after validation (atom keys in internal struct)
      assert signal.extensions["correlationid"] == %{id: "corr_test123"}
    end

    test "signal serialization roundtrip preserves correlationid" do
      {:ok, signal} =
        Jido.Signal.new(
          "test.event",
          %{foo: "bar"},
          source: "/test",
          correlationid: %{id: "corr_roundtrip"}
        )

      # Serialize and deserialize
      {:ok, binary} = Jido.Signal.serialize(signal)
      {:ok, parsed} = Jido.Signal.deserialize(binary)

      assert parsed.extensions["correlationid"] == %{id: "corr_roundtrip"}
    end
  end
end
