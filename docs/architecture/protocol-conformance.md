# FastCGI 1.0 Protocol Conformance

## Authority

Fasyn targets complete conformance with:

FastCGI Specification, Document Version 1.0, 29 April 1996.

Reference:

    https://github.com/fast-cgi/spec/blob/master/spec.md

This document is a conformance checklist and implementation contract. It does
not replace the specification.

## Scope

Fasyn implements the FastCGI interface from the application perspective.

The conformance target includes the wire protocol and the portions of the
classic FastCGI process state that require application behavior. Web-server
application management remains outside Fasyn.

A modern explicit TCP or Unix-domain listener API may coexist with classic
FastCGI startup compatibility, but it does not replace that compatibility.

## Initial Process State

The implementation shall support the classic FastCGI inherited-listener model:

- `FCGI_LISTENSOCK_FILENO` is file descriptor 0;
- the inherited descriptor is an already-created listening socket;
- the transport may be a Unix stream socket or TCP/IP socket;
- `FCGI_WEB_SERVER_ADDRS`, when present, is enforced as specified;
- a rejected peer is closed before FastCGI request processing.

Process argument construction, user/group selection, root directory, working
directory, and other web-server launch policy are not Fasyn process-management
features.

The runtime shall permit integration with the specification's termination
behavior, including `SIGTERM`, without requiring Fasyn to own process-wide
policy.

## Record Framing

Support FastCGI version 1 and the eight-byte record header.

The decoder shall correctly process:

- `version`;
- `type`;
- 16-bit `requestId`;
- 16-bit `contentLength`;
- `paddingLength`;
- the reserved byte;
- zero to 65535 content bytes;
- zero to 255 padding bytes.

Padding bytes are ignored semantically but consumed exactly.

Management records use request ID 0. Application records use nonzero request
IDs.

Socket reads and writes may split at any byte. Record parsing and serialization
shall therefore support partial I/O.

## Record Types

The implementation shall support every FastCGI 1.0 record type:

- `FCGI_BEGIN_REQUEST`;
- `FCGI_ABORT_REQUEST`;
- `FCGI_END_REQUEST`;
- `FCGI_PARAMS`;
- `FCGI_STDIN`;
- `FCGI_STDOUT`;
- `FCGI_STDERR`;
- `FCGI_DATA`;
- `FCGI_GET_VALUES`;
- `FCGI_GET_VALUES_RESULT`;
- `FCGI_UNKNOWN_TYPE`.

Direction, request-ID domain, content structure, and stream/discrete semantics
shall follow the specification.

## Name-Value Encoding

Implement the FastCGI name-value encoding exactly:

- lengths from 0 through 127 use the one-byte form;
- longer lengths use the four-byte form with the high bit marking that form;
- the four-byte representation carries a 31-bit length;
- a name-value pair may be fragmented across FastCGI records and socket reads.

`FCGI_PARAMS`, `FCGI_GET_VALUES`, and `FCGI_GET_VALUES_RESULT` use this
encoding where defined by the specification.

The decoder shall validate policy limits before allocating or buffering based on
a peer-provided length.

## Management Records

Fasyn handles management records internally.

For `FCGI_GET_VALUES`, support the standard variable names:

- `FCGI_MAX_CONNS`;
- `FCGI_MAX_REQS`;
- `FCGI_MPXS_CONNS`.

Reported values shall describe actual configured/runtime capabilities, not
unreachable theoretical maxima.

Unknown management record types shall produce `FCGI_UNKNOWN_TYPE` as specified.

Application code shall not need to handle management records.

## Request Lifecycle

A nonzero request ID becomes active when a valid `FCGI_BEGIN_REQUEST` for that
ID is accepted. It becomes inactive when Fasyn sends `FCGI_END_REQUEST`.

Inactive request IDs may be reused by the peer.

Records for an inactive request ID are ignored as specified, except for the
record that begins a new request.

Implementation identity shall distinguish successive generations of a reused
request ID so stale asynchronous work cannot target a later request.

## Begin Request

Implement the `FCGI_BEGIN_REQUEST` body, including:

- role;
- flags;
- `FCGI_KEEP_CONN`.

Support all FastCGI 1.0 roles:

- `FCGI_RESPONDER`;
- `FCGI_AUTHORIZER`;
- `FCGI_FILTER`.

An unknown role completes with `FCGI_UNKNOWN_ROLE` according to the
specification.

## Connection Persistence

Honor `FCGI_KEEP_CONN`.

When the peer delegates connection close after request completion, closure shall
be coordinated with other active multiplexed requests and pending output so no
valid sibling request is truncated.

Connection lifetime shall remain explicit and testable.

## Multiplexing

Support multiple active request IDs on one transport connection.

Advertise multiplexing through `FCGI_MPXS_CONNS` only when enabled by runtime
configuration and actually available.

If a runtime configuration does not permit another multiplexed request on a
connection, use `FCGI_CANT_MPX_CONN` where required by the specification.

Multiplexed records from different requests may be interleaved. Record bytes
themselves shall remain serialized correctly.

## Responder Role

Implement the Responder role stream protocol.

Fasyn receives:

- `FCGI_PARAMS`;
- `FCGI_STDIN`.

Fasyn sends:

- `FCGI_STDOUT`;
- optional `FCGI_STDERR`;
- `FCGI_END_REQUEST`.

A zero-length stream record terminates the corresponding stream.

The application may begin producing output after the parameter stream is
complete without requiring the complete STDIN stream to be resident in memory.

## Authorizer Role

Implement the Authorizer role protocol completely, including its parameter
input and required output semantics.

Fasyn shall preserve the distinction between FastCGI protocol status and the
authorization response produced by application code.

## Filter Role

Implement the Filter role stream protocol completely.

Fasyn receives:

- `FCGI_PARAMS`;
- `FCGI_STDIN`;
- `FCGI_DATA`.

Role sequencing shall follow the specification. In particular, Filter output is
not treated as an unrestricted Responder stream sequence.

Support the Filter parameters defined by FastCGI 1.0, including
`FCGI_DATA_LAST_MOD` and `FCGI_DATA_LENGTH`, and enforce the stream-length
consistency rules required by the specification.

## Stream Termination

FastCGI stream EOF is represented by a zero-length record of that stream type.

The application API shall not require application code to construct FastCGI
EOF records manually. Fasyn owns record framing and finalization.

`FCGI_END_REQUEST` is emitted only after Fasyn has completed the required
protocol-side stream finalization for the request.

## Abort and Cancellation

Implement `FCGI_ABORT_REQUEST`.

Cancellation shall be cooperative at the application-execution boundary and
authoritative at the Fasyn request-generation boundary.

Fasyn shall prevent output from a cancelled or finalized generation from
escaping later as output for a reused request ID.

The implementation shall complete an aborted request as promptly as the
documented cancellation contract allows.

## End Request and Protocol Status

Implement the `FCGI_END_REQUEST` body, including:

- 32-bit application status;
- protocol status.

Support every FastCGI 1.0 protocol status:

- `FCGI_REQUEST_COMPLETE`;
- `FCGI_CANT_MPX_CONN`;
- `FCGI_OVERLOADED`;
- `FCGI_UNKNOWN_ROLE`.

Do not misuse `FCGI_OVERLOADED` as a generic replacement for every policy or
application error.

## Errors and Process Lifecycle

Preserve the distinction between:

- application-level errors carried by application output/status;
- FastCGI protocol errors;
- lower-level runtime/system errors.

The Unix compatibility path shall provide a way to report lower-level protocol
and environment errors in accordance with the specification's syslog
expectation without forcing one logging policy on every embedding application.

The library shall permit callers to map intentional process termination and
abnormal termination to the FastCGI process semantics documented by the
specification.

## Automated Evidence

The automated suite links the conformance areas above to these scenarios:

- initial process state: `Tests.Classic` covers inherited Unix and TCP
  listeners, allowed/rejected `FCGI_WEB_SERVER_ADDRS` peers, malformed
  environment input, diagnostics, and real SIGTERM delivery;
- record framing and request-ID domains: `Tests.Protocol` covers round trips,
  every header byte boundary, maximum wire fields, version rejection, and
  application/management request-ID domains; `Tests.Records` covers exact
  content/padding consumption, maximum record boundaries, and deterministic
  arbitrary-byte decoder fuzz;
- name-value encoding: `Tests.Name_Values` covers one-byte/four-byte boundaries,
  policy limits, deterministic round-trip properties, and arbitrary-byte fuzz;
  `Tests.Responder` sweeps every FastCGI-record split of a pair using four-byte
  name and value lengths;
- management records and protocol statuses: `Tests.Management` covers
  `FCGI_GET_VALUES`, effective capacity advertisement, `FCGI_UNKNOWN_TYPE`, and
  `FCGI_OVERLOADED`; `Tests.Multiplexing` covers `FCGI_CANT_MPX_CONN`;
  `Tests.Responder` covers `FCGI_UNKNOWN_ROLE`;
- request lifecycle and generation isolation: `Tests.Responder` covers ignored
  inactive records; `Tests.Multiplexing` covers interleaving, out-of-order
  completion, request-ID reuse, stale-generation rejection, and connection-fatal
  sibling cleanup;
- connection persistence: `Tests.Multiplexing` verifies that a non-KEEP request
  does not truncate an active sibling and that transport close waits for all
  required output to drain;
- role semantics: `Tests.Responder`, `Tests.Authorizer`, and `Tests.Filter`
  cover all three FastCGI roles, stream sequencing, application/protocol
  status
  separation, Filter metadata validation, short/overlong DATA, and cache
  shortcut completion;
- stream termination and cancellation: Responder/Authorizer/Filter scenarios
  cover FastCGI EOF and `FCGI_END_REQUEST`; `Tests.Multiplexing` verifies that
  aborting one request preserves its sibling; `Tests.Runtime` covers abort while
  work is pending, request timeout, shutdown cancellation, and late-output
  rejection;
- configured resource exhaustion: `Tests.Execution` covers worker/pending-job
  saturation; `Tests.Management` covers global request admission;
  `Tests.Multiplexing` covers per-connection request capacity and verifies that
  a resource-limited request preserves its sibling; `Tests.Runtime` covers
  PARAMS, STDIN, and DATA below/exact/above total limits, bounded
  backpressure, rejected-record discard timeout, and completed-output stall
  timeout;
- malformed input and error scope: `Tests.Responder` covers malformed discrete
  bodies, invalid sequencing, truncated name-value lengths, and invalid record
  types; `Tests.Runtime` covers truncated transport input and protocol
  diagnostics; `Tests.Multiplexing` verifies connection-fatal failure retires
  all siblings.

Independent-peer interoperability remains external acceptance evidence rather
than an in-process conformance test. `rake interop:nginx` exercises the selected
NGINX executable as that independent peer: an HTTP POST crosses NGINX's FastCGI
client, enters Fasyn through the classic inherited Unix listener, and returns
Fasyn STDOUT/END_REQUEST as an HTTP 200 response. The fixture additionally
verifies the forwarded request method, query string, and request body before
returning success, and the task reports the NGINX version used for the run.

## Conformance Completion Criteria

FastCGI 1.0 may be described as complete only when:

1. every item in this document has an implementation;
2. every applicable item has direct automated coverage;
3. fragmented input and partial output are tested;
4. all three roles are tested;
5. management records are tested;
6. multiplexing and request-ID reuse are tested;
7. classic inherited-listener startup is tested on applicable POSIX targets;
8. configured resource exhaustion follows documented bounded behavior;
9. malformed peer input cannot cause unbounded allocation or cross-request
   corruption.
