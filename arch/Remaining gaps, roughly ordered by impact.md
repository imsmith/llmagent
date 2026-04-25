  Remaining gaps, roughly ordered by impact and feasibility:                                                                                                                                                                         

  ┌────────────────────────────┬───────────────────────────────────────────────┬──────────────┬───────────────────────────────────────────────────────────────────────────────┐  │            Gap             │                Design Concept                 │  Difficulty  │                                     Notes                                                                                          
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ Session management         │ Conversations, resets, scoping                │ Medium       │ Builds on Memory — store/restore named sessions, not just :history            │                                                      
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ Tool access control        │ Policy/allowlist per agent                    │ Medium       │ Agent state carries a tool policy; dispatch_tool checks before calling    │                                                      
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ Chain/pipeline abstraction │ Composable prompt→tool→result flows           │ Medium       │ The agent loop is a chain; question is whether to make it explicit/composable │
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ Extension model            │ Add tools without modifying source            │ Medium       │ Tool registry from config or discovery instead of hardcoded Tools module      │
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ Tuple space                │ Linda/JavaSpaces for multi-agent coordination │ Hard         │ The BEAM differentiator — ETS-backed out/in/rd with pattern matching          │
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ Streaming                  │ Chunked LLM responses                         │ Medium       │ Needs LLMClient behaviour extension + GenServer callback changes              │
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ NATS integration           │ Cross-runtime messaging                       │ Medium       │ Comn already has Comn.Events.NATS — wire it through EventBus                  │
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ Retriever/RAG              │ Vector store retrieval                        │ Hard         │ Needs external dependency (pgvector, Pinecone, etc.)                          │
  ├────────────────────────────┼───────────────────────────────────────────────┼──────────────┼───────────────────────────────────────────────────────────────────────────────┤
  │ DSL macros                 │ deftool, defchain                             │ Low priority │ Correctly deferred — semantics aren't stable enough yet                       │
  └────────────────────────────┴───────────────────────────────────────────────┴──────────────┴───────────────────────────────────────────────────────────────────────────────┘

  The tuple space is the architectural differentiator. Session management and tool access control are the most practical next steps. What's pulling you?
