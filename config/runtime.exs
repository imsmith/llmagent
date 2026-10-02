import Config

config :LLMAgent,
  model: System.get_env("LLMAGENT_MODEL", "gpt-4"),
  api_host: System.get_env("LLMAGENT_API_HOST", "http://localhost:11434/v1"),
  role: System.get_env("LLMAGENT_ROLE", "default")

# Discovery shims. Each is an external program that writes EDN register/expire
# lines on stdout; LLMAgent.Discovery.PortAdapter reads them and maintains the
# ads in LLMAgent.Tools.Discovery.
#
# NOTE: these paths resolve against File.cwd!(), so they only work when LLMAgent
# runs standalone. Under agento, LLMAgent is a dependency and this runtime.exs
# is not evaluated — agento declares its own :discovery_adapters and resolves
# scripts via Application.app_dir(:LLMAgent, ...). Adding a shim here does not
# turn it on there.
#
# The mDNS shim is left out under test. It renews its ads for as long as it
# runs, so the real network's hosts would reappear in a registry a test had
# just emptied. Its own integration test starts it against a fake source.
mdns_shims =
  if config_env() == :test do
    []
  else
    [
      %{
        name: :avahi_llama,
        command: System.find_executable("tclsh"),
        args: [Path.expand("priv/discovery/avahi-llama.tcl", File.cwd!())],
        env: []
      }
    ]
  end

config :LLMAgent,
       :discovery_adapters,
       mdns_shims ++
         [
           # Local executables in ~/bin, advertised as :speculative ads with leases.
           # Static reading only — bin-watch.tcl never executes a watched tool. See
           # the header of that script for why running them to interrogate them is
           # unsafe for this population.
           %{
             name: :bin_watch,
             command: System.find_executable("tclsh"),
             args: [
               Path.expand("priv/discovery/bin-watch.tcl", File.cwd!()),
               "--dir",
               Path.join(System.user_home!(), "bin"),
               "--interval",
               "60",
               "--lease",
               "180"
             ],
             env: []
           }
         ]
