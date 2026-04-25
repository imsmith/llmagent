---
title: Elixir agentic framework design
description: 
author: Ian Smith
date_created: 20250703
date_published: 
date_modified: 
tags: ghost_tag_llm
---


> [!QUESTION]
> i need a design for a elixir-native agentic framework like langchain or crewAI that is compatible with the elixir ecosystem

Below is a high‑level design sketch for an Elixir‑native “agentic” framework—think LangChain or CrewAI, but built idiomatically on OTP, GenServers, behaviours and macros. Feel free to adapt names and details to your own tastes.

---

## 1. Goals & Principles

- **OTP‑First**  
    Agents, chains and tools are all processes under supervisors, with well‑defined restart strategies.
    
- **Behaviour‑Driven**  
    Define clear behaviours for LLM clients, tools, memory backends, retrievers, etc., so everything plugs together.
    
- **DSL for Pipelines**  
    Provide `use Agento` + macros (`defchain`, `deftool`, `defmemory`) to declare flows in a concise, Elixir‑native way.
    
- **Elixir Ecosystem Compatible**  
    Leverage Tesla (HTTP), Nx (embeddings/ML), Nebulex or Mnesia (caching & memory), Broadway/Flow (streaming), Telemetry, Logger, Dialyzer, ExUnit/Mox.
    

---

## 2. Core Behaviours

```elixir
# lib/agento/behaviours/llm_client.ex
defmodule Agento.Behaviours.LLMClient do
  @callback generate(prompt :: String.t(), opts :: Keyword.t()) ::
              {:ok, %{text: String.t(), usage: map()}} | {:error, term()}
end

# lib/agento/behaviours/tool.ex
defmodule Agento.Behaviours.Tool do
  @callback call(input :: any(), opts :: Keyword.t()) ::
              {:ok, any()} | {:error, term()}
end

# lib/agento/behaviours/memory.ex
defmodule Agento.Behaviours.Memory do
  @callback get(key :: term(), ctx :: map()) :: any()
  @callback put(key :: term(), value :: any(), ctx :: map()) :: map()
end

# lib/agento/behaviours/retriever.ex
defmodule Agento.Behaviours.Retriever do
  @callback retrieve(query :: String.t(), top_k :: integer()) :: {:ok, [any()]} | {:error, term()}
end
```

---

## 3. DSL & Pipeline Definition

```elixir
defmodule MyApp.Agents.QAAgent do
  use Agento, otp_app: :my_app

  # 1) configure LLM
  llm :openai, module: Agento.LLM.OpenAI, api_key: {:system, "OPENAI_KEY"}

  # 2) define a Retriever tool
  deftool :vector_retriever do
    @behaviour Agento.Behaviours.Retriever
    def init(opts),   do: opts
    def retrieve(q, k), do: MyVectorDB.search(q, k)
  end

  # 3) define an in‑memory chat history
  defmemory :chat_history, backend: Agento.Memory.Nebulex, cache: MyApp.Cache

  # 4) declare a chain
  defchain :answer_question do
    step :fetch_docs, with: :vector_retriever, args: [query: & &1.question, top_k: 3]
    step :compose_prompt, fn %{question: q, fetch_docs: docs} ->
      """
      You are an expert. Q: #{q}
      Context: #{Enum.join(docs, "\n\n")}
      """
    end
    step :generate_answer, with: :openai, args: [prompt: & &1.compose_prompt]
    step :save_history, fn ctx ->
      chat = Map.get(ctx, :chat_history) |> List.insert_at(-1, %{q: ctx.question, a: ctx.generate_answer.text})
      {:ok, chat}
    end, after: fn ctx -> put_memory(ctx, :chat_history, ctx.save_history) end
  end
end
```

---

## 4. Supervisor & Runtime

```
MyApp.Application
├─ DynamicSupervisor (Agento.AgentSupervisor)
│    ├─ QAAgent (GenServer)
│    └─ AnotherAgent…
├─ Nebulex.CacheSupervisor
├─ Telemetry supervisor
└─ …other app processes…
```

- **DynamicSupervisor** lets you start/stop agents at runtime:
    
    ```elixir
    {:ok, pid} = Agento.AgentSupervisor.start_child(QAAgent, name: MyQA)
    Agento.call(pid, {:run, :answer_question, %{question: "What's Elixir?"}})
    ```
    
- Each agent is a GenServer that holds its own config and state (e.g. memory pointers).
    

---

## 5. Configuration & Extensibility

- **Config** via `config/config.exs` using NimbleOptions.
    
- **Add new LLMs** by implementing `Agento.Behaviours.LLMClient`.
    
- **Add new Tools** by `deftool` macro or by writing modules adhering to the Tool behaviour.
    
- **Swap Memory Backends** (ETS, Mnesia, Nebulex, Redis) by implementing the Memory behaviour.
    
- **Vector Stores**: wrap Pinecone, Weaviate, Redis‑search clients as Retriever behaviours.
    

---

## 6. Observability & Testing

- **Telemetry events** on every step:
    
    ```elixir
    :telemetry.execute([:agento, :chain, :step, :start], %{time: now}, %{agent: __MODULE__, step: :fetch_docs})
    ```
    
- **Logging** via `Logger.debug/1` in each behaviour default.
    
- **Testing** with ExUnit + Mox: mock out LLMClient and retrievers to assert flows.
    

---

## 7. Example Usage

```elixir
# start your application, ensure QAAgent is loaded under the AgentSupervisor

# spawn an instance
{:ok, pid} = Agento.AgentSupervisor.start_child(MyApp.Agents.QAAgent, name: :qa1)

# run the chain
{:ok, result} =
  Agento.Agent.call(pid, {:run, :answer_question, %{question: "Explain OTP supervisors?"}})

IO.puts(result.generate_answer.text)
```

---

### Next Steps

1. **Prototype** the DSL macros (`use Agento`, `defchain`, etc.).
    
2. **Implement core behaviours**, starting with a simple OpenAI client (HTTP → Tesla → JSON).
    
3. **Wire up** an in‑memory ETS backend for `defmemory`.
    
4. **Add** a basic retriever (e.g. file‑based or stub) to test end‑to‑end.
    
5. **Iterate** on ergonomics: shorten macro names, improve error messages, add fallbacks, etc.
    

With this scaffold, you’ll have a fully OTP‑driven, Elixir‑native agent framework that can grow into anything from simple chatbots to complex multi‑tool reasoning pipelines. Let me know which part you’d like to dive into first!

> [!QUESTION]
>  would also like a independent stateless function - like an AWS lambda - that is not an agent in this framework and an independent table function that provides a tuple-space - like a in Linda or  JavaSpaces - as part of the framework.

Below is an extension of the Agento design to include both:

1. **Stateless “function” modules** (à la AWS Lambda) that live outside of long‑running agent processes
    
2. A **shared tuple‑space** (Linda/JavaSpaces‑style) for loosely‑coupled coordination
    

---

## 1. Stateless Functions

### 1.1 Behaviour

```elixir
# lib/agento/behaviours/function.ex
defmodule Agento.Behaviours.Function do
  @moduledoc """
  A stateless compute unit. Called with some input, returns an output,
  but holds no internal state between invocations.
  """
  @callback call(input :: any(), opts :: Keyword.t()) ::
              {:ok, any()} | {:error, term()}
end
```

### 1.2 Macro DSL

```elixir
defmodule Agento.FunctionDSL do
  defmacro __using__(opts) do
    quote do
      @behaviour Agento.Behaviours.Function
      use GenServer, restart: :transient

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, [])
      def init(opts),    do: {:ok, opts}

      @doc """
      Invoke this function asynchronously under a Task supervisor.
      """
      def invoke(input, opts \\ []) do
        Task.Supervisor.async_nolink(
          Agento.FunctionSupervisor, 
          fn -> __MODULE__.call(input, opts) end
        )
      end
    end
  end
end
```

### 1.3 Example

```elixir
defmodule MyApp.Functions.TranslateText do
  use Agento.FunctionDSL

  @impl true
  def call(%{text: text, to: lang}, _opts) do
    # call out to an external translation API
    {:ok, ExternalTranslator.translate(text, to: lang)}
  end
end

# elsewhere, fire it off without spinning up an agent:
task = MyApp.Functions.TranslateText.invoke(%{text: "hola", to: "en"})
{:ok, %{text: "hello"}} = Task.await(task, 5_000)
```

### 1.4 Supervisor Setup

```elixir
# in your Application.start/2
children = [
  {Task.Supervisor, name: Agento.FunctionSupervisor},
  # … other supervisors …
]
```

---

## 2. Tuple‑Space (Linda / JavaSpaces)

### 2.1 Behaviour

```elixir
# lib/agento/behaviours/tuple_space.ex
defmodule Agento.Behaviours.TupleSpace do
  @callback out(tuple :: any()) :: :ok
  @callback rd(pattern :: any(), timeout :: timeout()) :: {:ok, any()} | :timeout
  @callback in(pattern :: any(), timeout :: timeout()) :: {:ok, any()} | :timeout
end
```

### 2.2 GenServer Implementation

```elixir
defmodule Agento.TupleSpace.Server do
  use GenServer

  ## Public API
  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)
  def out(pid, tuple),  do: GenServer.cast(pid, {:out, tuple})
  def rd(pid, pat, to),  do: GenServer.call(pid, {:rd, pat, to}, :infinity)
  def in_(pid, pat, to), do: GenServer.call(pid, {:in, pat, to}, :infinity)

  ## Callbacks
  def init(_), do: {:ok, %{tuples: []}}

  def handle_cast({:out, tuple}, state) do
    state = %{state | tuples: [tuple | state.tuples]}
    # wake any blocked readers
    Process.send_after(self(), :dispatch, 0)
    {:noreply, state}
  end

  def handle_call({:rd, pat, timeout}, {from, _}, state) do
    case match_once(state.tuples, pat) do
      {:ok, t} -> {:reply, {:ok, t}, state}
      :none    -> block_reader({:rd, pat}, from, timeout, state)
    end
  end

  def handle_call({:in, pat, timeout}, {from, _}, state) do
    case match_once_and_remove(state.tuples, pat) do
      {:ok, t, new_tuples} ->
        {:reply, {:ok, t}, %{state | tuples: new_tuples}}
      :none ->
        block_reader({:in, pat}, from, timeout, state)
    end
  end

  def handle_info(:dispatch, state) do
    # try to wake blocked readers…
    {:noreply, state} 
  end

  ## Helpers (simplified)
  defp match_once(tuples, pat) do
    Enum.find_value(tuples, :none, fn t ->
      if Pattern.match?(pat, t), do: {:ok, t}, else: false
    end)
  end

  defp match_once_and_remove(tuples, pat) do
    case Enum.split_with(tuples, fn t -> not Pattern.match?(pat, t) end) do
      {rest, [h | tail]} -> {:ok, h, rest ++ tail}
      _ -> :none
    end
  end

  defp block_reader(kind, from, timeout, state) do
    # register in state.readers with timer…
    {:noreply, update_in(state.readers, &[{kind, from, timeout}|&1])}
  end
end
```

_(You’d flesh out reader‐queue management, timeouts, notifications, and optional persistence via Mnesia or Nebulex.)_

### 2.3 Supervision

```elixir
children = [
  {Agento.TupleSpace.Server, name: Agento.TupleSpace}, 
  # …
]
```

### 2.4 Usage Example

```elixir
# publish a tuple
:ok = Agento.TupleSpace.Server.out(Agento.TupleSpace, {:order, 123, :created})

# non‑destructive read
{:ok, {:order, id, :created}} =
  Agento.TupleSpace.Server.rd(Agento.TupleSpace, {:order, _id, :created}, 5_000)

# destructive take
{:ok, {:order, id, :created}} =
  Agento.TupleSpace.Server.in_(Agento.TupleSpace, {:order, _id, :created}, 5_000)
```

---

## 3. How They Fit

```text
MyApp.Application
├─ Agento.FunctionSupervisor   # stateless functions
├─ Agento.TupleSpace           # shared Linda space
├─ DynamicSupervisor (agents)
│    ├─ QAAgent
│    └─ … 
├─ Nebulex.CacheSupervisor
└─ Telemetry/Logger/…
```

- **Agents** focus on long‑lived, stateful “chains”
    
- **Functions** handle ephemeral, stateless compute without agent overhead
    
- **TupleSpace** lets agents or functions coordinate via publish/read/take
    

---

With these pieces in place you get:

- on‑demand serverless‐style functions that you can call from within or outside any agent
    
- a Linda‑style tuple space for flexible, decoupled communication
    

Let me know if you’d like to drill into the reader‑queue logic, persistence options, or macro support for defining functions and tuple spaces!

> [!QUESTION]
> I also need this framework to be a NATs client and to be able to communicate with SWI-Prolog via NATS to off-load heavy logic.   show all the code.

I’ve added full code for:

- **`mix.exs`** dependencies (including Gnat & Jason)
    
- **`MyApp.Application`** supervision tree with the NATS client
    
- A **`NATSClient` behaviour**
    
- A **`Agento.NATS.Client`** GenServer wrapper around Gnat (publish, request, subscribe)
    
- An **`Agento.Prolog`** module to send Prolog queries over NATS and decode solutions
    

You can drop these files into your Elixir project under `lib/agento/…` and update your mix deps to get NATS and JSON support. Let me know if you need deeper wiring—like macro DSL for defining NATS‑backed functions, buffering of subscriptions, or example SWI‑Prolog server code.

> [!QUESTION]
> and if i wanted to have a large action model that this framework could access...  what does the design of that look like?

I’ve extended the existing code to include:

1. **`ActionModel` behaviour** defining `decide/2` to pick actions.
    
2. **`Agento.ActionModel.Default`**, a GenServer that uses an LLM (e.g. OpenAI function‑calling) to choose from a list of actions.
    
3. **Example wiring** in your supervision tree and an `AvailableActions` module listing possible actions with names, descriptions, and parameter schemas.
    
4. **Agent‑chain usage** showing how to invoke `decide/2` in a `defchain` step to set `:chosen_action` and `:action_params`.
    

With this in place, your agents can query the action model at runtime to determine which tool or function to run next, passing structured parameters. Let me know if you’d like to add:

- Macro support (`defactionmodel`) to simplify definitions
    
- Caching of action decisions
    
- Alternate implementations (e.g. local ONNX via Nx)

> [!QUESTION]
> I also need this framework to be a NATs client and to be able to communicate with SWI-Prolog via NATS to off-load heavy logic.   show all the code.

I’ve added full code for:

- **`mix.exs`** dependencies (including Gnat & Jason)
    
- **`MyApp.Application`** supervision tree with the NATS client
    
- A **`NATSClient` behaviour**
    
- A **`Agento.NATS.Client`** GenServer wrapper around Gnat (publish, request, subscribe)
    
- An **`Agento.Prolog`** module to send Prolog queries over NATS and decode solutions
    

You can drop these files into your Elixir project under `lib/agento/…` and update your mix deps to get NATS and JSON support. Let me know if you need deeper wiring—like macro DSL for defining NATS‑backed functions, buffering of subscriptions, or example SWI‑Prolog server code.

> [!QUESTION]
> and if i wanted to have a large action model that this framework could access...  what does the design of that look like?

```elixir
# mix.exs (excerpt)
defmodule MyApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :my_app,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MyApp.Application, []}
    ]
  end

  defp deps do
    [
      {:gnat, "~> 1.4"},
      {:jason, "~> 1.3"},
      {:telemetry, "~> 1.0"},
      {:nebulex, "~> 2.0"},
      {:nx, "~> 0.3"},
      {:broadway, "~> 1.0"},
      {:tesla, "~> 1.4"}
      # ... other deps ...
    ]
  end
end

# lib/my_app/application.ex

defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Agento.FunctionSupervisor},
      {Agento.TupleSpace.Server, name: Agento.TupleSpace},
      {Agento.NATS.Client, host: "localhost", port: 4222},
      {Agento.ActionModel.Default, []},
      {DynamicSupervisor, strategy: :one_for_one, name: Agento.AgentSupervisor},
      {Nebulex.CacheSupervisor, name: MyApp.CacheSupervisor}
      # ... telemetry, logger, etc. ...
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

# lib/agento/behaviours/nats_client.ex

defmodule Agento.Behaviours.NATSClient do
  @moduledoc """
  Behaviour for NATS client integration.
  """
  @callback publish(subject :: String.t(), payload :: binary(), opts :: Keyword.t()) ::
              :ok | {:error, term()}
  @callback request(subject :: String.t(), payload :: binary(), timeout :: timeout()) ::
              {:ok, binary()} | {:error, term()}
  @callback subscribe(subject :: String.t(), opts :: Keyword.t()) ::
              {:ok, pid()} | {:error, term()}
end

# lib/agento/nats/client.ex

defmodule Agento.NATS.Client do
  @moduledoc """
  A GenServer wrapper around Gnat for NATS messaging.
  """
  use GenServer
  require Logger
  @behaviour Agento.Behaviours.NATSClient

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def publish(subject, payload, _opts \\ []) do
    GenServer.call(__MODULE__, {:publish, subject, payload})
  end

  @impl true
  def request(subject, payload, timeout \\ 5_000) do
    GenServer.call(__MODULE__, {:request, subject, payload, timeout}, timeout + 1_000)
  end

  @impl true
  def subscribe(subject, _opts \\ []) do
    GenServer.call(__MODULE__, {:subscribe, subject})
  end

  ## GenServer callbacks

  def init(opts) do
    conn_opts = Keyword.take(opts, [:host, :port, :tls_opts, :connection_name])
    {:ok, conn} = Gnat.start_link(conn_opts)
    {:ok, conn}
  end

  def handle_call({:publish, subject, payload}, _from, conn) do
    :ok = Gnat.pub(conn, subject, payload)
    {:reply, :ok, conn}
  end

  def handle_call({:request, subject, payload, timeout}, _from, conn) do
    case Gnat.request(conn, subject, payload, timeout: timeout) do
      {:ok, msg} -> {:reply, {:ok, msg.body}, conn}
      error -> {:reply, error, conn}
    end
  end

  def handle_call({:subscribe, subject}, _from, conn) do
    {:ok, sid} = Gnat.sub(conn, self(), subject)
    {:reply, {:ok, sid}, conn}
  end

  def handle_info({:msg, %{body: body, subject: subject}}, conn) do
    Logger.debug("Received NATS message on #{subject}: #{inspect(body)}")
    {:noreply, conn}
  end
end

# lib/agento/prolog.ex

defmodule Agento.Prolog do
  @moduledoc """
  Off-load heavy logic to SWI-Prolog via NATS.
  """
  @nats Agento.NATS.Client

  @doc """
  Send a Prolog query and await results.
  `prolog_term` should be a Prolog term string, e.g. "member(X, [1,2,3])."
  Returns `{:ok, solutions}` or `{:error, reason}`.
  """
  def query(prolog_term, timeout \\ 5_000) do
    request = %{term: prolog_term}
    payload = Jason.encode!(request)

    case @nats.request("prolog.query", payload, timeout) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"solutions" => sols}} -> {:ok, sols}
          error -> {:error, {:decode_error, error}}
        end

      error ->
        error
    end
  end
end

# lib/agento/behaviours/action_model.ex

defmodule Agento.Behaviours.ActionModel do
  @moduledoc """
  Behaviour for selecting actions (tools, functions, or calls) given a context.
  """
  @callback decide(context :: map(), opts :: Keyword.t()) ::
              {:ok, %{action: atom(), params: map()}} | {:error, term()}
end

# lib/agento/action_model/default.ex

defmodule Agento.ActionModel.Default do
  @moduledoc """
  Default action model implementation using OpenAI function-calling style.
  """
  use GenServer
  require Logger
  alias Agento.Behaviours.{ActionModel, LLMClient}

  @behaviour ActionModel
  @llm Application.compile_env(:my_app, :action_model_llm, Agento.LLM.OpenAI)

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def decide(context, opts \\ []) do
    GenServer.call(__MODULE__, {:decide, context, opts})
  end

  ## Callbacks

  def init(opts), do: {:ok, opts}

  def handle_call({:decide, context, opts}, _from, state) do
    functions = opts[:actions] || Application.fetch_env!(:my_app, :available_actions)
    prompt = build_prompt(context, functions)

    with {:ok, %{name: fname, arguments: args}} <-
           LLMClient.generate(@llm, prompt: prompt, functions: functions) do
      params = Jason.decode!(args)
      action = String.to_existing_atom(fname)
      {:reply, {:ok, %{action: action, params: params}}, state}
    else
      err -> {:reply, err, state}
    end
  end

  defp build_prompt(context, functions) do
    base = "Given context:\n#{inspect(context, pretty: true)}"
    fn_defs = functions |> Enum.map(&format_fn/1) |> Enum.join("\n")
    [base, "Available actions:", fn_defs] |> Enum.join("\n\n")
  end

  defp format_fn(%{name: name, description: desc, parameters: params}), do:
    "#{name}: #{desc} (#{inspect(params)})"
end

# Usage in an agent chain:
# step :choose_action, fn ctx ->
#   {:ok, %{action: act, params: params}} =
#     Agento.ActionModel.Default.decide(ctx, actions: MyApp.AvailableActions.list())
#   %{ctx | chosen_action: act, action_params: params}
# end

# lib/my_app/available_actions.ex

defmodule MyApp.AvailableActions do
  @moduledoc "Defines actions the action model can choose."

  def list do
    [
      %{
        name: "fetch_docs",
        description: "Retrieve relevant documents",
        parameters: %{query: :string, top_k: :integer}
      },
      %{
        name: "translate",
        description: "Translate text to a target language",
        parameters: %{text: :string, to: :string}
      },
      %{
        name: "store_result",
        description: "Store a result in memory",
        parameters: %{key: :string, value: :string}
      }
    ]
  end
end

```

I’ve extended the existing code to include:

1. **`ActionModel` behaviour** defining `decide/2` to pick actions.
    
2. **`Agento.ActionModel.Default`**, a GenServer that uses an LLM (e.g. OpenAI function‑calling) to choose from a list of actions.
    
3. **Example wiring** in your supervision tree and an `AvailableActions` module listing possible actions with names, descriptions, and parameter schemas.
    
4. **Agent‑chain usage** showing how to invoke `decide/2` in a `defchain` step to set `:chosen_action` and `:action_params`.
    

With this in place, your agents can query the action model at runtime to determine which tool or function to run next, passing structured parameters. Let me know if you’d like to add:

- Macro support (`defactionmodel`) to simplify definitions
    
- Caching of action decisions
    
- Alternate implementations (e.g. local ONNX via Nx)

> [!QUESTION]
> ok.  thanks.  
> 
> I would like to step back and talk about the LAM itself.     can you show an example action that might be included in a LAM?

Here’s a concrete example of a single “action” entry you might include in your Large Action Model (LAM)—expressed as an Elixir map, with JSON‑Schema for its parameters. Think of this as one of the “functions” your action model can choose from:

```elixir
%{
  # Unique name the model will return
  name: "summarize_documents",

  # Human‑readable description for prompt construction
  description: "Generate a concise summary of the provided list of documents.",

  # JSON‑Schema for parameters the model must supply
  parameters: %{
    type: "object",
    properties: %{
      # A list of raw text blobs to summarize
      documents: %{
        type: "array",
        items: %{type: "string"},
        description: "An array of document texts (strings) to summarize."
      },
      # Desired maximum token length of the summary
      max_length: %{
        type: "integer",
        description: "Maximum length of the summary in tokens.",
        default: 150
      },
      # Optionally, a style hint (e.g., bullet list vs. paragraph)
      style: %{
        type: "string",
        enum: ["concise", "bullet", "narrative"],
        description: "Format style for the summary."
      }
    },
    required: ["documents"]
  }
}
```

### How it fits into your LAM

```elixir
defmodule MyApp.AvailableActions do
  def list do
    [
      # … other actions …
      %{
        name: "summarize_documents",
        description: "Generate a concise summary of the provided list of documents.",
        parameters: %{
          type: "object",
          properties: %{
            documents: %{type: "array", items: %{type: "string"}},
            max_length: %{type: "integer", default: 150},
            style: %{type: "string", enum: ["concise", "bullet", "narrative"]}
          },
          required: ["documents"]
        }
      }
      # … more actions …
    ]
  end
end
```

### Example agent step

Once the action model chooses `"summarize_documents"` and emits something like:

```json
{
  "action": "summarize_documents",
  "params": {
    "documents": ["…long text1…", "…long text2…"],
    "max_length": 200,
    "style": "bullet"
  }
}
```

your agent can dispatch it, for example:

```elixir
step :do_summary, fn ctx ->
  %{params: params} = ctx.chosen_action
  {:ok, summary} = MyApp.Functions.SummarizeDocuments.call(params)
  Map.put(ctx, :summary, summary)
end
```

—where `MyApp.Functions.SummarizeDocuments` is a stateless function module you implement to actually perform the summarization (e.g. via an LLM call or local model).