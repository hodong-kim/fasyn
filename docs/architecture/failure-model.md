# Failure Model

Fasyn distinguishes caller errors, FastCGI peer/protocol errors, external system
failures, application-handler failures, internal contract or invariant
violations, and unexpected implementation failures.

These classes shall not be collapsed merely because one public API exposes a
single error channel.

## Failure Classes

### Caller Errors

A public Fasyn operation may define malformed configuration, an invalid object,
or use in an invalid lifecycle state as a reportable caller error.

Caller errors are part of the API contract. They shall not be converted into
successful no-ops unless that behavior is explicitly documented.

### FastCGI Peer and Protocol Errors

Input from a FastCGI peer is untrusted.

This class includes malformed record framing, an unsupported protocol version,
invalid use of the null request ID, malformed record content, invalid role
stream sequencing, malformed name-value encoding, and other violations of the
FastCGI 1.0 wire contract.

A protocol-defined negative result is not by itself an implementation failure.
Examples include:

- `FCGI_CANT_MPX_CONN`;
- `FCGI_OVERLOADED`;
- `FCGI_UNKNOWN_ROLE`;
- `FCGI_UNKNOWN_TYPE`.

Use the protocol-defined result when the specification defines one. Otherwise
apply the failure scope rules below.

### External System Failures

External failures originate outside Fasyn's trusted protocol and runtime state.

Examples include:

- file descriptor or socket exhaustion;
- allocation failure;
- nonblocking I/O readiness races;
- interrupted or failed system calls;
- event-loop or timer backend failure;
- signal integration failure;
- platform API failure;
- failure reported by Clair.

Expected external failures shall remain distinguishable from protocol errors and
internal invariant violations.

### Application-Handler Failures

An application callback may fail while Fasyn itself remains healthy.

The direct `Fasyn.Request.Exchange` path does not catch application callback
exceptions. The exception propagates to the caller, which shall abandon the
current `Exchange` and its `Writer`. Direct callback failure is not translated
into a cancellation cause.

The asynchronous runtime isolates the exception at the worker boundary and
reports `CALLBACK_FAILED` to the connection runtime. Output staged by the
failing callback is not committed. If the bounded terminal output can be
encoded, Fasyn closes the request streams and emits `FCGI_END_REQUEST` with
`appStatus = 1` and protocol status `FCGI_REQUEST_COMPLETE`. The nonzero
application status distinguishes this result from successful application
completion. Fasyn does not synthesize diagnostic text into `FCGI_STDERR`, and
handler failure does not create a `Cancellation_Cause`.

Application-handler failure is request-fatal while connection framing remains
trustworthy. Unrelated request generations on the same connection shall remain
isolated from that failure. If the terminal failure output itself cannot be
encoded within the configured bounds, the connection can no longer complete
the request normally and follows the connection-failure path.

### Internal Contract and Invariant Violations

An impossible state, broken ownership rule, invalid internal transition, stale
request generation, cross-request output mix-up, unexpected null object, or
other violation of a trusted internal precondition is an invariant failure.

Internal invariant failures shall not be silently converted into ordinary EOF,
peer error, overload, cancellation, or success.

Assertions may expose these failures during development. Assertions shall not
replace normal error handling for expected caller, peer, handler, or external
failures.

### Unexpected Implementation Failures

An unexpected Ada exception or an error not attributable to documented caller
input, the FastCGI peer, application code, or an external system condition is an
implementation failure.

Preserve enough diagnostic context to identify the affected connection,
request generation, operation, and state when doing so is safe.

## Failure Scope

Failure classification and failure scope are separate questions.

### Request-Fatal

A failure is request-fatal when Fasyn can still trust connection framing and can
isolate the affected request.

Examples may include:

- a request exceeding a configured PARAMS, STDIN, or DATA policy limit;
- request timeout;
- request cancellation;
- application-handler failure;
- a role-specific sequence violation that is safely attributable to one active
  request and does not destroy connection framing.

Request-fatal handling should preserve unrelated multiplexed requests whenever
the protocol state remains trustworthy.

### Connection-Fatal

A failure is connection-fatal when Fasyn can no longer trust or safely continue
the transport-level protocol state.

Examples include:

- unsupported FastCGI version when continuation cannot be made trustworthy;
- broken record framing;
- unrecoverable parser state;
- socket failure;
- corruption of the connection writer state.

A connection-fatal failure terminates every active request on that connection.

### Runtime-Fatal

A runtime-fatal failure means the server context cannot safely continue serving
connections.

This scope is reserved for failures that invalidate shared runtime state, not
for ordinary connection or request errors.

## Cancellation and Late Work

`FCGI_ABORT_REQUEST` requests cancellation; it does not make already-running
application work magically disappear.

Cancellation shall mark the request generation, signal application work, reject
late output from that generation after finalization, and complete the FastCGI
request according to the documented cancellation contract.

Late output from an old request generation shall never be delivered to a newer
request that reuses the same request ID.

## State and Resource Rules

A failed operation shall leave each affected object in a documented state. The
implementation shall either:

- preserve the previous valid state;
- transition to a documented recoverable or terminal state; or
- invalidate the object explicitly when its state can no longer be trusted.

Cleanup after failure shall not erase the failure that caused cleanup to run.

## Multiple Failures

When several failures occur:

1. preserve the first causally relevant failure as the primary failure;
2. retain cleanup failures as secondary diagnostics when possible;
3. make a cleanup failure primary if the operation otherwise succeeded;
4. allow a later invariant or implementation failure to replace the primary
   failure only when it proves that earlier state or results cannot be trusted;
5. never turn multiple failures into success.

Protocol status, application status, diagnostics, and public API errors are
different channels and shall not be conflated.
