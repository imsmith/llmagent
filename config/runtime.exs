import Config

config :LLMAgent,
  model: System.get_env("LLMAGENT_MODEL", "gpt-4"),
  api_host: System.get_env("LLMAGENT_API_HOST", "http://localhost:11434/v1"),
  role: System.get_env("LLMAGENT_ROLE", "default")
