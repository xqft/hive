import Config

# Use a separate database for tests
config :hive, db_path: "priv/sqlite/hive_test.db"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hive, HiveWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "T0qrbedAShpj2joVhf+ryHXJs56oShyW+HmoFqfmgvKaJEoZ6b2vGwM1MrRbH1s1",
  server: false

# Configure mock SDK for Agent tests
config :hive,
       :agent_sdk_command,
       {System.find_executable("node") || "node",
        fn _agent_name, _session_id ->
          [Path.expand("test/support/mock_sdk.js")]
        end}

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
