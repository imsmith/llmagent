Remaining gaps, roughly ordered by impact and feasibility:

| Gap | Design Concept | Difficulty | Status | Notes |
| --- | --- | --- | --- | --- |
| Tuple space | Linda/JavaSpaces for multi-agent coordination | Hard | Done | ETS-backed out/in/rd with pattern matching in `lib/llmagent/tuple_space/`; tool wrapper at `lib/tools/tuple_space.ex` |
| Tool access control | Policy/allowlist per agent | Medium | Done | `allowed_tools` enforced in dispatch; agent state carries the policy |
| Agent orchestration | Spawn/kill/list/status subagents | Medium | Done | `lib/tools/agent.ex` + `LLMAgent.AgentSupervisor`; children write results to tuple space, parent monitors for orphans |
| Session management | Conversations, resets, scoping | Medium | Open | Builds on Memory — store/restore named sessions, not just :history |
| Chain/pipeline abstraction | Composable prompt→tool→result flows | Medium | Open | The agent loop is a chain; question is whether to make it explicit/composable |
| Extension model | Add tools without modifying source | Medium | Substrate done, migrations in progress | Discovery substrate landed 2026-05-03 (`Tools.Discovery`, `Tool.Dispatcher`, six canonical kinds, open binding registry). First real consumer landed 2026-05-07: mDNS-driven LLM endpoint discovery via `priv/discovery/avahi-llama.tcl` → `Discovery.PortAdapter`. Per-tool migrations from the legacy `LLMAgent.Tools` registry are next. |
| Streaming | Chunked LLM responses | Medium | Open | Needs LLMClient behaviour extension + GenServer callback changes |
| NATS integration | Cross-runtime messaging | Medium | Open | Comn already has Comn.Events.NATS — wire it through EventBus |
| Retriever/RAG | Vector store retrieval | Hard | Open | Needs external dependency (pgvector, Pinecone, etc.) |
| DSL macros | deftool, defchain | Low priority | Deferred | Semantics aren't stable enough yet |

Of the remaining open items, session management and the extension model are the most practical next steps. NATS would unlock cross-runtime work. What's pulling you?
