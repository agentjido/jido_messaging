postgres_exclusions =
  if System.get_env("JIDO_MESSAGING_POSTGRES_URL") do
    []
  else
    [postgres: true]
  end

ExUnit.start(capture_log: true, exclude: postgres_exclusions)
