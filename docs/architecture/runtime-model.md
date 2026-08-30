# Runtime Model

## Layers

Fasyn is divided conceptually into five layers.

### Protocol

Owns:

- FastCGI record codec;
- name-value codec;
- protocol validation;
- request and stream state machines;
- role semantics;
- management records;
- protocol status generation.

The protocol layer does not own sockets or worker threads.

### I/O

Owns:

- listeners and accepted transports;
- nonblocking reads;
- partial record input;
- partial writes;
- connection output serialization;
- connection close progress.

Only this layer may perform transport I/O on a connection it owns.

### Runtime

Owns:

- connection objects;
- active request tables;
- request generations;
- multiplexing;
- resource accounting;
- timers;
- backpressure;
- cancellation;
- shutdown coordination.

### Execution

Owns application work dispatch through a bounded interface.

A bounded worker pool is the initial/default execution mechanism. Protocol
correctness shall not depend on the concrete worker-pool implementation.

### Application API

`Fasyn.Request` is the role-neutral request/application namespace shared by
Responder, Authorizer, and Filter. Its request context, writer, exchange, and
runtime child packages apply the same lifecycle model to all three roles.

The application API presents request input and response operations without
exposing FastCGI record framing.

Application code shall not need to write record headers, zero-length EOF
records, or `FCGI_END_REQUEST` records directly.

#### Deferred Application Completion

An application may transfer terminal response completion out of its executor
callback through an opaque deferred request handle. Deferral is permitted only
after request input is complete for the active role: Responder `STDIN` end,
Authorizer `PARAMS` end, or Filter `DATA` end. This keeps deferred lifetime
separate from executor callback lifetime without creating a second input-buffer
policy.

The handle identifies one connection/request generation and never exposes the
connection, socket, or FastCGI record writer. A successful defer closes the
callback-scoped writer for further application use. Later STDOUT, STDERR, and
terminal completion submissions are staged as bounded logical commands. For
these deferred commands, FastCGI record encoding occurs when the connection
event loop consumes the command and mutates the request's bounded response
state. A synchronous executor callback differs: its callback-scoped `Writer`
encodes complete FastCGI records into bounded work-item storage before the
connection accepts that completion. In both paths, only the connection owner
serializes accepted output and performs transport writes.

Deferred requests continue to own their request slot, request timer, and shared
admission charge until terminal retirement. The executor worker is released as
soon as the callback returns. A retired generation remains distinguishable to
any surviving handle so late output cannot target a reused FastCGI request ID.

Abort, request timeout, resource cancellation, connection failure, and runtime
shutdown retire deferred work and make later output/completion submissions fail.
Cancellation observation remains available through the deferred handle while
that handle exists.

## Connection Ownership

A connection owns:

- its transport handle;
- incremental input parser state;
- active request table;
- connection-local request-generation counters or equivalent identity state;
- serialized output queue/state;
- connection resource accounting;
- connection close state.

No worker may perform I/O on the connection socket.

## Request Ownership

A request owns:

- request ID and generation identity;
- role;
- `FCGI_KEEP_CONN` state relevant to its completion;
- PARAMS decode state;
- STDIN state;
- DATA state where applicable;
- output stream state;
- cancellation state;
- timeout/deadline state;
- per-request resource accounting;
- application execution state.

A request object becomes unreachable for new protocol work after finalization,
but stale asynchronous work may still exist temporarily. Generation checks
shall make that stale work harmless.

## Multiplexed Output

Synchronous executor callbacks encode complete FastCGI record bytes through a
bounded callback-scoped `Writer`. Deferred producers instead stage bounded
logical output commands; the connection event loop encodes those commands when
it consumes them.

The connection output path admits completed output into bounded request and
connection state and is the only path that serializes FastCGI bytes to the
socket. Workers and deferred producers never perform connection transport I/O.

Records belonging to different request IDs may be interleaved where the
protocol permits. Bytes from separate records shall never race on the socket.

## Incremental Input

The connection parser consumes arbitrary socket fragments.

Record content is delivered incrementally to the request state machine. PARAMS
name-value decoding maintains state across record boundaries and input-buffer
boundaries.

Input buffering is controlled by `resource-policy.md`.

## Cancellation

`FCGI_ABORT_REQUEST`, request timeout, resource-limit enforcement, runtime
shutdown, and connection failure may all initiate cancellation through distinct
causes.

Cancellation is recorded in request state and propagated to execution through a
cancellation mechanism. Finalization prevents later output from the cancelled
generation from entering the connection writer.

## Shutdown

Shutdown has two separate concerns:

- stop admitting new connections and requests;
- finish, cancel, or terminate existing work within a bounded grace policy.

Closing the runtime shall not permit callbacks, queued jobs, timers, or native
resources to outlive the objects that own them.

Classic FastCGI `SIGTERM` integration is a platform/lifecycle boundary. Fasyn
shall support the required behavior without silently assuming exclusive
ownership of the host process.

## Clair Boundary

Use Clair for generic platform facilities that meet Fasyn's requirements.

Do not encode FastCGI protocol semantics into Clair. Do not duplicate generic
platform abstractions inside Fasyn merely because FastCGI uses them.
