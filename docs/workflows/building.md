# Building

Fasyn is written in Ada and uses Clair as its platform/runtime dependency.

## Toolchain

Use GNAT with Ada 2022 support and a compatible GPRbuild toolchain. The Rake
build driver requires Ruby and Rake.

By default, the Rake driver invokes `clang -dumpmachine` to detect the target
and host triples. Install Clang for this default workflow, or provide
`CLAIR_TARGET` (or `TARGET`) and `CLAIR_HOST_TARGET` explicitly. Set
`CLAIR_TARGET_OS` as well when it cannot be inferred from the target triple.
Conflicting primary/alias values and a target-OS value that contradicts the
target triple are configuration errors.

Fasyn shall use the same target architecture, ABI, build profile, and compatible
toolchain assumptions as the Clair artifact linked into it. `fasyn_config.gpr`
reads the shared Clair target, build profile, artifact profile, and library
kind external values without importing Clair, so the core project remains
dependency-independent while using the same artifact identity. Debug builds use
`-O0 -g`; release builds use `-O2`.

On native macOS, Fasyn uses `GPRBUILD` when set, otherwise GPRbuild on `PATH`,
then the newest installed Alire GPRbuild under `XDG_DATA_HOME/alire/toolchains`
or `~/.local/share/alire/toolchains`. If its `gprconfig` cannot find Ada on
`PATH`, Fasyn selects the newest host-compatible GNAT from the sibling Alire
toolchains. The selected command and compiler environment are shared with the
Clair producer; the user's shell is not modified.

Fasyn reads Clair's public `rake --silent info` output to obtain
`CLAIR_LIBYAML_PREFIX`, `CLAIR_PCRE2_PREFIX`, and `CLAIR_GETTEXT_PREFIX`, then
passes those same values to Clair preparation and Fasyn's imported GPR
projects. Clair owns package discovery; Fasyn does not hardcode Homebrew paths
or reconstruct dependency link options. Explicit prefix overrides are handled
by Clair. This also applies to prepared roots: the caller must supply prefix
overrides if their artifacts use dependencies other than Clair's current
native defaults.

Native macOS compilation and linking use one deployment target for Clair and
Fasyn: `CLAIR_MACOS_DEPLOYMENT_TARGET` or `MACOSX_DEPLOYMENT_TARGET`, defaulting
to the host's `sw_vers -productVersion`. Conflicting overrides are rejected.

## Clair Source and Build Root

By default, the sibling `../clair` checkout is the Clair source authority.
`FASYN_CLAIR_ROOT` may select another source checkout.

Fasyn reads Clair's public projects directly from that source checkout. Clair
artifacts are produced under Fasyn's consumer-owned
`build/deps/clair` by setting `CLAIR_BUILD_ROOT` when invoking Clair's Rake
driver. The source checkout is not cloned, reset, cleaned, or used for mutable
build output.

A parent build may provide a prepared read-only artifact root with
`FASYN_CLAIR_PREPARED_ROOT`. In that mode Fasyn does not invoke Clair's
producer or clean that root. The matching Clair source checkout is still needed
for source-owned public GPR projects. A prepared root must be independent of the
Clair source checkout; the source tree itself, one of its descendants, or an
ancestor that contains it is rejected as a dependency-artifact root.

The caller providing a prepared root is responsible for pairing it with the
matching Clair source revision and compatible toolchain/sysroot configuration.
Fasyn consumes Clair through its public GPR boundary and intentionally does not
parse Clair's private build-stamp format to recreate provider-owned validation
policy.

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
on Linux, FreeBSD, and macOS. Windows runtime support is outside the current
public contract.

The test project imports `fasyn_runtime.gpr` and uses public
`Clair.Test.*` from the same production `libclair`. Clair no longer provides
or requires a separate consumer test runtime. Fasyn test discovery uses Clair's
host-side `gen-clair-test-registry` tool. In a normal Fasyn build the Rake
driver prepares it by invoking Clair's `rake host-tools` task; it is not a
Fasyn top-level task.

## Build Driver

Show the resolved development context with:

    rake info

Build all current production Fasyn sources with:

    rake build

or equivalently:

    rake

The build driver builds Clair from its source authority into
`build/deps/clair`, then builds the core `fasyn.gpr` library and compiles the
runtime project with the same target/profile/toolchain selection. Fasyn
GPRbuild treats the prepared Clair core as externally built, so consumer builds
do not recursively rebuild or clean the dependency.

For low-level debugging, the core project can be built directly with:

    gprbuild -P fasyn.gpr

and the runtime project can be compiled with a command equivalent to:

    gprbuild -c -r -P fasyn_runtime.gpr

The direct runtime invocation also requires the Clair source checkout on the
project path plus the same `CLAIR_BUILD_ROOT`, target, target OS, build/artifact
profile, security instrumentation, library kind, and matching GPR target
selection used by the producer build. Pass
`CLAIR_CORE_EXTERNALLY_BUILT=True` so GPRbuild consumes the prepared Clair
artifact rather than rebuilding it. Prefer `rake build` for reproducible
development builds.

Build products are isolated by target and dependency artifact identity under
`build/`:

    build/obj/<target>/<artifact-profile>/core/
    build/obj/<target>/<artifact-profile>/runtime/
    build/lib/<target>/<artifact-profile>/
    build/obj/<target>/<artifact-profile>/tests/
    build/bin/<target>/<artifact-profile>/tests/
    build/gen/<target>/<artifact-profile>/tests/

The Fasyn artifact profile combines Clair's artifact profile with the selected
Clair library kind. For example, the ordinary release/static-pic configuration
uses `release-clair-static-pic`; a security-instrumented profile remains
separate as well. This prevents stale Ada objects, libraries, runtime units,
generated test registries, or executables from being reused across incompatible
target ABIs, build/security profiles, or dependency library kinds.

Dependency artifacts are isolated under `build/deps/clair`; that directory
contains build outputs only, not a Clair source checkout. A direct
`gprbuild -P fasyn.gpr` with no external target uses the
`native/release-clair-static-pic` namespace; pass the same external values as
Clair when reproducing a Rake-managed build directly.

## Alire

Alire is an additional build entry point, not a replacement for the Rake and
GPRbuild workflows above. The root `alire.toml` exports `fasyn.gpr` and
`fasyn_runtime.gpr`, disables generated Alire configuration, and declares Clair
as a production dependency.

When Alire resolves Clair, Clair owns its target preparation before GPRbuild
consumes `clair.gpr`; Fasyn does not duplicate that provider policy. A normal
resolved build is:

    alr build

Do not commit a local Clair path pin to Fasyn. Repository acceptance before
public catalog resolution uses a temporary pin only inside the isolated
`rake test-alire` workflow; `testing.md` owns that acceptance procedure.

Inside a resolved Alire environment the Rake driver discovers Clair through
`CLAIR_ALIRE_PREFIX`. `FASYN_CLAIR_ROOT` remains the explicit override and takes
precedence, while a sibling `../clair` checkout remains the default outside
Alire.

Public dependency-resolution and Fasyn publication state are owned by
`../roadmaps/alire-support.md`.

## Test Build Boundary

Build the complete test executable set without running target programs with:

    rake test-build

This is the build-only entry point for native or cross target preparation. Test
execution, native-target checks, acceptance commands, suite coverage, soak, and
memory/interoperability gates are owned by `testing.md`.

## Cleaning

Remove Fasyn build products for the selected target/artifact profile with:

    rake clean

Remove every Fasyn-owned target/artifact-profile set and the default
consumer-owned Clair artifact root with:

    rake clean-all

An external `FASYN_CLAIR_PREPARED_ROOT` is never removed by Fasyn cleanup.

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
