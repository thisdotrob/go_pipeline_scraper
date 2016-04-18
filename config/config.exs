use Mix.Config

config :scraper, go_pipeline_name: System.get_env("GO_PIPELINE_NAME")
config :scraper, go_username: System.get_env("GO_USERNAME")
config :scraper, go_password: System.get_env("GO_PASSWORD")
config :scraper, go_base_url: System.get_env("GO_BASE_URL")

config :hound, driver: "phantomjs"
config :hound, http: [timeout: :infinity]
config :hound, http: [recv_timeout: :infinity]
