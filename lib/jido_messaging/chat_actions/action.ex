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
        output_schema:
          Zoi.object(%{
            status: Zoi.atom(),
            action: Zoi.atom(),
            code: Zoi.atom() |> Zoi.optional(),
            data: Zoi.any() |> Zoi.optional(),
            details: Zoi.map() |> Zoi.optional(),
            audit: Zoi.map()
          })

      @doc false
      def chat_action_operation, do: unquote(operation)

      @impl true
      def run(params, context) do
        Jido.Messaging.ChatActions.Executor.execute(unquote(operation), params, context)
      end
    end
  end
end
