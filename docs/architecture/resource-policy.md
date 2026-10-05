# Resource Policy

Fasyn is bounded by design.

FastCGI wire-format maxima describe what can appear on the protocol. They do not
define how much memory, concurrency, queue space, or execution capacity Fasyn
must grant to one peer.

## Required Limits

The runtime shall provide bounded policy for at least:

- simultaneous transport connections;
- simultaneous requests globally;
- simultaneous requests per connection;
- total PARAMS bytes per request;
- individual parameter-name bytes;
- individual parameter-value bytes;
- total STDIN bytes per request;
- total DATA bytes per Filter request;
- resident input buffering per request;
- resident output buffering per request;
- resident output buffering per connection;
- aggregate resident output buffering across admitted runtime work;
- worker count;
- pending execution jobs;
- request lifetime;
- idle read lifetime where applicable;
- stalled write lifetime where applicable;
- graceful shutdown lifetime.

Exact public configuration names are not fixed by this document.

## Admission

Check capacity before accepting work whenever the protocol permits rejection at
that point. Execution queue admission shall be reserved before allocating or
copying a work-item payload, so sustained saturation cannot amplify into
repeated large allocation/copy/free cycles. A connection blocked by bounded
executor submission capacity waits through a caller-owned intrusive FIFO node
and receives retry opportunities from owner-thread completion progress. If the
Worker Pool pending queue is still transiently full, the waiter requeues and
waits for a later completion rather than self-polling. Saturation shall not
create a per-connection retry timer, periodic wakeup, or allocation per retry.

Global request-capacity exhaustion maps naturally to `FCGI_OVERLOADED` when the
FastCGI specification defines that result for the situation.

Per-connection multiplexing refusal maps to `FCGI_CANT_MPX_CONN` when required.

Once a request has been admitted, later stream-policy violations are request
failures, not excuses to relabel every failure as overload.

## Streaming Versus Buffering

Accepted total stream length and resident buffer size are distinct policies.

For example, Fasyn may permit a very large STDIN stream while holding only a
small bounded window in memory.

PARAMS decoding shall also be incremental. A valid name-value pair may cross
FastCGI record boundaries; the decoder shall not require an entire PARAMS stream
or entire peer-declared value to be resident before progress can occur.

Wire fragmentation does not define executor work granularity. The connection
may coalesce adjacent application input for the same request and stream after
protocol decoding. One connection-owned bounded batch buffer is used rather
than one buffer per request slot or one allocation per record. Its capacity
keeps enough reserve for one maximum next callback, so a partially filled batch
cannot turn a later valid maximum-size pair or stream chunk into a false
resource/protocol failure. PARAMS batching is additionally capped at 64 pairs
per worker item. Request/type changes, stream EOF, batch bounds, and the end of
one owner-thread dispatch pass provide bounded flush points.

Management `FCGI_GET_VALUES` matching shall likewise remain bounded. Unknown
name/value contents are consumed without retaining buffers proportional to
peer-declared lengths.

## Output Backpressure

Each connection has one serialized output path.

When an output budget is exhausted, application production shall stop, suspend,
fail according to documented policy, or otherwise propagate backpressure. The
runtime shall not continue appending to an unbounded queue.

A slow peer shall not be able to consume unlimited memory by preventing output
drain. Per-request serialized output uses bounded circular storage so partial
writes advance a logical head rather than repeatedly moving the remaining
payload. Executor work items reserve Writer storage from the output bytes that
the job can actually use, not from the executor-wide maximum. A callback with
no writable output retains only the minimal internal sentinel required by the
positive Writer discriminant.

Protocol-defined control responses are subject to the same bounded-output
principle. If a valid `FCGI_GET_VALUES_RESULT`, `FCGI_UNKNOWN_TYPE`,
`FCGI_OVERLOADED`, or `FCGI_CANT_MPX_CONN` response cannot be queued because of
transient output pressure, input progress pauses while at most one semantic
control response is retained. Output drain resumes encoding and input progress;
transient control-buffer pressure is not a protocol error.

Fasyn does not maintain a separate process-global output-byte counter. A
process-wide bound is composed from shared connection/request admission,
per-request and per-connection output budgets, and bounded executor and deferred
queues. No component may introduce an unbounded output queue merely because the
aggregate limit is composed rather than represented by one counter.

Deferred application output uses the same request and connection output budgets.
Its request table and staged commands are separately bounded, capacity is
reserved before payload allocation, and transient pressure is reported as
backpressure rather than extending an unbounded queue. Retired generations may
retain one bounded table entry while a deferred handle still exists so late
output remains generation-safe. A configured deferred capacity of zero disables
application response deferral while preserving synchronous execution and
completion delivery; the internal notification target may still keep minimal
implementation storage that is not application-admission capacity.

Deferred producers never perform connection transport I/O. The connection
event loop remains the only owner of socket serialization. Direct request-output
occupancy is maintained as an aggregate and synchronized when one request
Writer's pending length changes; ordinary connection-budget queries therefore
do not rescan every active request. Backpressure work shall be driven by state
changes that can alter output occupancy, not by every payload byte, so bounded
accounting does not create an input-size multiplied by capacity CPU cost.

Deferred request and connection identity lookup shall use balanced indices
embedded in the fixed-capacity deferred tables. Lookup, insertion, and removal
therefore remain O(log live deferred entries/connections) in the worst case
without per-index allocation or collision-degenerate hashing. Separate dense
active arrays use append/swap removal where bounded iteration is required.
Per-connection staged-byte accounting and ready-command discovery use aggregate
or intrusive state. Ordinary synchronization and notification progress shall not
scan the full configured deferred capacity. Shutdown may make one bounded linear
retirement pass, and retired-command reclamation shall continue from prior
progress rather than restart a full-capacity scan for each command.

Attacker-selected FastCGI request IDs are indexed in reusable request-slot
storage with a balanced tree, so lookup, admission, and retirement remain
O(log active requests) in the worst case without a per-request index allocation.
A separate dense active-slot list supports O(1) append/swap removal and bounds
round-robin output-source discovery by the current active-request count rather
than historical slot high-water. Request timeout callbacks identify their slot
directly through a slot-local adapter instead of scanning allocated slot
capacity.

Completion retirement is transition-driven rather than discovered by repeatedly
scanning all active requests. When a completed request's direct output reaches
zero, its reusable slot is linked at most once into an intrusive ready-retirement
queue. Normal settling consumes only those ready slots. Whole-capacity scans are
reserved for bounded teardown or test-only invariant checking rather than
attacker-repeatable callback paths.

A deferred producer that observes `Deferred_Would_Block` receives one
blocked-attempt wait token. Writable epochs detect progress between the failed
write and registration so that race returns immediate readiness instead of
losing the wake. Otherwise the producer may register one caller-owned one-shot
writable waiter for that request generation. Fasyn retains no more than one
such waiter pointer per deferred request and allocates no waiter object. Waiters
are linked by connection and woken only by state changes that can release output
pressure or retire the request; registration therefore requires no producer
polling and no full deferred-table scan. One executor notification may dispatch
at most 64 writable waiters. A callback is only a retry opportunity, not a byte
reservation, so a producer that still observes backpressure may register again.

## Multiplexing Fairness

One request shall not permanently monopolize connection output or executor
capacity merely because it can continuously produce data.

The scheduler may use a simple policy initially, but the policy shall preserve
resource bounds and prevent a single request from bypassing per-request and
connection-wide limits.

Connection I/O fairness is bounded by both syscall counts and bytes. One owner
callback may process at most 64 KiB of ordinary buffered/socket input and may
send at most 64 KiB of connection output, regardless of larger configured read
or write chunk capacities. Partial FastCGI records and partial writes remain
valid progress and resume on a later owner dispatch. The paused ABORT probe has
a smaller protocol-derived bound.

Worker-completion handoff to the connection owner shall likewise be
byte-bounded.
An ordinary completed Work_Item may transfer at most 128 KiB of encoded output
per notification callback, and slices shall end only on complete FastCGI record
boundaries. A partially delivered Work_Item remains executor-owned and counts as
non-idle until its final slice is accepted by the completion handler.

A deferred STDOUT/STDERR command is subject to the same 128 KiB encoded owner
delivery budget. Non-final deferred slices shall end on the fixed deferred chunk
boundary, and the not-yet-delivered encoded bytes shall remain charged to both
the request and connection staged-output budgets until accepted or cancelled.
Cancellation while a command is retained shall release the remaining charge
without exposing a later payload slice.

## Runtime Stream-Limit Semantics

`Fasyn.Request.Connection.Stream_Limits` bounds total request input for
`FCGI_PARAMS`, `FCGI_STDIN`, and Filter `FCGI_DATA`. The default policy is
1 MiB of PARAMS and 1 GiB each of STDIN and DATA. Embeddings may select smaller
nonnegative limits per connection. A zero limit permits the stream's empty
terminator but rejects every non-empty content byte.

The connection accounts each record from its validated header before delivering
content to application execution. A record that would cross a configured total
limit is discarded without allocating from its declared length, the request is
cancelled with `Resource_Limit`, and a resource diagnostic is emitted when a
reporter is configured. Fasyn finishes that request only after consuming the
rejected record boundary, so connection framing remains trustworthy and
unrelated multiplexed requests remain isolatable.

The request-lifetime timer remains armed while a rejected record is being
discarded and while completed output is waiting to drain. A peer therefore
cannot hold a connection forever by withholding an over-limit record body or by
refusing to read completion output.

The connection runtime also bounds zero-request descriptor retention. An
initialized connection with no active application request owns a one-shot idle
connection deadline; the default is 60 seconds and callers may select another
positive duration. Arbitrary transport bytes and management records do not
refresh this deadline, so a peer cannot keep an admission slot forever by
trickling a partial header or other non-request traffic. Accepting the first
`FCGI_BEGIN_REQUEST` removes the idle deadline and the request lifetime becomes
authoritative. When the last KEEP_CONN request retires, the idle deadline starts
again.

Shared admission remains the aggregate connection bound. Production embeddings
call `Request.Connection.initialize` with a shared `Fasyn.Admission.Context`.
`OK + Capacity_Refused` is normal connection-capacity refusal and does not
activate the Connection. `Cleanup_Pending` retains one connection-admission
slot until successful finalization consumes the pending Event Loop cleanup, so
failure retention cannot escape the aggregate transport bound. Admission
connection/request quotas are nonnegative: a zero connection quota refuses every
connection acquisition, while a zero request quota permits admitted connections
and management traffic but rejects every application request as overloaded.

## Allocation Safety

Validate peer-provided lengths and accumulated totals before allocation.

Integer arithmetic used for lengths, accumulation, record assembly, queue
accounting, and deadlines shall be checked for overflow before resource
commitment.

Connection request-slot payload storage shall be allocated lazily to the actual
concurrent-request high-water mark and reused after request retirement. Merely
configuring a large per-connection request limit shall not allocate every slot's
full request-output and PARAMS decoder storage on an idle connection. If a new
high-water slot cannot be allocated, the allocation failure is a runtime
resource failure and shall not be misclassified as a peer protocol error.
Request-slot pointer/index storage shall follow the same principle: an idle
connection shall allocate none of that variable-size table, and the table may
grow geometrically only as concurrent-request high-water increases, bounded by
`max_requests_per_connection`. Growth reallocates only lightweight pointer/index
storage; existing request payload objects remain independently owned and
reusable.

Connection buffers whose size follows runtime configuration belong in explicit
heap-owned connection storage rather than callback task stacks. Socket reads may
fill connection-owned input storage directly, and output serialization may use
a connection-owned send scratch buffer. Output progress shall be committed as
each native send succeeds instead of retaining a request-count-sized temporary
consumption table until the callback returns.

Completed FastCGI name-value pairs shall be delivered to application callbacks
from the decoder's already-bounded resident storage rather than by constructing
name/value arrays sized from peer-declared lengths on the task stack. Such views
are synchronous and callback-scoped; applications must not retain their storage
after the callback returns.

Callback-scoped `Fasyn.Request.Context` construction shall not allocate or
initialize an OS-backed synchronization resource per application dispatch. Its
cancellation state remains concurrently observable by executor cancellation and
worker callbacks, so the synchronization itself shall be compiler-enforced
lock-free atomic state rather than an unsynchronized field. A future change that
cannot preserve the lock-free protected operation shall fail at build time
rather than silently turn callback count into native-lock resource growth.

Configured resident name/value bounds are nonnegative. A zero name or value
bound is a deliberate policy that permits an empty field while rejecting the
first peer-declared non-empty field before payload storage or callback delivery.
A peer-declared PARAMS field above either resident bound is a request resource
failure while FastCGI record framing remains trustworthy: consume the current
record boundary, cancel only that request generation, and preserve unrelated
multiplexed requests. Null-range decoder/connection storage is therefore valid
and shall not be reinterpreted as an initialization error.

## Configuration Consistency

Advertised `FCGI_MAX_CONNS`, `FCGI_MAX_REQS`, and `FCGI_MPXS_CONNS` values shall
be consistent with effective runtime policy.

The implementation shall not advertise capacity that configuration or executor
limits make impossible to provide. Connection initialization shall reject a
configuration whose maximum parameter pair, streamed callback chunk, or request
output cannot be represented by the selected executor. It shall also reject a
per-request output bound too small to encode Fasyn's required terminal FastCGI
records. A trusted configuration mismatch is a caller error, not a peer protocol
error discovered later while processing valid input.
