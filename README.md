# Fasyn

Fasyn is an Ada implementation of the FastCGI 1.0 application-side interface.
It provides protocol codecs and a bounded asynchronous runtime for embedding
FastCGI applications while keeping HTTP and application-framework semantics
outside the library.

## Features

- FastCGI 1.0 record framing and incremental name-value encoding/decoding
- Responder, Authorizer, and Filter roles
- Management records and admission results
- Persistent connections and bounded request multiplexing
- Nonblocking connection handling with bounded backpressure
- Cancellation, request timeouts, and graceful shutdown
- Deferred application completion with generation-safe request identity
- Classic inherited-listener process compatibility in the POSIX runtime

## Dependency

Fasyn uses [Clair](https://github.com/hodong-kim/clair) for generic operating-
system and runtime facilities. By default, the build expects the repositories to
be sibling checkouts:

    projects/
      clair/
      fasyn/

Set `FASYN_CLAIR_ROOT` to use a Clair checkout at another location.

## Platform Scope

The core protocol library built by `fasyn.gpr` does not depend on Clair's POSIX
I/O layer. The asynchronous runtime under `src/runtime` uses `Clair.IO.Posix`
and is supported on Linux, FreeBSD, and macOS. Windows runtime support is not
part of the current public contract.

## Building

Fasyn requires GNAT with Ada 2022 support, GPRbuild, Ruby, and Rake. The
default Rake workflow also uses Clang to detect host and target triples unless
those target values are supplied explicitly.

    rake build

Run the canonical native acceptance suite, including the bounded long-run
RSS/FD soak, with:

    rake test

For the single-pass development loop, use:

    rake test-fast

Fasyn also carries an Alire manifest that exports the protocol and runtime GPR
projects and declares Clair as a production dependency. Alire remains optional;
the existing Rake/GPRbuild workflow does not require `alr`. On Linux x86-64,
the repository integration is validated with:

    rake test-alire

That acceptance covers an Alire root build and a separate external consumer of
the Clair-backed runtime. Catalog publication remains gated on a publicly
resolvable Clair crate, clean unpinned catalog acceptance, and an explicit
Fasyn publication decision; no local dependency pin is committed to Fasyn.

Run the independent NGINX interoperability acceptance with:

    rake interop:nginx

See `docs/workflows/building.md` and `docs/workflows/testing.md` for details.

## Documentation

Architecture contracts, workflows, source conventions, and active roadmaps are
routed through `docs/README.md`.

## License

Fasyn is distributed under the Zero-Clause BSD License (0BSD). See `LICENSE`.
