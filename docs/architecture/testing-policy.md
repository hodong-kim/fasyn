# Testing Policy

FastCGI conformance, boundedness, and state isolation are production contracts,
not optional integration-test concerns.

## Test Levels

Tests shall cover at least:

- pure record codec behavior;
- incremental name-value codec behavior;
- request and role state machines;
- management record behavior;
- resource accounting and admission;
- multiplexing;
- request-ID reuse and stale-work rejection;
- cancellation;
- partial nonblocking I/O;
- connection close and `FCGI_KEEP_CONN`;
- executor saturation;
- timeout and shutdown;
- classic inherited-listener startup where supported;
- end-to-end interoperability with at least one independent FastCGI peer.

## Fragmentation

Every streaming parser shall be tested with fragmentation at every meaningful
boundary, including:

- every byte of the eight-byte record header;
- content/padding boundaries;
- one-byte and four-byte name/value length fields;
- inside a four-byte length field;
- inside a name;
- inside a value;
- between successive FastCGI records.

Tests shall not assume one socket read equals one record.

## Multiplexing

Use deterministic tests that interleave records for multiple request IDs.

Cover:

- simultaneous active requests;
- interleaved STDIN and output;
- request completion in a different order than begin order;
- request-ID reuse;
- late output from an old generation;
- one request cancellation while siblings continue;
- connection-fatal failure terminating all siblings.

## Resource Exhaustion

Every configurable bound shall have a boundary test for:

- below the limit;
- exactly at the limit;
- immediately above the limit;
- arithmetic overflow or impossible peer-declared length where applicable.

Tests shall verify both returned/protocol results and resource cleanup.

## Negative Protocol Tests

Malformed or invalid peer input shall cover:

- unsupported version;
- invalid management/application request-ID domain;
- malformed discrete record body;
- invalid role;
- invalid stream sequencing;
- malformed name-value length encoding;
- records targeting inactive request IDs;
- truncated connection input.

The test shall assert the documented failure scope: request, connection, or
runtime.

## Property and Fuzz Testing

Record and name-value decoders are fuzz targets.

Useful properties include:

- encode/decode round trips for valid values;
- arbitrary fragmentation does not change decoded stream value;
- invalid input never causes out-of-bounds access or unbounded allocation;
- one request cannot alter another request's state without a connection-fatal
  transition.

A fuzz failure shall become a deterministic regression test before closure.

## Conformance Evidence

Fasyn may claim FastCGI 1.0 completion only when every applicable section of
`protocol-conformance.md` has linked automated evidence.

A test that only exercises NGINX's common Responder path is insufficient for a
complete conformance claim.
