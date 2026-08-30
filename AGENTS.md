# Repository Instructions

## Scope

These instructions apply to the entire repository.

## Project Definition

Fasyn is an Ada library and bounded asynchronous runtime that implements the
FastCGI 1.0 application-side interface completely.

The protocol authority is the FastCGI Specification, Document Version 1.0,
29 April 1996. Protocol completeness includes the application-visible initial
process state, FastCGI record framing, name-value encoding, all three roles,
management records, connection persistence, multiplexing, request lifecycle,
protocol status results, and the error behavior defined by that specification.

Fasyn is protocol infrastructure, not an application framework. Do not add HTTP
parsing, MCP semantics, JSON semantics, routing, templates, database facilities,
process management, NGINX configuration, or application-session policy.

## Clair Dependency

Use Clair for operating-system and runtime facilities that Clair already
provides. Do not duplicate a Clair abstraction inside Fasyn merely to avoid the
dependency.

By default, keep the public Clair checkout as a sibling of Fasyn at `../clair`,
or select another checkout with `FASYN_CLAIR_ROOT`. The corresponding source
repository is:

    https://github.com/hodong-kim/clair

Keep Fasyn-specific protocol state and policy in Fasyn. Keep generic operating
system, event, timing, I/O, signal, and related facilities in Clair when they
belong there.

## Engineering Principles

Follow `docs/architecture/engineering-principles.md`.

FastCGI 1.0 completeness is a defined product goal and is not speculative
generality. Features outside the FastCGI application interface require a
separate demonstrated requirement.

## Failure Model

Follow `docs/architecture/failure-model.md`.

Do not silently convert protocol errors, caller errors, external system
failures, application-handler failures, internal invariant violations, or
unexpected implementation failures into successful control flow.

## State Ownership

Do not introduce mutable global state or mutable package-level runtime
variables.

Runtime state shall be owned by explicit server, listener, connection, request,
executor, or other objects whose lifetimes are controlled by their owners.

Request identity shall not be represented by `requestId` alone. FastCGI request
IDs are reusable. Any asynchronous work that can outlive one request instance
shall be associated with an identity that distinguishes the connection and the
specific generation of the request ID.

## Resource Bounds and Backpressure

Follow `docs/architecture/resource-policy.md`.

Every externally amplifiable resource shall be bounded or accounted for.
Protocol field maxima are wire-format limits, not permission to allocate an
equivalent amount of resident memory.

Input and output streams shall support incremental processing. Backpressure
shall propagate toward the producer instead of allowing unbounded queues.

## Concurrency and Socket Ownership

Follow `docs/architecture/runtime-model.md`.

Only the I/O layer that owns a connection may perform reads or writes on that
connection socket. Worker tasks shall not write FastCGI bytes directly to a
socket.

Multiplexed output may interleave complete FastCGI records from independent
requests, but bytes belonging to one record shall never be corrupted by
concurrent writers.

Execution queues and worker pools shall be bounded.

## Protocol Correctness

Follow `docs/architecture/protocol-conformance.md`.

Parsers shall be incremental and shall not assume that a FastCGI stream element
or name-value pair is contained within one FastCGI record.

Management records that belong to the FastCGI library shall be handled by Fasyn
rather than forwarded to an application handler.

Do not weaken protocol validation to accommodate one particular web server.
Interoperability behavior may be specialized only when it remains conformant to
FastCGI 1.0.

## Testing

Follow `docs/architecture/testing-policy.md` and
`docs/development/testing.md`.

Use `Clair.Test` for Fasyn Ada tests. Use `Clair.Test.Reporter` for suites and
scenarios and `Clair.Test.Assertions` for assertions. Do not introduce standalone
Ada test executables based on `pragma Assert` or an independent assertion
framework when the test belongs in the Fasyn unit-test suite.

Protocol state machines, record codecs, incremental name-value decoding,
multiplexing, cancellation, request-ID reuse, resource limits, and partial I/O
shall have direct tests.

FastCGI 1.0 conformance claims require tests for every applicable item in
`docs/architecture/protocol-conformance.md`.

## Toolchain

Use GNAT and its Ada runtime toolchain for Fasyn.

Use the same target, ABI, and build assumptions as the Clair artifact linked
into Fasyn. Do not bypass Clair with ad-hoc native bindings when Clair already
owns the required platform boundary.

## Copyright Lineage

Fasyn originated in 2023. New Fasyn source files that carry a copyright range
shall preserve the 2023 start year; in 2026 the range is `2023-2026`.

Do not copy the Open Market, Inc. copyright from the historical bundled FastCGI
reference implementation into new Fasyn source unless code derived from that
implementation is actually carried forward. A clean Ada implementation based
on the public FastCGI specification retains Fasyn's own copyright lineage.

Do not infer a license marker from an example in the style guide. Use an SPDX
identifier only after the repository license defines it.

## Documentation

Follow `docs/README.md`.

Architecture documents own durable contracts and invariants. Roadmaps own
current delivery state and order. Development documents own reproducible build,
test, and contribution procedures. Temporary resume notes belong under
`docs/handoffs/` only when intentionally needed.

Do not create documentation solely to preserve conversation history. Update the
document that owns the subject.

## Style

Follow `docs/development/style-guide.md`.

That file is copied unchanged from Clair and is the shared Ada coding-style
baseline. Fasyn-specific architecture and safety requirements take precedence
where they are more restrictive.
