# Testing

Repository-wide test requirements are defined in
`../architecture/testing-policy.md`.

The FastCGI completion checklist is defined in
`../architecture/protocol-conformance.md`.

## Canonical Command

Build and run the current native test suite with:

    rake test

The command prepares the selected Clair test runtime, builds
`fasyn_tests.gpr`, and runs:

    build/tests/bin/fasyn_unit_tests

The test executable uses `Clair.Test`.

Runtime tests that observe worker-produced output must wait until the connection
event-loop has published that completion; an application callback-local flag is
not a synchronization point for connection-owned output state. Failed test runs
exit with failure after printing the summary so an assertion that interrupts a
scenario before cleanup cannot leave worker tasks holding the process open.
Successful runs still return normally and retain Ada finalization as a leak check.

## NGINX Interoperability

Run the independent HTTP-to-FastCGI acceptance path with:

    rake interop:nginx

The task first runs the canonical native suite, then creates an isolated Unix
listener and temporary NGINX prefix. The Fasyn fixture receives that listener as
classic FastCGI file descriptor 0. NGINX receives a real HTTP POST, forwards the
method, query string, and body as FastCGI PARAMS/STDIN, and returns Fasyn
STDOUT/END_REQUEST as HTTP. The acceptance response is HTTP 200 with
`fasyn-nginx-ok`.

The workflow requires NGINX and curl but does not modify the system NGINX
configuration or service state. Override the executable paths with `FASYN_NGINX`
and `FASYN_CURL` when required.

## Suite Coverage

The native suite covers the protocol, role, management, multiplexing,
cancellation, resource, timeout, shutdown, and classic-listener requirements
listed in `../architecture/protocol-conformance.md`. That document owns the
detailed mapping from conformance requirements to test suites.

Runtime tests use small native fixtures only to arrange operating-system
conditions such as socket pairs, listener sockets, and stalled peers. Production
transport and event-loop operations remain behind Clair.

A test-only child package may inspect private runtime state when an invariant
cannot be established through the application API alone. Such helpers remain
under `tests/` and are not production API.

## Clair Dependency

Tests use the same Clair checkout as normal builds: the sibling `../clair`
checkout by default, or the checkout selected with `FASYN_CLAIR_ROOT`.

Tests shall not silently switch to another Clair revision or installed copy when
the development workflow expects the local checkout.

The Fasyn test project uses Clair's test runtime and compiles Fasyn runtime
sources in the test project. This avoids linking both Clair's production and test
aggregate libraries into one executable while exercising the same Fasyn runtime
source.

## Conformance Discipline

Implementation changes require a reproducible failure at the FastCGI/Fasyn
boundary rather than an application-specific workaround. Do not document a test
command before the corresponding executable workflow exists.

FastCGI 1.0 completion criteria and automated evidence are owned by
`../architecture/protocol-conformance.md`.
