import Config

# Configuration for test environment

# Nostrum requires a token with valid format (base64-encoded user ID + timestamp + hmac)
# Using manual sharding prevents nostrum from trying to connect to Discord
config :nostrum,
  token: "MTIzNDU2Nzg5MDEyMzQ1Njc4.XXXXXX.XXXXXXXXXXXXXXXXXXXXXXXXXXXX",
  num_shards: :manual
