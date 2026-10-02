{:ok, _} = Application.ensure_all_started(:req)
body = %{model: "x", stream: true, max_tokens: 64, messages: [%{role: "user", content: "count to twenty"}]}
url = "http://10.10.1.226:8080/chat/completions"
# full stream
{:ok, resp} = Req.post(url, json: body, receive_timeout: 60_000,
  into: fn {:data, data}, {req, resp} ->
    n = Req.Response.get_private(resp, :n, 0)
    {:cont, {req, Req.Response.put_private(resp, :n, n + byte_size(data))}}
  end)
IO.puts("full: status=#{resp.status} bytes=#{Req.Response.get_private(resp, :n)} body=#{inspect(resp.body)}")
# halt after first chunk
t0 = System.monotonic_time(:millisecond)
{:ok, resp2} = Req.post(url, json: body, receive_timeout: 60_000,
  into: fn {:data, data}, {req, resp} -> {:halt, {req, Req.Response.put_private(resp, :first, byte_size(data))}} end)
IO.puts("halt: status=#{resp2.status} first_chunk=#{Req.Response.get_private(resp2, :first)} ms=#{System.monotonic_time(:millisecond) - t0}")
# error status with into
{:ok, resp3} = Req.post("http://10.10.1.226:8080/nope", json: body, into: fn {:data, d}, {req, resp} -> {:cont, {req, Req.Response.put_private(resp, :err, d)}} end)
IO.puts("404: status=#{resp3.status} captured=#{inspect(Req.Response.get_private(resp3, :err))}")
IO.inspect(Req.post("http://127.0.0.1:1/x", json: body, retry: false, into: fn {:data, _}, acc -> {:cont, acc} end), label: "refused")
