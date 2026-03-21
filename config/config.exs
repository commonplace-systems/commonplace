import Config

config :commonplace,
  data_dir: System.get_env("COMMONPLACE_DATA_DIR", "data")

import_config "#{config_env()}.exs"
