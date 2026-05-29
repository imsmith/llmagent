# Brainstorm: orchestration and the role of LLMs

**Date:** 2026-05-19
**Status:** Open — to be ruminated on further.

Captured from a brainstorming dialogue while pressure-testing the native-function-calling spec (`docs/superpowers/specs/2026-05-19-native-function-calling.md`). The conversation started as a critique of the spec's load-bearing assumptions and progressively reframed what "tool calling" and "agent" actually are.

The spec was committed mid-session at `0602456`; the brainstorming that followed largely supersedes its framing. This doc preserves the dialogue for further thought before deciding whether to revise the spec, replace it, or follow a different design thread entirely.

---

## §1 — Pressure-testing the spec

**Claude:** Going back into brainstorming mode. The spec is well-formed but it makes a lot of load-bearing assumptions that deserve pressure-testing before we commit to a 16-task plan. Here are the four I'd most want to dig into — pick the one that worries you most, or add one I missed:

1. **The empirical foundation.** We've assumed llama-server's native function-calling on gemma-26B will produce clean calls because the documentation says it uses grammar-constrained sampling. We have NOT actually verified that with this model. Per-model quirks defeat grammar-constrained sampling sometimes — the model's training distribution can produce schema-valid-but-semantically-garbage calls. If gemma-26B still emits unusable calls even with `tools[]`, half the spec is wrong. Cheapest experiment: a 30-line probe script that asks gemma-26B for a `crypto.sha256` call through the OpenAI tools API and shows what comes back.

2. **MCP tools as ads — is the conversion actually clean?** I asserted "MCP and OpenAI function-calling both use JSON-Schema, so the conversion is structural." But MCP has richer lifecycle than I implied — content types, resource subscriptions, prompts as a separate primitive. The function-calling slice IS clean (MCP `tools/list` returns name + description + JSON-Schema for inputs, same as OpenAI's `tools[]`). But the broader assertion that "MCP, mDNS, and trained ads are all on the same footing" may not survive contact with MCP's `resources` and `prompts` primitives. Worth deciding: do those become different kinds (`:resource`, `:prompt`), or do we just import the `tools` slice and ignore the rest?

3. **Capability negotiation as static binding metadata.** The spec puts `capabilities: [:tools]` in the binding ad's `meta` field. But "supports `tools[]`" is per-endpoint AND possibly per-model on the same endpoint AND can be probed via `/v1/models`. Static metadata in the ad means: someone has to know what the endpoint supports when registering the ad. The mDNS shim doesn't know that — it just reads the avahi TXT record. Either: (a) the shim probes the endpoint's `/v1/models` before emitting the ad (slower discovery, more failure modes), (b) the agent does runtime capability detection and caches it, (c) we assume all OpenAI-compatible endpoints in our network support `tools[]` and skip negotiation entirely. The spec implies (a); (b) or (c) might be better.

4. **Multi-tool-call iteration vs the existing serial GenServer loop.** The current `LLMAgent` GenServer is built around: one prompt → one `Task.async` for the LLM call → one tool dispatch → one followup prompt → repeat. If `tool_calls` has 3 entries, the loop has to dispatch 3 tools and concatenate 3 `role: "tool"` messages before going back to the LLM. The spec hand-waves "same code with a fold," but the GenServer's `handle_info({ref, …})` pattern doesn't fit a fold trivially — each dispatch could be its own Task, results come back asynchronously, and the loop needs to know when ALL are done before re-prompting. Worth a closer look: do we serialize them, or actually parallelize, and how does the agent's mailbox handle the fan-in?

---

## §2 — Three pivots: RMI in disguise, Postel, and swarms

**User:** ok, this is where I start to allow my criticism of the way openai and anthropic develop protocols loose. this tool calling api is, technically, hot garbage. the mcp tool calling is better, but still shit. at the end of the day, this is just rmi dressed up to not set off all the rmi alarms. which is to say that we don't need to be beholden to either of these if we have a better way, especially since I think we do. "supports tools[]" is also trash, but it's our trash so we can own it, BUT the advertisement is the advertiser telling us that the endpoint supports something; don't second-guess that — liberal in what we accept, conservative in what we send. If we need more information in the mdns, we can put more information in the mdns, but we can't initiate a byzentine generals problem just because we're afraid to take an advertisement at face value. Tool use by the genserver... this really sounds like a "i'm smoking weed and have the munchies" kind of problem. let the agent be a supervisor for sub agents and keep one-tool-per-agent-at-a-time as a rule. we aren't trying to make super-agents, we're trying to make swarms.

**Claude:** OK so the reframe is bigger than the spec was contemplating. Let me make sure I'm tracking before asking the next question.

**Pivot 1: OpenAI/MCP tool-calling is RMI in different clothes.** The substrate IS the protocol; tools[]/tool_calls is at best a compatibility shim for endpoints that don't know how to talk to it natively. Our model doesn't need to emit OpenAI-shaped calls — our model needs to express intent that the substrate can resolve. We use the OpenAI shim where we have to (real OpenAI, real Anthropic, MCP servers), not as the primary path.

**Pivot 2: Postel — trust the ad.** If the advertisement says "supports tools[]" or "supports our substrate protocol" or whatever, we send accordingly. If it lies, we get an error, update our prior, move on. No probing, no Byzantine handshake, no `/v1/models` introspection. If we need richer capability info, we put it in the advertisement, not in a runtime negotiation protocol.

**Pivot 3: One-tool-per-agent-per-turn. Multi-tool = spawn sub-agents.** The agent is an OTP supervisor for sub-agents. Multi-step parallel work means the model calls `function.agent` `:spawn` to fan out. Children carry their own policy, their own subset, their own event stream. Tuple space for results. No multi-tool-call fold inside one GenServer.

The first two are downstream of the third in a sense — once you accept "one tool per turn, multi = spawn," the case for parallel `tool_calls` in the response evaporates, and "what does the model emit" becomes the central question. Which leads to the one I really want to pull on:

**Question:** What does the substrate-native interface look like *to the model*? Three plausible shapes, with very different small-model implications:

(a) **A mini-DSL in plain text.** The system prompt teaches the model a small command language — e.g., `[sha256 hello]`, `[bash "echo hello"]`, `[spawn :crypto sha256 hello]`. The agent parses with a real parser, matches against the loadout, dispatches. Closer to MUD/text-adventure protocols than to RMI. Cheap parser, transparent to humans reading the transcript, no schema-validation theatre, doesn't need grammar-constrained sampling because the parser tolerates whitespace/quoting variation.

(b) **Coordinate-shorthand sent as message-style emissions.** The model emits Smalltalk-flavored messages: `crypto sha256 data: "hello"` or `function.crypto/sha256 hello`. The agent interprets messages against the loadout. Cleaner mapping to substrate coordinates than (a). Still parseable. Closer to "sending a message to a tool" than "calling a function on it."

(c) **Affordance-first natural language.** The model just says what it wants in prose; the agent does intent-matching against `affordance.declared` entries. ("I want to compute the SHA-256 hash of 'abc'" → match to `function.crypto` `:compute` `"sha256"`.) Most flexible, most demanding on the matcher, most fragile for small models without intent-classification scaffolding.

My read: (a) is the right starting point. It's debuggable (you can read transcripts), small-model-friendly (no grammar-constrained sampling needed; a tolerant parser handles minor drift), substrate-native (the command language IS substrate coordinates), and shimmable (we translate to OpenAI tools[] for endpoints that need it). (b) is a refinement of (a) for later. (c) is the affordance-discovery work, deferred to the trained-ad commons.

Where would you want to start — (a), (b), or something I'm missing?

---

## §3 — What are we actually asking when we make a tool call?

**User:** ok, wait... what are we actually aasking when we make a tool call? like, this tool exists, it is a definite actor with determiniant results, which makes it better than the llm at what it does. we are just asking the llm to ride along with the tool and get value from it, right? if I want something that the tool can do — "hash this file with sha256" is really, "i'm too lazy to look up the man page to get the command syntax right, so you do it" Let's call those Class 1 tools. if I want something that is multi-part, now I'm asking the llm to clerk for me — "build a database of all the nfl games in the 2026 season, where they are geographically, what time they kick off. Then, for each team, calculate the round-trip travel distance between games and the total minutes between kickoffs and represent that as a csv with a row for each game." is really, "go to the web and get the schedule, then go to the web and get the distance between cities, then get all the kickoff times into the same timezone, then write a function that calculates travel distance and inter-game interval between each game after game 1 and put that into a row of a csv in this format {...}

**Claude:** That's the right level. Two extensions, both pulled from things you've already said:

**Class 0 exists below Class 1.** Pure inference. No tool. The user asked for a haiku, the LLM writes one. Most chat interactions are Class 0. The model isn't escorting anyone anywhere; it IS the destination. The interesting thing about Class 0 is it's the default; agentic systems collapse it into Class 1 reflexively ("emit a tool call OR a final answer") and pay context-window tax for tools the model didn't need to know about.

**Class 3 exists beyond Class 2.** Stateful engagement with something living. Watching a log stream, participating in a coordination protocol, holding a session open with an external service that has its own state and lifecycle. The substrate's `:stream` and `:coordinate` kinds already point at this. Class 3 isn't tool USE — it's tool PARTICIPATION. The LLM joins something already in motion; the tool isn't a one-shot expert, it's an ongoing relationship.

So the taxonomy and what each asks of the model:

| Class | What we're really asking | What the model has to do |
|---|---|---|
| **0** | Just talk to me | Pure inference |
| **1** | Be my interpreter to this one expert | Pick the right tool, hand it the inputs, surface its output |
| **2** | Be my clerk; plan and sequence | Decompose into Class 1 sub-tasks (probably via sub-agents), thread results, compose output |
| **3** | Be my ambassador to this relationship | Hold session, route events, decide when to participate vs withdraw |

Three implications I think follow:

1. **The model→agent interface isn't one thing.** It's context-shaped by which class we're in. Class 1 doesn't need a tools[] array; it needs a single verb the model can express + the input. Class 2 needs the spawn primitive prominently. Class 3 needs subscription/withdrawal semantics. The OpenAI tools[] protocol smashes all of these into one shape ("call this function with these args") and that's part of why it feels like ill-fitting RMI.

2. **The loadout is class-shaped, not just policy-shaped.** A Class 1 agent's loadout is probably one tool — it IS the hashing agent. A Class 2 clerk's loadout includes the spawn primitive. A Class 3 ambassador's loadout includes the relevant `:stream` or `:coordinate` ad. This is much smaller, much more focused than "give the model the whole list filtered by policy."

3. **The substrate already has the right primitives for all four.** The kinds (`:compute`, `:query`, `:action`, `:stream`, `:coordinate`, `:spawn`) ARE the class structure — `:compute`/`:query`/`:action` are Class 1 verbs, `:spawn` is the Class 2 hinge, `:stream`/`:coordinate` are Class 3 relationships. We haven't been thinking of them this way but they fall out exactly right.

Which makes me wonder if the right next question is: **does the function-calling spec need rewriting around classes, or does it stay focused on one class (probably Class 1, the simplest and most common case) and let the others get their own designs as we learn?**

My instinct: Class 1 is the load-bearing one to get right first. Most agentic value is Class 1. If we nail the Class 1 interface — model gets pointed at one tool, expresses input in some friendly form, gets a result — then Class 2 falls out as "the clerk Class 1's the spawn tool repeatedly" and Class 3 is its own thing built on the streaming substrate kinds we already have.

What do you want — Class 1 only as the v1, or all four classes co-designed?

---

## §4 — The LLM is the help

**User:** i guess i'm wondering why we're spending all this time on handing tools to llms when we have this orchestration framework that already does most of that and what we really need to do is make it suitable for llms to ride along with the tools we're orchestrating and stop making them the stars of the show, because they really aren't. they are the help.

**Claude:** You're right. And the function-calling spec I committed is residue from the inverted framing.

The orchestration framework already does the load-bearing work: discovery, dispatch, policy, supervision, coordination, persistence, events. What an LLM is *actually* good at — translating natural language to structured intent, generating syntactically-correct invocations, summarizing results back into prose, fuzzy-matching when the user is sloppy — is a narrow band of competences. We've been putting the LLM at the center because that's what every blog post says to do, but the LLM is the LEAST reliable, LEAST deterministic, LEAST observable component in the entire stack. Putting it in charge of decision flow is exactly backward.

The right frame: **the orchestrator runs the show; LLMs are tools the orchestrator dispatches to when it needs language-shaped competence.** Just like the orchestrator dispatches to `function.crypto` when it needs hash-shaped competence.

What this means concretely:

1. **The LLM is a tool kind, not a top-level actor.** Most likely as `:generate` (already in the substrate) or as new sub-kinds like `function.llm.classify`, `function.llm.parse_intent`, `function.llm.summarize`, `function.llm.format`. Each is a specific narrow LLM use-case. The orchestrator picks the right one for the step.

2. **Plans become first-class.** Not the LLM's plan — OUR plan. A workflow is a sequence or graph of (mostly deterministic) tool calls, where some steps are "ask the LLM to translate this user input into a coordinate" or "ask the LLM to summarize this tool's output for the user." The agent process executes the plan; doesn't make it up.

3. **The user's interface is to the orchestrator, not to the LLM.** The user submits a job; the orchestrator may ask clarifying questions (those questions might be LLM-generated for fluency, but the *decision to ask* belongs to the orchestrator). There's no "chat session with the LLM" at the top level. There's a job, a plan, dispatches, results.

4. **Small models become viable.** "Classify this user request into one of 5 categories" or "format this map as JSON" are within a 7B model's reliable range. "Plan and execute a multi-tool task" isn't. By reducing the LLM's role to focused single-step work, we move into the band where local llamas actually deliver.

5. **The current LLMAgent GenServer is mis-shaped for this.** It's built around "prompt → wait for LLM → dispatch tool → feed back → repeat." Under the reframe, it should be built around "receive job → plan → step through plan → at each step, dispatch (sometimes to LLM-as-tool) → collect → continue or branch." That's a closer cousin to Broadway or Oban than to a chat loop.

6. **Most of the substrate we just built is exactly right for this.** Discovery, kinds, bindings, policy, dispatcher, supervision, tuple space — all of it serves orchestration. The only piece that's wrong-shaped is the LLM-centric agent loop in `LLMAgent.ex`. The substrate doesn't need to change much; the agent process does.

Where this leaves the function-calling spec: **superseded, or at least demoted**. Native function-calling as a thing the orchestrator uses when dispatching to an LLM-as-tool is still useful (it's how we get a clean response shape from llama-server). But it's no longer THE design problem. It's an implementation detail of one tool-kind adapter. The real design problem is the orchestration loop.

---

## §5 — Comn.Secret.lock and the wrapper-module question

**User:** Comn.Secret.lock() is no different than LLMAgent.Tool.Crypto.perform(), except that we let the llm make the Comn.Secret call.

**Claude:** Yeah. That's the punchline.

The "tool" abstraction is a category we invented to wrap a thing that didn't need wrapping. `Comn.Secret.lock/2` IS a tool — it's a deterministic function that does crypto. So is `:crypto.hash/2`. So is `File.read/1`. So is `Req.get!/1`. The Elixir + Comn function space is *already* the tool space. We just spent a sprint writing wrapper modules around functions that already worked, because we thought "tool" meant "module that implements `LLMAgent.Tool`."

What the substrate genuinely provides is **discovery + policy + telemetry over the existing function space**. The wrapper modules were never load-bearing.

What this actually means:

1. **`LLMAgent.Tools.Crypto` shouldn't exist.** What should exist is an ad with `coordinate: "function.crypto.sha256"` and `binding: {:mfa, {:crypto, :hash, [:sha256]}}` (or whatever the call shape is). The dispatcher applies the MFA. No wrapper module. No `perform/2`. No `compute/2`. The "tool" is the function `:crypto.hash/2`.

2. **Same for the other eleven.** `Bash` becomes an ad pointing at `:os.cmd/1` or `System.cmd/3`. `File.read` becomes an ad pointing at `File.read/1`. `Web.get` becomes an ad pointing at `Req.get/1`. `Comn.Secret.lock`? Just write an ad. No new code, just metadata + policy.

3. **The kinds describe the binding, not the module.** `:compute` says "pure function, freely retryable." That's a property of the function being called, recorded in the ad. The function doesn't know it's a `:compute` — the ad knows, and the dispatcher knows what `:compute` means for invocation semantics (no idempotency key, no subscriber pid, etc.).

4. **The adapters reshape.** We don't need `:module` adapter dispatching to kind callbacks. We need binding adapters that say HOW to reach the function: `:mfa` (apply directly), `:mcp` (route through MCP transport), `:http` (HTTP request), `:openai_chat` (already exists, exactly this shape — it's an MFA-on-Req binding for a specific kind of call). The current `:module` adapter survives as a degenerate case of `:mfa`.

5. **Schemas are ad metadata, not behaviour callbacks.** The function doesn't carry its own schema — the AD does. Because the function is just a function; the schema is part of describing it for orchestration. This reverses the §6.1 commitment in the spec.

6. **The 12-tool migration sprint produced the right ARTIFACT (each tool has an ad) but the wrong CODE (each tool has a wrapper module).** The wrapper modules can be deleted. The ads stay, point at the underlying functions. ~1000 lines of wrapper code becomes ~50 lines of ad declarations referencing functions that already work.

7. **Comn folding becomes radical and obvious.** Every Comn function is a candidate for an ad. `Comn.Secret.lock/2` → `function.secret.lock`. `Comn.Repo.Table.ETS.get/2` → `function.repo.table.ets.get`. `Comn.Events.NATS.publish/3` → `function.events.nats.publish`. The Comn ecosystem becomes a library of tool implementations; llmagent's substrate becomes the discovery/policy/dispatch layer over it. This is the right shape — Comn provides competences; the substrate makes them addressable, policy-gated, LLM-dispatchable.

This collapses the function-calling spec dramatically. It also retroactively reframes what the migration sprint should have been (an ads-only sprint, not a wrappers-plus-ads sprint). And it makes the question "what do we tell the LLM" much smaller — the LLM doesn't see 12 tool modules; it sees a loadout of ads, each pointing at some function, anywhere in the Elixir+Comn universe.

The orchestrator frame from your last message plus this — they fit together. The orchestrator dispatches via ads to functions. LLMs are ONE kind of function (the natural-language-shaped one). The substrate doesn't distinguish.

So: do we treat the existing 12 tool migrations as wrong-shape work to undo, or as scaffolding that'll get demoted as we move to ad-only definitions? And — if we accept the ads-over-existing-functions frame — what does the implementation plan actually become?

---

## §6 — Knowing when not to use the LLM

**User:** no, i think what we have is fine... i think how we use it is what's in need of work. I want LLMAgent.perform() to be there for the kind of vague and arbitrary shit that llms are good at. and if i LLMAgent.perform.with_tool(tool[],"prompt") then great. (the syntax here is kind of irrelevant, but you see my point) But that could just be LLMAgent.perform("use Comn.Secret to lock the password you get from https://example.net") (again, syntax is kind of irrelevant, what matters is that LLMs are non-deterministic, in part because they have a many-roads kind of input function, and that is a powerful thing when you want it, but it also means that when you don't want it, you need to be able to know when *not* to use the llm.

**Claude:** That lands. The substrate doesn't change. What changes is **where the LLM lives in the call stack**.

Right now LLMAgent is at the *top* of the stack — you give it a prompt, it drives a loop, it dispatches tools, it decides when to stop. That makes the LLM the orchestrator. Under your frame, LLMAgent is at the *middle* of the stack — it's a function the orchestrator calls when the work is shaped like LLM work, and a deterministic dispatcher calls something else when the work is shaped like deterministic work.

The discriminator is exactly what you named — many-roads input. You reach for the LLM when:
- the input is vague ("summarize this")
- the input is natural language requiring translation ("what they meant was X")
- the work needs generation, not retrieval ("write a haiku")
- the steps aren't enumerable in advance ("figure out how to do X")

You DON'T reach for the LLM when:
- the work has a deterministic algorithm
- you already know the steps
- correctness matters more than fluency
- the function exists and works fine

So the missing piece is just a clean **call site** for "invoke LLM competence here." Something like:

```elixir
LLMAgent.perform("write a haiku about rain")
# → {:ok, "..."}  — blocking, no tools, one-shot

LLMAgent.perform("summarize this log", tools: [], context: log_text)
# → {:ok, "..."}  — blocking, explicit loadout (empty), context provided

LLMAgent.perform("use Comn.Secret to lock the password from https://example.net",
  tools: ["function.secret.*", "function.http.*"], timeout: 30_000)
# → {:ok, result}  — blocking, scoped loadout, longer timeout
```

Three things follow:

1. **The current LLMAgent GenServer is one mode, not THE mode.** The fire-and-forget prompt → events → durable history shape is right for "long-running interactive session" (chat UI, ongoing conversation). It's wrong for "I need fuzzy competence right now, give me the answer." The function-style entry point is what's missing.

2. **This makes the LLM addressable like any other competence.** The orchestrator calls `LLMAgent.perform/2` the same way it calls `Comn.Secret.lock/2` — both are functions that do something the orchestrator can't do itself, called when the orchestrator needs them, returning when done. The LLM is just the one with many-roads input.

3. **The function-calling spec collapses to "internals of `LLMAgent.perform`."** How the inner loop dispatches tools that the LLM-as-callee uses — that's still real work, but it's hidden behind the function boundary. The loadout, the tool_calls handling, the role-tool continuation — all of that is implementation detail of one function. It's not the user-facing API anymore.

What's actually missing in code, then, is a small, clear `LLMAgent.perform/1,2,3` function that:
- Spins up an ad-hoc agent (or a stateless inline call for tools-free invocations)
- Accepts an explicit loadout / policy override
- Blocks until completion (or returns a `Task` if you want async)
- Returns the final result, not a conversation
- Terminates cleanly when done

And the existing `LLMAgent` GenServer stays as the long-lived session shape, used when that's actually what you want (agento's chat UI, primarily).

---

## §7 — Orchestration as the discipline

**User:** no, an llm can be the orchestrator (but it doesn't have to be) and the orchestrator can orchestrate llms just like any other tool or resource. I guess the point is that orchestration, to me, is about scheduling tasks to task performers and disaggregating flows into task-sized things and distributing them for scheduling.

**Claude:** Right — I keep collapsing back to LLM-centric framing. The frame is **orchestration**, and the LLM is one possible orchestrator AND one possible task performer; neither role is intrinsic to it.

So the actual stack is something like:

```text
job (a thing to be done)
  ↓
orchestrator (decomposes job → plan; might be deterministic code, might be LLM, might be hybrid, might recurse)
  ↓
plan (sequence/graph of tasks)
  ↓
scheduler (routes tasks to performers; manages parallelism, sequencing, dependencies)
  ↓
task → task performer (function, LLM, sub-orchestrator, external service, human-in-the-loop)
  ↓
results compose back up the stack
```

Anyone can be the orchestrator. Anyone can be the performer. The substrate provides primitives, not roles. A function might be a performer in one orchestration and an orchestrator in another (recursive). An LLM might be a performer when called for translation and an orchestrator when given a job to decompose. The substrate doesn't pre-assign.

What we have, mapped to that frame:

| Layer | What we have | What's thin |
|---|---|---|
| **Job** | Free-form prompts; agent name/role | No explicit "job" object with declared inputs/outputs/success criteria |
| **Orchestrator** | One implementation: `LLMAgent` GenServer (LLM-driven loop) | No deterministic-orchestrator implementation; no hybrid; orchestrator-as-callable-interface is implicit |
| **Plan** | Lives in the LLM's working memory | No explicit plan object; no way for a deterministic orchestrator to declare one |
| **Scheduler** | Direct dispatch via `Tool.Dispatcher`; DynamicSupervisor for sub-agents | No queueing, no dependency graph execution, no parallelism management beyond `Task.Supervisor` |
| **Performer** | All twelve tool ads + mDNS-discovered LLM ads + (future) MCP ads | This part's actually well-built |
| **Policy** | `%LLMAgent.Tool.Policy{}` | Adequate |
| **Discovery** | `Tools.Discovery` | Adequate |
| **Composition** | Done implicitly by the LLM concatenating tool results into context | No explicit result-composition primitive; no fan-in pattern for sub-agents beyond tuple space |

The performer side is mature. The orchestration side is essentially the LLMAgent GenServer's prompt-tool-prompt loop, which is one orchestrator (and a particular kind — LLM-driven, conversational, persistent-history). We don't have:

1. **An explicit notion of a "job"** — something with a clear request, success criterion, and termination.
2. **An explicit "plan" object** — something a deterministic orchestrator could declare and a runner could execute.
3. **A general scheduler** — something that takes a plan + a policy and dispatches tasks, with dependencies, parallelism, retries, monitoring.
4. **An orchestrator-agnostic interface** — `Orchestrator.run(job, plan_strategy)` or similar, where the strategy is pluggable (one strategy uses an LLM to decompose; another uses a hand-written deterministic plan; a third uses a hybrid).
5. **Composition primitives** — fan-in, sequence, parallel-collect, conditional-branch. Probably want a small DSL or just well-named functions.

The Bayesian-chain agent loop from the broader vision sits on top of THIS — the chain isn't a function of the LLM, it's a function of the orchestrator's iterative plan-execute-update cycle. The orchestrator can be entirely deterministic and still run a Bayesian chain; the chain is the loop structure, not who-decides.

Question to focus the next move: where does the orchestration layer want to live in the existing code? Three options I can see —

(a) **New top-level module `LLMAgent.Orchestrator`** with `run/2`-style API; the existing `LLMAgent` GenServer becomes one implementation of an orchestrator-strategy (the LLM-driven one).
(b) **Generalize the existing `LLMAgent` GenServer** so its decision loop is pluggable — today it's hardcoded "ask LLM, dispatch, repeat"; that becomes one strategy module. Other strategies plug in.
(c) **Orchestrator is a new concept entirely** — separate from `LLMAgent`, separate supervisor tree, agents are one *kind of performer* it can dispatch to. The substrate stays unchanged; orchestration sits next to it.

I lean (c) — keeps the existing agent loop intact for the cases where it's right, makes orchestration its own subsystem with clear boundaries, doesn't try to retrofit. (a) and (b) tangle the new concept into code that already has its own shape.

---

## Where this leaves us

The native-function-calling spec (`docs/superpowers/specs/2026-05-19-native-function-calling.md`) was framed around making the LLM more reliable as the dispatcher. This brainstorm progressively undid that framing:

- §2: OpenAI/MCP tool calling is RMI in disguise; the substrate is the real protocol; sub-agent spawn replaces parallel tool calls.
- §3: There isn't ONE shape for the model→agent interface; there are at least four classes of cognitive ask (none, single tool, clerk, ambassador).
- §4: The LLM is the help, not the star. Orchestration is what's load-bearing.
- §5: The wrapper modules from the migration sprint were over-engineered; the substrate is metadata over functions, not re-implementations.
- §6: Don't conflate "agentic system" with "LLM-driven loop." `LLMAgent.perform/2` as the call-site lets the orchestrator decide when LLM competence is appropriate.
- §7: Orchestration is the real discipline. The LLM is one possible orchestrator AND one possible performer; the substrate is role-agnostic. What's missing is jobs, plans, schedulers, orchestrator-agnostic interfaces, composition primitives.

**Open threads to ruminate on:**

- Does the orchestration layer actually need to exist as new code, or can the existing substrate + a few small additions (`LLMAgent.perform/2`, an explicit "plan" data type) cover what's needed?
- What's the right shape for a plan? Sequential? DAG? Petri net? Something simpler?
- How does the Bayesian-chain idea map onto this — is the chain a property of the orchestrator, the plan, or the agent's iterations across jobs?
- The 12 tool wrapper modules from the migration: do they stay (as scaffolding for the still-coherent ad framework), get demoted, or eventually disappear in favour of ads-on-existing-functions?
- Where does `LLMAgent.perform/2` actually live — top-level public API, or behind an `Orchestrator` interface?
- Class 0–3 are useful descriptive categories, but should they be PRESCRIPTIVE (different code paths per class) or DESCRIPTIVE (the orchestrator picks based on context, all classes use the same primitives)?

**Status of the committed spec:** The function-calling spec at commit `0602456` is still on the branch. It is not invalidated — its lower-level points (LLMs need a clean way to emit structured calls when used; capability metadata belongs in ads; per-tool schemas as behaviour callbacks if we KEEP wrapper modules) still hold within their assumed scope. But its top-level framing (LLM as primary agent; tools[] as the contract) is the inversion the brainstorm just undid. Decision deferred: revise, replace, or keep as a sub-spec inside a larger orchestration design.
