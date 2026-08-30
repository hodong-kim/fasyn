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
that point.

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

## Output Backpressure

Each connection has one serialized output path.

When an output budget is exhausted, application production shall stop, suspend,
fail according to documented policy, or otherwise propagate backpressure. The
runtime shall not continue appending to an unbounded queue.

A slow peer shall not be able to consume unlimited memory by preventing output
drain.

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
output remains generation-safe.

Deferred producers never perform connection transport I/O. The connection
event loop remains the only owner of socket serialization.

## Multiplexing Fairness

One request shall not permanently monopolize connection output or executor
capacity merely because it can continuously produce data.

The scheduler may use a simple policy initially, but the policy shall preserve
resource bounds and prevent a single request from bypassing per-request and
connection-wide limits.

## Runtime Stream-Limit Semantics

`Fasyn.Request.Connection.Stream_Limits` bounds total request input for
`FCGI_PARAMS`, `FCGI_STDIN`, and Filter `FCGI_DATA`. The default policy is
1 MiB of PARAMS and 1 GiB each of STDIN and DATA. Embeddings may select smaller
positive limits per connection.

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

An independent idle-transport timeout is not imposed by the connection runtime.
Idle connections remain bounded by shared connection admission; embeddings that
require an idle-transport lifetime may apply a stricter lifecycle policy outside
the FastCGI request lifetime.

## Allocation Safety

Validate peer-provided lengths and accumulated totals before allocation.

Integer arithmetic used for lengths, accumulation, record assembly, queue
accounting, and deadlines shall be checked for overflow before resource
commitment.

## Configuration Consistency

Advertised `FCGI_MAX_CONNS`, `FCGI_MAX_REQS`, and `FCGI_MPXS_CONNS` values shall
be consistent with effective runtime policy.

The implementation shall not advertise capacity that configuration or executor
limits make impossible to provide.
