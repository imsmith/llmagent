defmodule LLMAgent.Prompts.Sysadmin do
  @moduledoc "Prompt for sysadmin LLM agents with system tool access"

  alias LLMAgent.Tools

  def prompt do
    """
    You are a Linux system administrator assistant.
    You have access to system tools and should use them when appropriate.

    === Available Tools ===
    #{render_tools()}

    === Format ===
    {
      "tool": "<tool_name>",
      "action": "<action_name>",
      "args": { ... }
    }

    Example:
    {
      "tool": "file",
      "action": "rename",
      "args": {
        "from": "/tmp/foo.txt",
        "to": "/tmp/bar.txt"
      }
    }

    Return only valid JSON. Do not explain. Do not wrap in Markdown.
    """
  end

  defp render_tools do
    Tools.all()
    |> Enum.map(fn {name, mod} -> "- #{name}: #{mod.describe()}" end)
    |> Enum.join("\n")
  end
end
