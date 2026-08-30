# Engineering Principles

Correctness, performance, safety, reliability, maintainability, and bounded
resource behavior under large-scale and hostile input are the primary criteria
for evaluating Fasyn designs and implementations.

## Minimum Sufficient Design

A minimum sufficient design is the smallest design that fully satisfies the
defined goal and the engineering properties required to make that goal sound.
It is not the design with the fewest components, checks, states, or lines of
code.

For Fasyn, the defined goal is a complete FastCGI 1.0 application-side
implementation with bounded asynchronous execution.

Therefore the following are required structure rather than speculative
generality:

- all FastCGI 1.0 record types applicable to the application side;
- Responder, Authorizer, and Filter roles;
- management records;
- connection persistence;
- multiplexing;
- request-ID reuse;
- incremental stream processing;
- cancellation and shutdown;
- partial nonblocking I/O;
- backpressure;
- resource admission and limits;
- classic inherited-listener process-state compatibility required by the
  specification.

Do not add unrelated application facilities merely because a server might use
them. HTTP interpretation, MCP, JSON, routing, templates, databases, and process
management remain outside Fasyn.

## Protocol and Runtime Separation

Protocol semantics shall not depend on a particular worker-pool implementation,
event backend, web server, or application framework.

The protocol layer owns FastCGI representation and state rules. The runtime
owns connection and request lifetime, scheduling, backpressure, cancellation,
and resource policy. The I/O layer owns transport progress. The execution layer
runs application work through a bounded interface.

Changing an executor or I/O backend shall not require rewriting FastCGI record
or role semantics.

## Incremental Processing

A FastCGI record boundary is not an application stream boundary.

Parsers and encoders shall operate incrementally. They shall tolerate arbitrary
valid fragmentation across socket reads and FastCGI records. A name-value length
field, name, value, request body, filter data stream, or output stream may cross
internal buffer boundaries.

Large accepted streams shall not imply large resident buffers.

## Explicit State and Ownership

Reliability shall come from explicit state machines, ownership rules, and valid
transitions rather than from permissive cleanup or hidden shared state.

Connections own connection-local protocol state and request tables. Requests
own request-local role state, stream state, cancellation state, and resource
accounting. Executors own work queues. The component that owns a socket owns
socket I/O.

Request IDs are protocol names with reusable lifetime, not permanent object
identities.

## Boundedness

All peer-amplifiable state shall be limited. Limits shall be checked before an
allocation, queue insertion, job dispatch, or other irreversible resource
commitment whenever practical.

Reaching a configured capacity is an expected runtime condition. Where
FastCGI defines a protocol result such as `FCGI_OVERLOADED` or
`FCGI_CANT_MPX_CONN`, use that result according to the specification.

## Backpressure

Output congestion shall not cause unlimited per-request or per-connection
buffer growth. Input admission shall not outpace the memory or execution
capacity reserved for accepted requests.

Backpressure may suspend reading, suspend application production, reject new
work, or apply another documented bounded mechanism. It shall not silently
discard valid protocol data.

## Platform Boundaries

Use Clair for generic platform facilities when Clair provides the required
contract. Keep FastCGI semantics independent of operating-system constants and
backend object layouts.

The classic FastCGI inherited-listener process model is a protocol compatibility
boundary, not permission to make Fasyn a process manager.

## Application Isolation

One request shall not be able to corrupt the state or output of another request
on the same multiplexed connection.

A request-scoped failure should remain request-scoped when framing and
connection state remain trustworthy. A connection-fatal error may terminate all
requests on that connection because their transport has become unusable.

## No Framework Creep

Do not interpret FastCGI parameter names beyond what the FastCGI specification
requires for role semantics and classic process-state compatibility.

For example, Fasyn may transport `REQUEST_METHOD`, `CONTENT_TYPE`, and other
CGI-style parameters without owning their HTTP meaning.
