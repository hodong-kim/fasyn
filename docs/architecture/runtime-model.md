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

A connection with zero active application requests owns one idle-connection
deadline. It is not a transport-inactivity timer: arbitrary peer bytes and
management records do not reset it. The first admitted request transfers
lifetime authority to that request's deadline, and retirement of the last
KEEP_CONN request re-arms the idle deadline. This prevents byte-trickle peers
from retaining a bounded admission/descriptor slot indefinitely.

Runtime identity is monotonic within its ownership domain. An executor assigns
nonzero connection identities without reuse for the lifetime of that executor
Context, including reinitialization of the same Context object; exhausting the
64-bit space rejects further connection identities. A connection likewise
assigns each admitted request a nonzero generation that is never reused while
that connection identity exists. The final generation may be used once, after
which a later `BEGIN_REQUEST` fails closed and the connection is torn down rather
than wrapping to an identity that a stale asynchronous handle could still name.
A newly initialized transport receives a fresh executor connection identity and
therefore begins a new request-generation namespace.

### Execution

Owns application work dispatch through a bounded interface.

A bounded worker pool is the initial/default execution mechanism. Protocol
correctness shall not depend on the concrete worker-pool implementation.

Execution completion objects are limited callback-scoped views. Their backing
work item is reclaimed after the completion callback returns, so completion
objects cannot be copied or retained for later access. The supported
`Fasyn.Request.Execution` surface exposes logical single-operation submission,
completion, capacity, cancellation, lifecycle, observability, and the deferred
completion inspection required by public completion handlers. Connection batch
submission and the concrete internal deferred chunk size are runtime
coordination details and remain under the unsupported
`Fasyn.Request.Execution.Internal` child rather than becoming compatibility
commitments. Execution admission is
reserved before allocating or copying a peer-amplifiable work-item payload;
queue saturation therefore applies backpressure without allocation churn. A
cancellation arriving between reservation and work-item binding is retained by
the reservation and applied when the callback context becomes available.

Valid wire fragmentation is decoupled from application scheduling. After the
FastCGI/request state machines have validated input, a connection may collect
adjacent work for the same request and stream into one bounded application
operation. PARAMS work preserves one `on_parameter` call per decoded pair but a
worker item carries at most 64 pairs. STDIN and DATA may be delivered as larger
ordered chunks spanning FastCGI record and socket-read boundaries; those wire
boundaries are not application semantics. Request/type transitions, terminal
callbacks, batch capacity/reserve limits, and the end of one owner-thread I/O
pass bound latency and work size. The connection owns one reusable batch buffer,
not one batch allocation per record/request slot.

Combined data-plus-terminal worker items disable terminal-only deferral while
running intermediate callbacks and restore it only for the role's legal terminal
callback. Filter output gating is preserved across combined PARAMS/STDIN work.
Normal Work_Item Writer storage is sized from the callback's actual usable
output limit; non-writing work keeps only minimal internal storage.

Worker completion and deferred-output publication share one payload-free Clair
event-loop notification source. Producers publish authoritative bounded state
before signaling. Each notification callback processes at most 64 worker
completions, 64 executor-capacity waiter attempts, and 64 deferred commands.
Ordinary completed Work_Items also have a 128 KiB owner-delivery byte budget.
If one completed response exceeds that budget, Execution retains the Work_Item
and resumes it on a later notification, exposing only complete FastCGI record
boundaries to the connection. The owning connection keeps its application work
paused and `inflight_jobs` charged until the final slice arrives, while worker
admission is released as soon as worker execution itself completes.

Deferred STDOUT/STDERR handoff uses the same 128 KiB encoded-byte budget. A
large staged command remains executor-owned across notifications; non-final
slices end only on the fixed 16 KiB deferred chunk boundary so the connection
can encode each slice without splitting a logical deferred chunk. Request and
connection staged-byte reservations are reduced only for slices accepted by the
owner callback, and connection busy/processing state remains held until the
final slice. Cancellation between slices retires the retained command and
releases the still-authoritative remaining reservation without delivering a
later slice.
When a completion releases admission, existing FIFO capacity waiters get a
bounded progress opportunity before that completion handler may submit follow-up
work. Normal submissions cannot leapfrog an older waiter; only the waiter being
dispatched may make its retry attempt. This prevents a continuously active
connection from repeatedly reacquiring capacity ahead of older waiters.

Executor saturation uses no periodic retry timer. A connection whose bounded
executor submission is refused registers one caller-owned intrusive FIFO wait
node; registration, removal, and dispatch are event-loop-owner operations and
perform no per-wait allocation. If a woken waiter finds the Worker Pool pending
queue still transiently full, it requeues and waits for a later real completion
instead of self-signaling. If one notification exhausts the 64-waiter budget
without such a requeue, the remaining bounded capacity progress is re-signaled
for a later dispatch. Capacity-wait handler failures preserve the first failure
while unused capacity may continue to later FIFO waiters in the same bounded
pass.

A connection removes its node in O(1) before close, timeout retirement, or
shutdown, and executor shutdown/finalization rejects a live or currently
dispatched waiter so no stale connection address can survive its owner. Worker
completion, deferred work, and carried bounded capacity progress are re-signaled
when work remains, so an acknowledged wake cannot strand authoritative work.

Connection socket callbacks combine count and byte fairness bounds. A single
owner dispatch performs at most 16 ordinary reads and 16 writes, while ordinary
input parsing and native output transmission each have an independent 64 KiB
byte budget. Configured `read_buffer_bytes` and `write_chunk_bytes` may be
larger, but one callback cannot consume those larger capacities in full.
Buffered input and partial output records remain authoritative and resume on a
later owner dispatch.

An idle executor therefore uses no periodic completion or saturation-poll timer.
The notification signaler lives with the reference-counted deferred target so a
deferred handle that outlives executor finalization cannot retain a pointer into
released executor storage. A signal failure never rolls back worker completion
or deferred command publication; the authoritative queued work remains owned,
and the first progress-signal failure is retained separately and surfaced by
the executor when its owner-thread notification path next runs. Setup-failure
cleanup releases a signaler only after the unstarted Worker Pool has stopped and
finalized.

### Application API

`Fasyn.Request` is the role-neutral request/application namespace shared by
Responder, Authorizer, and Filter. Its request context, writer, exchange, and
runtime child packages apply the same lifecycle model to all three roles.

The application API presents request input and response operations without
exposing FastCGI record framing. `on_stdin` and `on_data` receive ordered stream
chunks whose boundaries are selected by bounded runtime scheduling; applications
must not infer FastCGI record or socket-read boundaries from callback sizes.

A Connection keeps at most one application job in flight, so callbacks for one
connection are serialized. The executor may run jobs from different connections
concurrently. If multiple connections share one `Application` instance, that
instance may therefore receive simultaneous callbacks on different worker tasks.
Shared mutable application state must be synchronized by the application, or the
embedding must provide separate Application instances. Fasyn deliberately does
not add process-wide Application serialization.

A callback `Context` exposes the first cancellation cause observed for its exact
request generation. Executor cancellation may publish that cause while the
application callback is running, so the Context's internal cancellation state is
thread-visible atomic state. Direct `Request.Exchange` processing may construct a
fresh Context for each synchronous callback; that state therefore remains
lock-free and does not acquire an OS-backed lock per callback.

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

The executor indexes deferred request generations and maintains one bounded
aggregate per connection for direct/staged output occupancy, connection output
limit, and connection busy state. Staged commands are linked in per-connection
FIFO order, while a separate ready-connection FIFO contains at most one marker
per runnable connection. Taking one command marks that connection busy before
another sibling can run, preserving connection-owned serialization without
full deferred-table readiness scans.

When a deferred producer receives `Deferred_Would_Block`, that attempt records
request and connection writable epochs and grants one wait token. A later write
attempt supersedes the token. `wait_writable` consumes it: if either epoch has
advanced in the meantime, it returns immediate readiness instead of registering,
closing the lost-wakeup race between a failed write and waiter registration.
Otherwise it can register a caller-owned one-shot writable waiter on that exact
request generation. The executor stores at most one queued waiter per request
and groups queued waiters by connection. A separate ready-wait connection FIFO
is edge-triggered by
output-drain, busy-to-ready, processing-completion, cancellation, and shutdown
state changes. The owner notification dispatches at most 64 waiter callbacks per
pass and re-signals if more remain. A waiter callback runs on the executor's
owning Event Loop and supplies only the request identity; it does not transfer
connection ownership or reserve output capacity. The producer retries and may
register another one-shot waiter if the retry still would block. Cancellation or
retirement wakes a queued waiter so the producer can observe `Deferred_Closed`
instead of waiting forever.

Abort, request timeout, resource cancellation, connection failure, and runtime
shutdown retire deferred work and make later output/completion submissions fail.
Cancellation observation remains available through the deferred handle while
that handle exists.

## Package Ownership

Public package placement follows the state it owns rather than implementation
convenience. `Fasyn.Protocol` owns wire-domain values, while
`Protocol.Bodies` owns fixed bodies for records such as `BEGIN_REQUEST` and
`END_REQUEST`, while `Protocol.Codec` owns complete record framing.
`Fasyn.Request` owns the role-neutral request identity, callback Context, Writer,
Exchange state machine, and deferred response handle.

`Fasyn.Request.Connection` and `Fasyn.Request.Execution` remain Request children
because their implementations cooperate directly with Request's private
Writer/Exchange/deferred state. Moving either package out of the Request
hierarchy would require an artificial facade over that private state and would
increase coupling. The unsupported `Request.Execution.Internal` child is only
for sibling runtime coordination and is not a compatibility surface.

Shared facilities that do not depend on Request's private view live at the Fasyn
root. `Fasyn.Admission` owns connection/request quota accounting across runtime
objects, and `Fasyn.Shutdown` coordinates connections, the shared executor, and
the Event Loop. `Fasyn.Listener` and `Fasyn.Classic` likewise own connection
admission rather than per-request state. Do not nest a shared runtime facility
under Request merely because Request consumers happen to call it.

Listener readiness is also bounded work. One `Fasyn.Listener` callback accepts at
most 16 queued transports before yielding to the Event Loop and stops immediately
on native would-block. An accepted descriptor remains Listener-owned until the
application accept callback returns `OK`; a non-OK return or escaping exception
causes Listener to close that still-owned descriptor before propagating the
status. The listening descriptor itself remains caller-owned and has its original
blocking mode restored on successful finalization.

An accept callback that receives `Cleanup_Pending` from
`Request.Connection.initialize` shall not let Listener close that descriptor
while provider cleanup still requires it. The callback may finalize the
Connection synchronously before returning non-OK, or return `OK` to accept
descriptor ownership and retain it until Connection finalization removes the
lifetime obligation.

Connection initialization is an explicit ownership transaction. A fresh or
successfully finalized Connection is **Reusable**. Successful timer/watch
registration commits the Connection to **Active**. Connection close, terminal
runtime cleanup, or incomplete initialization cleanup moves it to
**Finalization_Required**; only successful `finalize` returns it to
**Reusable**. Reinitialization before that transition is rejected.

`initialize` reports a separate `Initialization_Outcome`. `Activated`
transfers descriptor close ownership to the Connection. `Capacity_Refused`
and `Failed_Releasable` leave the descriptor immediately releasable by the
caller. `Cleanup_Pending` means Clair retained Event Loop cleanup state: close
ownership remains with the caller, but the same underlying descriptor must stay
open until Connection finalization succeeds. The shared connection-admission
slot also remains held through `Cleanup_Pending`, so failure retention stays
inside the aggregate connection bound.

The initial idle timer is prepared before descriptor-watch registration. Clair
`add_watch` distinguishes complete failure cleanup with `NULL_SOURCE` from
cleanup-pending failure with a retained source handle. Fasyn stores that
retained source handle directly and retries its removal during finalization;
it does not
duplicate Event Loop source ownership. Request admission acquired for a
`BEGIN_REQUEST` is either attached to the newly allocated request slot or
released before any failure path closes the connection.

## Runtime Context Extensibility

Runtime owner objects such as `Fasyn.Listener.Context`, `Fasyn.Classic.Context`,
`Fasyn.Request.Execution.Context`, and `Fasyn.Request.Connection.Context` are
limited private ownership contexts, not application extension points. They shall
not be tagged merely so implementation callbacks can inherit Clair or Fasyn
handler interfaces.

Event-loop, timer, completion, capacity, and listener dispatch are implemented
through private adapter objects composed inside their owning Context. The
adapter may retain a pointer to that owner only while the corresponding
registration can still dispatch. Operations that establish such retained owner
addresses use an `aliased in out` Context formal so the required address
stability is explicit in the Ada source contract; the caller keeps that aliased
Context alive until successful finalization removes the registrations.

Consumer extensibility is exposed deliberately through interfaces such as
`Fasyn.Request.Application`, `Fasyn.Listener.Accept_Handler`, diagnostic
reporters, completion/capacity handlers, and deferred writable waiters. Do not
make an owning Context derivable when a private composition adapter can provide
the required implementation dispatch.

## Connection Ownership

A connection owns:

- its transport handle;
- incremental input parser state;
- active request table;
- connection-local request-generation counters or equivalent identity state;
- serialized output queue/state;
- connection resource accounting;
- connection close state.

The active request table allocates neither full request payloads nor configured
pointer/index capacity on an idle connection. Lightweight pointer/index storage
grows geometrically with concurrent-request high-water up to the configured
limit. Request payload state, including the request writer and PARAMS decoder
storage, is allocated lazily as the same high-water increases and is retained
for bounded reuse after retirement. A completed request remains on the retirement
queue until removal of its request timer succeeds; only then may its slot return
to the free list. Timer cleanup failure therefore cannot silently detach a live
timer from retirement discovery or permit that slot to be reused by a later
request generation.

Variable-size connection stream/deferred buffers and output-send scratch storage
are connection-owned heap allocations. I/O callbacks therefore do not place
`read_buffer_bytes`, `write_chunk_bytes`, or request-count-sized scratch arrays
on the event-loop task stack. Successful sends advance the owning bounded output
buffer immediately, preserving record serialization without a deferred
per-callback consumption array.

PARAMS delivery likewise does not materialize decoded-length task-stack arrays.
A completed name-value pair is visited synchronously through callback-scoped
`Byte_Array` views over the request decoder's bounded storage, then the decoder
is reset for the next pair. The application callback lifetime rule therefore
also protects these borrowed views from escaping their owning request state.

No worker may perform I/O on the connection socket. A connection and the
executor that delivers its completions shall use the same event-loop context.
Connection initialization rejects a loop mismatch so socket, timer, and
completion callbacks mutate connection state through one serialized event-loop
boundary rather than cross-loop locking. The executor also owns the nonzero
connection-identity sequence used by its connections. It never reuses an issued
identity within that Context, including after executor reinitialization, so
caller-selected duplicate IDs cannot alias executor admission, cancellation, or
deferred accounting.

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

The connection parser consumes arbitrary socket fragments. If application work
pauses while only part of the next FastCGI header has been decoded, the bounded
paused-ABORT probe stays disabled until the decoder is again at a true record
boundary. Partial header bytes therefore remain owned by the normal decoder and
cannot be reinterpreted as a fresh probe header.

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
