# Building

Fasyn is written in Ada and uses Clair as its platform/runtime dependency.

## Toolchain

Use GNAT with Ada 2022 support and a compatible GPRbuild toolchain. The Rake
build driver requires Ruby and Rake.

By default, the Rake driver invokes `clang -dumpmachine` to detect the target
and host triples. Install Clang for this default workflow, or provide
`CLAIR_TARGET` (or `TARGET`) and `CLAIR_HOST_TARGET` explicitly. Set
`CLAIR_TARGET_OS` as well when it cannot be inferred from the target triple.

Fasyn shall use the same target architecture, ABI, build profile, and compatible
toolchain assumptions as the Clair artifact linked into it.

## Clair Checkout

By default, the Rake driver uses a sibling Clair checkout:

    projects/
      clair/
      fasyn/

The corresponding repository is:

    https://github.com/hodong-kim/clair

Select another checkout with:

    FASYN_CLAIR_ROOT=/path/to/clair rake info

The build driver validates that the selected Clair checkout exists. Fasyn must
not copy Clair sources into this repository to simulate a dependency.

## Project Boundary

`fasyn.gpr` builds the protocol/core static library and remains independent of
Clair's aggregate production library.

Clair-backed listener and connection runtime sources live under `src/runtime`
and are described by `fasyn_runtime.gpr`. This is a normal source project rather
than a second Fasyn library. It consumes Clair through the supported
`clair.gpr`/`clair_config.gpr` project boundary.

Keeping these two build roles separate avoids importing Clair's aggregate
library into the core Fasyn library project while still compiling every runtime
unit against the canonical Clair production interface.

The core `fasyn.gpr` library does not import Clair's POSIX I/O layer. The
Clair-backed runtime under `src/runtime` uses `Clair.IO.Posix` and is supported
on Linux and FreeBSD. Windows runtime support is outside the current public
contract.

The test project uses the corresponding Clair test runtime and compiles the same
Fasyn runtime sources directly into the test executable. This prevents a test
binary from linking duplicate Clair production/test aggregate libraries.

## Build Driver

Show the resolved development context with:

    rake info

Build all current production Fasyn sources with:

    rake build

or equivalently:

    rake

The build driver prepares the selected Clair target/profile, builds the core
`fasyn.gpr` library, and then compiles the runtime project with the same target
and profile. Runtime compilation is forced across its source units even though
`fasyn_runtime.gpr` intentionally has no main program.

For low-level debugging, the core project can be built directly with:

    gprbuild -P fasyn.gpr

and the runtime project can be compiled with a command equivalent to:

    gprbuild -c -r -P fasyn_runtime.gpr

The direct runtime invocation also requires the same Clair project search paths,
target variables, and build profile that the Rake driver supplies. Prefer
`rake build` for reproducible development builds.

Build products are placed under `build/`.

## Testing

Run the native test suite with:

    rake test

The underlying test project is `fasyn_tests.gpr`, and the current executable is:

    build/tests/bin/fasyn_unit_tests

See `testing.md` for current suite coverage.

## Cleaning

Remove Fasyn build products with:

    rake clean

## Generated and Build Artifacts

Generated files and build products shall remain outside source directories and
shall not be committed unless a specific platform contract requires a generated
source artifact to be versioned.

Target-specific build state shall not be shared across incompatible target
ABIs.

## Direct Platform Access

Before adding a native binding or platform shim, check whether Clair already
provides the required facility.

A Fasyn-specific native boundary is justified only when the operation is
intrinsically FastCGI-specific or Clair cannot reasonably own the generic
facility.
