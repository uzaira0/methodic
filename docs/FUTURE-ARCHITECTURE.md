# Future Architecture Considerations

## Durable Objects (Concept)

The pattern: **co-located compute + storage with single-threaded access per entity**. Essentially the Actor model with persistence.

| Property | Benefit for Chronicle |
|----------|----------------------|
| Single-writer per entity | No race conditions on participant data |
| State locality | Fast reads, no distributed coordination |
| Strong consistency | HIPAA audit trail integrity |
| Addressable by ID | Natural fit for `participant_id`, `study_id` |

### Self-Hosted Implementations

- **Dapr** (Microsoft, Apache 2.0) - sidecar pattern, any language
- **Orleans** (.NET, open source) - virtual actors
- **Akka** (Scala/Java) - already JVM, fits your stack
- **wasmCloud** - actors + WASM
- **Proto.Actor** (Go/.NET) - lightweight

### Application to Chronicle

```
┌─────────────────────────────────────────┐
│         Durable Object per Entity       │
├─────────────────────────────────────────┤
│ ParticipantActor(participant_id)        │
│   - Buffers incoming sensor data        │
│   - Enforces per-participant rate limit │
│   - Maintains enrollment state          │
│   - Single-writer = no conflicts        │
├─────────────────────────────────────────┤
│ StudyActor(study_id)                    │
│   - Aggregates metrics                  │
│   - Manages study state machine         │
│   - Coordinates participant events      │
└─────────────────────────────────────────┘
```

Use cases:
- **Sensor data ingestion** - buffer writes, batch to Postgres
- **Rate limiting** - per-participant state without Redis
- **Enrollment state machine** - clean transitions, no race conditions
- **Real-time aggregation** - study-level metrics without polling

---

## WASM/WASI Containers

WebAssembly as a portable, sandboxed runtime for server-side code.

### Self-Hosted Runtimes

- **Wasmtime** (Bytecode Alliance, most mature)
- **Wasmer** (universal, embeddable)
- **WasmEdge** (CNCF, optimized for cloud/edge)
- **Spin** (Fermyon, serverless WASM apps)
- **wasmCloud** (distributed WASM actors)

### Application to Chronicle

| Use Case | Why WASM |
|----------|----------|
| **Plugin system** | Researchers define custom data transforms in any language, sandboxed |
| **Questionnaire logic** | Complex branching/scoring without trusting arbitrary code |
| **Data validation rules** | Per-study custom validators, hot-reloadable |
| **Edge processing** | Pre-process on mobile before upload (WASM runs everywhere) |
| **Computed fields** | Derive values from sensor data without exposing raw PHI |
| **Anonymization functions** | Pluggable de-identification algorithms |

### Security Benefits

- Sandboxed execution (capability-based security)
- No filesystem/network access unless explicitly granted
- Memory-safe even for C/Rust code
- Deterministic execution (reproducible research)

---

## Combined: wasmCloud

**wasmCloud** (Apache 2.0) combines both concepts:
- Actors written in WASM
- Durable state via "capability providers"
- Location-transparent - actors can move between nodes
- Hot-swappable components

```
┌──────────────────────────────────────────────┐
│              wasmCloud Host                  │
├──────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐          │
│  │ Participant │    │   Study     │          │
│  │   Actor     │    │   Actor     │  (WASM)  │
│  │   (.wasm)   │    │   (.wasm)   │          │
│  └──────┬──────┘    └──────┬──────┘          │
│         │                  │                 │
│    ┌────┴──────────────────┴────┐            │
│    │    Capability Providers    │            │
│    ├────────────┬───────────────┤            │
│    │ PostgreSQL │ NATS/Kafka    │            │
│    │ Provider   │ Provider      │            │
│    └────────────┴───────────────┘            │
└──────────────────────────────────────────────┘
```

---

## Implementation Recommendations

| Timeframe | Approach |
|-----------|----------|
| **Short-term** | Hazelcast `EntryProcessor` for actor-like patterns - model participants as map entries with single-threaded processing |
| **Medium-term** | **Dapr** sidecar adds durable actors without rewriting JVM backend - language-agnostic, Kubernetes-native |
| **Long-term** | **wasmCloud** for plugin system where researchers contribute custom processing logic safely |
