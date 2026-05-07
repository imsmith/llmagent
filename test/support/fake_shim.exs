# Reads scripted commands from $LLMAGENT_FAKE_SHIM_SCRIPT (one per line)
# and writes them verbatim to stdout with a small delay between lines.
# Used by Discovery.PortAdapter tests to drive the GenServer with known input.
#
# Each line in the script file is either:
#   EMIT <edn-line>     — write the rest of the line to stdout
#   SLEEP <ms>          — wait
#   EXIT  <code>        — exit with the given status

path = System.get_env("LLMAGENT_FAKE_SHIM_SCRIPT") || raise "missing script"

path
|> File.stream!()
|> Stream.map(&String.trim_trailing/1)
|> Enum.each(fn
  "EMIT " <> rest ->
    IO.puts(rest)

  "SLEEP " <> ms ->
    ms |> String.to_integer() |> Process.sleep()

  "EXIT " <> code ->
    System.halt(String.to_integer(code))

  "" ->
    :ok

  other ->
    IO.puts(:stderr, "fake_shim: unknown directive: #{other}")
end)
