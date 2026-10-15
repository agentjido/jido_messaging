defmodule Jido.Messaging.ChatActions.Action do
  @moduledoc false

  defmacro __using__(opts) do
    operation = Keyword.fetch!(opts, :operation)
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    schema = Keyword.fetch!(opts, :schema)

    quote do
      use Jido.Action,
        name: unquote(name),
        description: unquote(description),
        schema: unquote(schema),
        output_schema: Zoi.struct(Jido.Signal)

      defoverridable validate_output: 1

      @doc false
      @impl Jido.Executable
      def validate_output(%Jido.Signal{} = output) do
        catalog =
          Jido.Signal.Catalog.new!([
            Jido.Messaging.Signal.OperationCompleted,
            Jido.Messaging.Signal.OperationFailed
          ])

        with {:ok, ^output} <- output |> Jido.Signal.to_map() |> Jido.Signal.from_map(),
             {:ok, ^output} <- Jido.Signal.Catalog.validate(catalog, output),
             {:ok, ^output} <- Jido.Chat.Signal.Policy.validate(output),
             do: {:ok, output}
      end

      def validate_output(_output), do: Jido.Chat.Signal.Policy.error(:invalid_request)

      @doc false
      def chat_action_operation, do: unquote(operation)

      @impl true
      def run(params, context) do
        Jido.Messaging.ChatActions.Executor.execute(unquote(operation), params, context)
      end
    end
  end
end
