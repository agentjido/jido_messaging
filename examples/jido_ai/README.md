# Optional Jido AI Demo

The core `jido_messaging` package does not require `jido_ai`. This example adds
a ReAct agent behind the normal `Jido.Messaging.AgentRunner` handler boundary.

Add the optional package to the host application:

```elixir
def deps do
  [
    {:jido_messaging, "~> 1.1"},
    {:jido_ai, "~> 2.2"}
  ]
end
```

The demo task loads these example modules when agent mode starts:

```bash
mix jido.messaging.demo --agent
```

Applications do not have to use `jido_ai`. They can connect any agent process
to messaging with an `AgentRunner` configuration:

```elixir
agent_config = %{
  name: "SupportAgent",
  trigger: :mention,
  handler: fn message, context ->
    MyAgentProcess.handle_message(message, context)
  end
}

children = [
  {Jido.Messaging.AgentRunner,
   room_id: "support",
   agent_id: "support-agent",
   agent_config: agent_config,
   instance_module: MyApp.Messaging}
]
```

The handler returns `{:reply, text}`, `{:ok, text}`, `:ignore`, or an error.
This function contract is the supported integration boundary. Agent ownership,
model calls, tools, and durable state remain outside the messaging core.
