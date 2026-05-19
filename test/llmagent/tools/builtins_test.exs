defmodule LLMAgent.Tools.BuiltinsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias LLMAgent.{Tools.Builtins, Tools.Discovery, ToolQuery}

  setup do
    case Process.whereis(Discovery) do
      nil -> {:ok, _} = Discovery.start_link(consume_announcements: false)
      _ -> Discovery.reset!()
    end

    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    :ok
  end

  test "register_all/0 registers every built-in tool ad" do
    :ok = Builtins.register_all()

    expected = [
      "function.crypto",
      "resource.network",
      "resource.proc",
      "resource.fs.events",
      "resource.hardware.events",
      "resource.fs.file",
      "function.http",
      "function.systemd",
      "function.dbus",
      "function.coordination.tuplespace",
      "function.agent",
      "function.shell.bash"
    ]

    for coord <- expected do
      assert {:ok, ad} = Discovery.find_one(ToolQuery.new(%{coordinate: coord}))
      assert ad.fidelity == :authoritative
    end
  end
end
