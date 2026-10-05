# Security Model

Fasyn treats every FastCGI peer byte and peer-controlled timing decision as
untrusted. Security work therefore focuses on preserving bounded resource use,
protocol state isolation, and deterministic recovery when a peer is malformed,
slow, adversarial, or intentionally saturates configured limits.

Fasyn is protocol infrastructure, not an authentication or transport-security
layer. A deployment that requires peer authenticity or confidentiality shall
restrict the FastCGI transport with operating-system access control, a local
Unix-domain socket, loopback/firewall policy, a trusted front end, or another
appropriate deployment boundary. Fasyn does not add TLS or application
authentication semantics to FastCGI.

## Trust Boundaries

The FastCGI peer is untrusted. Record fields, declared lengths, fragmentation,
request IDs, role selection, stream ordering, multiplexing patterns, connection
timing, read behavior, and write-drain behavior may all be chosen to maximize
resource use or trigger edge cases.

Fasyn callers and application callbacks are inside the process trust boundary.
They may be buggy and their documented failures are contained where practical,
but Fasyn is not a sandbox for hostile application code with process memory or
descriptor access. Configuration is likewise caller-controlled and validated as
a caller contract rather than treated as hostile wire input.

Clair and the operating system are trusted implementation dependencies, while
their expected resource and system-call failures remain external failures under
`failure-model.md`.

## Security Properties

### Memory and Allocation

Peer-declared lengths shall never directly authorize proportional resident
allocation. Every peer-amplifiable buffer, queue, table, deferred command, and
execution path shall be bounded or accounted for before allocation or copy.
Integer arithmetic used in resource accounting shall reject unrepresentable
results before resource commitment.

### CPU and Scheduling

One peer shall not obtain work disproportionate to accepted protocol progress
through fragmentation, saturation, repeated retry, or configured-capacity
scans. Hot-path work shall be byte/count bounded per dispatch and data
structures used for attacker-selected identifiers shall avoid avoidable linear
work multiplied by configured capacity. Recovery and shutdown may use bounded
linear passes when they are not attacker-repeatable hot paths.

### Connection and Descriptor Lifetime

Connection admission shall bound simultaneous owned transports. A peer shall
not be able to retain an admitted descriptor forever merely by withholding a
complete request or trickling partial framing. Once a request is active, its
request lifetime remains authoritative through cancellation and required output
drain. When no application request is active, a separately bounded idle
connection policy shall limit descriptor retention.

### Protocol and Request Isolation

Malformed peer input may terminate the affected request or connection according
to the documented failure scope, but shall not corrupt unrelated request state.
Request identity includes connection identity and request generation so stale
asynchronous work cannot target a reused FastCGI request ID.

### Backpressure and Slow Peers

A peer that stops reading shall not cause unbounded output growth. Output,
control responses, worker completion, deferred production, and writable waiters
remain bounded and backpressure propagates toward producers. A peer that stops
providing required input shall be bounded by the applicable connection or
request lifetime.

### Failure Containment

Peer errors, external failures, application callback failures, and internal
invariant failures remain distinct. Cleanup shall not turn failure into success,
leak owned descriptors or admission capacity, or expose stale output after
cancellation. Diagnostic callbacks are a side channel and their failure shall
not corrupt protocol/runtime state.

## Security Validation

Security-sensitive changes require deterministic regression tests for the
property being changed. Parser and name-value decoders remain fuzz targets.
Resource limits require below/exact/above coverage, and attack-shaped runtime
scenarios shall include slow/partial peers, saturation, request-ID churn,
cancellation races, and recovery after the hostile condition ends.

Long-running and high-scale validation shall additionally look for memory/FD
growth, CPU amplification, starvation, generation/identity exhaustion, timer or
notification storms, and cleanup that becomes progressively more expensive over
time. A discovered fuzz or stress failure becomes a deterministic regression
test before the corresponding audit item is closed.

## Non-Goals

Fasyn does not promise isolation from arbitrary hostile code running in the same
process, does not authenticate FastCGI peers, and does not replace host firewall,
Unix permission, service-manager, privilege-separation, or reverse-proxy policy.
Those deployment controls complement rather than weaken the runtime properties
above.
