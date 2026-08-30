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
and is supported on Linux and FreeBSD. Windows runtime support is not part of
the current public contract.

## Building

Fasyn requires GNAT with Ada 2022 support, GPRbuild, Ruby, and Rake. The
default Rake workflow also uses Clang to detect host and target triples unless
those target values are supplied explicitly.

    rake build

Run the native test suite with:

    rake test

Run the independent NGINX interoperability acceptance with:

    rake interop:nginx

See `docs/development/building.md` and `docs/development/testing.md` for details.

## Documentation

Architecture, conformance, resource, runtime, testing, and development documents
are indexed in `docs/README.md`.

## License

Fasyn is distributed under the Zero-Clause BSD License (0BSD). See `LICENSE`.
