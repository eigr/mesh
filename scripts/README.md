# MVP Actor System - Benchmarks

This directory contains benchmark scripts to test the actor system scalability.

## Available Scripts

### 1. `benchmark.exs` - Single-Node Benchmark
Tests performance on a single node.

```bash
mix run scripts/benchmark.exs
```

**Included tests:**
- Creation of 50,000 actors
- 10,000 invocations on the same actor (hot spot)
- Hash ring distribution
- Multi-capability
- Mixed load
- Latency measurement (P50, P95, P99)

### 2. `benchmark_multinode.exs` - Multi-Node Benchmark
Tests distributed performance with multiple Erlang nodes.

**⚠️ IMPORTANT:** This benchmark needs to be executed in distributed mode:

```bash
elixir --name bench@127.0.0.1 --cookie mvp -S mix run scripts/benchmark_multinode.exs
```

**DO NOT** execute with just `mix run`, use the complete command above!

**Included tests:**
- Distributed actor creation
- RPC latency between nodes
- Distributed mixed load
- Resilience (node failure simulation)
- Hash ring balancing

### 3. `test_multinode.exs` - Simple Multi-Node Test
Basic test to verify connectivity between nodes.

```bash
elixir --name test@127.0.0.1 --cookie mvp -S mix run scripts/test_multinode.exs
```

### 4. `benchee_benchmark.exs` - Professional Benchmarks with Benchee
Statistical benchmarks using the Benchee library with extended metrics.

```bash
mix run scripts/benchee_benchmark.exs
```

**Included tests:**
- Actor creation performance (100, 1k, 5k actors)
- Invocation performance (sequential vs parallel)
- Multi-capability comparison
- Hot spot contention analysis
- Hash ring distribution patterns

**Features:**
- Extended statistics (median, percentiles, standard deviation)
- Memory profiling per operation
- Comparison mode between scenarios
- Warmup and multiple iterations for accuracy

## Expected Warnings

### `:slave` module warnings
```
warning: :slave.start/3 is deprecated
```
**This is normal.** The `:slave` module will be replaced by `:peer` in OTP 29. For now, it still works perfectly.

### Errors during cluster initialization
```
[error] Process #PID<...> raised an exception
** (ErlangError) Erlang error: {:exception, {:undef, [{Capabilities, :_update_capabilities_from_remote...
```

**This is normal and expected.** During cluster initialization, nodes connect before the application is fully loaded, causing RPC attempts that fail. These errors are captured and do not affect system functionality.

**Why it happens:**
1. Node A and Node B connect
2. Capabilities on Node A detects `nodeup` from Node B
3. Tries to propagate capabilities via RPC
4. But the application is not yet loaded on Node B
5. RPC fails with `:undef` (function not found)
6. System ignores and continues normally

After complete initialization, the system works perfectly without errors.

## Expected Results

### Single-Node (85,000 actors)
- Creation throughput: ~16,000 actors/s
- Invocation throughput: ~30,000 req/s
- P95 latency: < 100μs
- Memory per actor: ~11 KB
- Success rate: 100%

### Multi-Node (4 nodes, ~10,000 actors)
- Creation throughput: ~8,000 actors/s
- Distributed throughput: ~8,000 req/s
- RPC latency: ~150μs
- Balanced distribution across nodes
- Success rate: >99%

## Support

For more information about the architecture, see the source code in `lib/mesh/`.
