# Testing

Repository-wide test requirements are defined in
`../architecture/testing-policy.md`.

The FastCGI completion checklist is defined in
`../architecture/protocol-conformance.md`.

## Canonical Command

Build and run the current native test suite with:

    rake test

The command prepares the selected Clair production artifact plus the host-side
test-registry generator, builds `fasyn_tests.gpr`, runs the native suite once,
runs the default 25-iteration same-process soak with RSS/FD bounds, then runs
the focused executor-lifecycle memory regression. On Linux and FreeBSD, the
direct-Exchange callback-memory regression also runs; macOS skips only that gate.
The single-pass and soak phases execute:

    build/bin/<target>/<artifact-profile>/tests/fasyn_unit_tests

The executor regression runs `fasyn_execution_lifecycle_tests` through
`Clair.Test`. The callback regression drives the separately built
`fasyn_exchange_callback_churn_fixture` through its Ruby resource sampler.

The test executable uses `Clair.Test`. Test objects, generated registry source,
and executables are isolated by the selected target and the Clair-derived
artifact profile, including dependency library kind, just like production
artifacts.

On macOS, the direct-Exchange callback resource sampler reports `SKIP (darwin)`
because it currently implements Linux and FreeBSD process accounting only. The
remaining canonical gates run normally. See `building.md` for macOS toolchain
and dependency selection.

For the ordinary fast development loop, run only the single-pass suite with:

    rake test-fast

Build the complete test executable set without running target programs with:

    rake test-build

This is the canonical cross-build entry point. `rake test`, `rake test-fast`,
`rake test-soak`, `rake test-valgrind`, and interoperability execution are
native-only gates.

Runtime tests that observe worker-produced output must wait until the connection
event-loop has published that completion; an application callback-local flag is
not a synchronization point for connection-owned output state. Failed test runs
exit with failure after printing the summary so an assertion that interrupts a
scenario before cleanup cannot leave worker tasks holding the process open.
Successful runs still return normally and retain Ada finalization as a leak check.

## Supported-Platform Acceptance

The asynchronous runtime is supported on Linux, FreeBSD, and macOS. Before
closing a release-candidate validation that changes the public runtime surface,
lifecycle contracts, platform boundary, or Clair integration, run both commands
on each supported runtime operating system with the intended compatible Clair
checkout:

    rake build
    rake test

Both commands shall pass without a Fasyn platform-specific workaround. Record
the target OS/version and the suite, case, and assertion summary in the
validation work or release record so cross-platform acceptance remains
auditable without turning this procedure into a candidate-specific status log.

## Valgrind Memory-Safety Gate

On Linux, run the complete native suite under Valgrind Memcheck with:

    rake test-valgrind

The task rebuilds the native test executable and fails on invalid memory access
or definite/indirect leaks. No leak suppressions are checked in: toolchain or
runtime leaks remain visible instead of being hidden from the memory-safety
gate. On FreeBSD 15.1 with GNAT 16, `Fasyn.Environment_Variables.Set` bypasses
the leaking `Ada.Environment_Variables.Set` / `__gnat_setenv` putenv fallback by
calling the POSIX `setenv` interface directly. The Classic environment test uses
that wrapper, and the unsuppressed Valgrind gate must remain leak-free. This gate
is required after changes to worker completion, notification, deferred output,
shutdown, or asynchronous lifetime ownership.

## Long-Run Attack-Shaped Soak

The canonical `rake test` command includes the long-run gate after the
single-pass suite. To run only the long-run phase, use:

    rake test-soak

The default soak executes 25 full suite iterations after one test build. Reusing
one process is intentional: request/connection churn, malformed/fuzz input,
listener storms, saturation/recovery, cancellation races, and request-ID reuse
are repeated without process restart hiding retained heap or descriptor state.
After every iteration the test process reports resident memory and open-descriptor
counts. The Rake driver requires forward progress, uses iteration 2 as the default
warmup baseline, and fails if later steady-state RSS grows by more than 4096 KiB
or the FD count grows at all. Interrupting the Rake soak runner terminates
the child process and joins the output-reader thread before propagating the
interrupt, so a manual abort does not leave an orphan soak process or a
secondary reader-thread exception.

The separate `rake test-soak` target remains available for focused long-run
work, while `rake test-fast` preserves the ordinary fast development loop. The
policy used by both `rake test` and `rake test-soak` can be adjusted for longer
campaigns with:

- `FASYN_SOAK_ITERATIONS` (default 25, minimum 2);
- `FASYN_SOAK_WARMUP` (default 2);
- `FASYN_SOAK_TIMEOUT` for the overall child-process lifetime (default
  `iterations * 10 + 60` seconds);
- `FASYN_SOAK_PROGRESS_TIMEOUT` for the maximum interval without a completed
  iteration (default 30 seconds);
- `FASYN_SOAK_MAX_RSS_GROWTH_KB` (default 4096); and
- `FASYN_SOAK_MAX_FD_GROWTH` (default 0).

The test executable accepts `FASYN_TEST_REPEAT` directly when repeated execution
is useful without the Rake resource-policy checks. Values are limited to
1..10,000. RSS is obtained through `Clair.Process.Memory.query_current_usage`
and normalized from bytes to KiB by the Fasyn test runner. This keeps the soak
metric as current resident memory on the supported Linux, FreeBSD, and macOS
runtimes; Clair owns the platform accounting source, including FreeBSD
`KERN_PROC_PID`/`kinfo_proc.ki_rssize`. FD accounting remains a small
Fasyn test helper over `/proc/self/fd` or `/dev/fd`. A platform that cannot
provide either measurement fails the soak rather than silently claiming
resource stability.

RSS is deliberately a bounded process-residency signal, not a live-allocation
counter. On FreeBSD, libc's jemalloc may keep recently freed dirty or muzzy
pages resident until its decay policy purges or reuses them. A bounded RSS rise
with stable descriptors/threads and leak-free object accounting is therefore
not, by itself, evidence of a Fasyn ownership leak. Investigate such a rise with
unsuppressed Memcheck, ordinary Massif object-heap profiling, and native VM-map
sampling such as `procstat -v`. `Massif --pages-as-heap=yes` replaces ordinary
object-heap accounting with page-level mapping accounting; its `mem_heap_B` may
therefore include mappings such as thread stacks and loader/runtime pages and
must not be read as live `malloc` bytes.

On FreeBSD, `MALLOC_CONF=dirty_decay_ms:0,muzzy_decay_ms:0` may be used as a
focused diagnostic control: if retained RSS disappears while the same workload
and ownership checks pass, allocator dirty/muzzy residency is the discriminator.
The canonical test gate and production runtime shall not force this setting;
immediate purge changes host allocator policy and can hide the process-residency
high-water that the ordinary soak is intended to bound. Any soak failure shall
become a focused deterministic regression before the corresponding security
audit item is closed.

## Executor Lifecycle Memory Regression

Run the executor resource gate independently with:

    rake test-execution-lifecycle-memory

The `Clair.Test` scenario holds one Event Loop and repeatedly initializes,
shuts down, and finalizes one executor with one worker. After 1,000 warmup
cycles it measures 20 batches of 1,000 cycles through
`Clair.Process.Memory.query_current_usage`. Every lifecycle status must succeed,
and peak current RSS may exceed the warmup baseline by at most 512 KiB. The
separate executable gives this small lifecycle a reproducible allocator
baseline without repeating it inside every full-suite soak iteration.

This guards native synchronization resources as well as Ada heap ownership.
A FreeBSD GNAT 16.2.0 build previously omitted native-lock finalization for
constrained protected subtypes. The corrected compiler inspects the base type's
generated lock representation, while Fasyn retains its unconstrained
deferred-state allocation for compatibility with affected compiler builds.
Removing that compatibility form requires supported-platform acceptance rather
than relying on compiler version text alone.

When accepting a compiler-side cleanup fix, rebuild both Fasyn and its
consumer-owned Clair artifacts from fresh output directories. The compiler's
focused protected-cleanup regression must pass with the installed toolchain,
without a frontend override, before that installation is accepted as evidence.
A compiler reporting the same version string may still contain different
runtime or downstream patches.

The protected state must be deallocated when its last target reference is
released; surviving deferred handles still retain it through their existing
ownership contract. FreeBSD libthr allocates mutex storage through a private
allocator, so zero Memcheck lost blocks cannot replace this resource gate.
Short page probes can also miss retained locks while allocations still fit in
existing runtime pages.

## Direct Exchange Callback Memory Regression

The canonical `rake test` command also runs the focused regression for the
historical FreeBSD application-callback memory finding. Run only that gate with:

    rake test-exchange-callback-memory

The regression is owned by Fasyn because it exercises `Fasyn.Request.Exchange`
directly and does not depend on a Sonbal product fixture. It always consumes the
current selected Clair source authority rather than pinning a Clair revision.
The retired Sonbal FastCGI parent soak is historical closure evidence only; the
checked-in Fasyn regression is the durable routine guard for this boundary.

Two workloads preserve the original discriminator:

- `params_finish`: one application callback per request; and
- `params_payload_finish`: seven parameter callbacks plus one parameter-finish
  callback per request.

Each case performs 50 warmup requests before measurement, then defaults to 50
batches of 100 requests (5,000 measured requests). Linux samples RSS, VSZ,
thread count, and descriptor count from `/proc`; FreeBSD samples RSS/VSZ with
`ps` and threads/descriptors with `procstat`. The gate requires exact thread and
descriptor return, rejects a late RSS tail that fails to plateau, and rejects
sustained positive RSS growth. VSZ is retained in the structured diagnostic
output for investigation but is not by itself a failure criterion because
allocator address-space high-water can grow without retained live objects.

Longer or focused runs can adjust:

- `FASYN_EXCHANGE_CALLBACK_BATCHES` (default 50, minimum 8);
- `FASYN_EXCHANGE_CALLBACK_BATCH_SIZE` (default 100);
- `FASYN_EXCHANGE_CALLBACK_ONLY_CASE` (`params_finish` or
  `params_payload_finish`); and
- `FASYN_EXCHANGE_CALLBACK_TRACE=1` to print every resource sample.

The regression runs on Linux and FreeBSD. macOS skips this specific resource
gate rather than claiming equivalent process-accounting semantics.

## Alire Consumer Acceptance

Where Alire is installed, validate the Alire crate boundary with:

    rake test-alire

This is intentionally separate from `rake test` so Alire is never required by
the canonical native workflow. The acceptance task operates on a temporary copy
of Fasyn, resolves the selected local Clair checkout through an Alire path pin
in that copy only, and verifies both the Fasyn root build and a fresh external
runtime consumer.

The external fixture imports `fasyn_runtime.gpr` and uses `Fasyn.Listener` so
the check covers the Clair-backed production boundary rather than only the
protocol core. The fixture executable must link and run successfully.

Each temporary Alire workspace explicitly selects an Alire-detected external
GNAT 16 and an Alire-detected system-package GPRbuild before dependency
resolution. The repository-local `alire/` state is deliberately not copied, so
acceptance does not silently inherit a stale compiler selection. If either
toolchain component is unavailable, the acceptance task fails rather than
falling back to Alire's bundled GNAT.

Alire 1.2.1 reliably exposes dependency prefixes to `alr exec`, so the complete
native suite is invoked inside the Alire environment as:

    alr exec -- rake test

No test action is declared in Fasyn's manifest for this compatibility point.
Catalog-only dependency resolution is a release acceptance step tracked in
`../roadmaps/alire-support.md`.

## NGINX Interoperability

Run the independent HTTP-to-FastCGI acceptance path with:

    rake interop:nginx

The task first runs the single-pass native suite, then creates an isolated Unix
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

Tests use the same Clair source authority and prepared artifact root as normal
builds: the sibling `../clair` checkout by default, or the source selected with
`FASYN_CLAIR_ROOT`. Tests shall not silently switch to another Clair revision
or installed copy when the development workflow expects that source authority.

Public `Clair.Test.*` units are part of Clair's production artifact. Fasyn does
not consume Clair's private test projects or build Clair's unit suite. The only
additional provider-side test preparation is the build-machine
`gen-clair-test-registry` tool. Fasyn prepares it through Clair's
`rake host-tools` task; `host-tools` is not a Fasyn top-level task.

When `FASYN_CLAIR_PREPARED_ROOT` is supplied, test builds consume that
dependency root read-only. The root must be independent of the Clair source
checkout, and the caller must pair it with the matching source/toolchain
configuration. The registry generator must already exist there; Fasyn does not
rebuild missing provider artifacts in prepared mode.

## Conformance Discipline

Implementation changes require a reproducible failure at the FastCGI/Fasyn
boundary rather than an application-specific workaround. Do not document a test
command before the corresponding executable workflow exists.

FastCGI 1.0 completion criteria and automated evidence are owned by
`../architecture/protocol-conformance.md`.
