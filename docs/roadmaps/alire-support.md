# Alire Support Roadmap

## Purpose

Track the remaining work required to make Fasyn consumable from the public
Alire catalog while preserving Rake/GPRbuild as the normal non-Alire workflow.

## Current State

Repository-level Alire integration is implemented. The root `alire.toml`
exports `fasyn.gpr` and `fasyn_runtime.gpr`, disables generated Alire
configuration, and declares Clair as a production dependency. No local or
repository URL pin is committed.

The manifest uses `1.0.0` for the first public release candidate; the
publication hold below remains in effect.
FreeBSD canonical `rake test` passes the native suite, soak, executor lifecycle,
and callback resource gates for this candidate.

`rake test-alire` validates the repository in temporary workspaces. It uses a
source-only snapshot of the selected Clair checkout, pins only the temporary
Fasyn copy to that snapshot, builds Fasyn, runs the native acceptance suite,
and builds/runs a separate consumer of the Clair-backed runtime. Repository
Alire state and dependency build artifacts are not reused.

Alire remains optional. `rake build`, `rake test`, and direct GPRbuild workflows
must continue to work without `alr`.

Version compatibility follows `../architecture/versioning.md`. The unpublished
first release is not yet a compatibility baseline.

## Remaining Work

### 1. Publication Hold

Do not publish Fasyn merely because repository integration is technically
ready. Publication requires an explicit maintainer decision.

### 2. Public Clair Resolution

Before Fasyn can be consumed from the catalog by name, Clair must be resolvable
through the supported public Alire index with a version compatible with Fasyn.
Do not add a committed local path or moving repository pin as a substitute.

This roadmap does not authorize modifying Clair from the Fasyn work tree. If a
Fasyn acceptance run exposes a required Clair source change, make that change in
Clair as a separate work unit.

### 3. Unpinned Catalog Acceptance

Once Clair resolves from the public index, run:

    rake alire:catalog_preflight

The preflight must succeed with no committed Clair pin and must build/run an
external consumer that exercises the Clair-backed Fasyn runtime.

Also verify a clean Fasyn checkout with:

    alr build

Then verify a clean external consumer using the normal user workflow:

    alr with fasyn
    alr build

Acceptance requires that users do not need `FASYN_CLAIR_ROOT`, a sibling
checkout, a local pin, or extra GPR switches for catalog consumption.

### 4. Fasyn Catalog Publication

Publish only after the unpinned acceptance above passes and the maintainer ends
the publication hold. Published metadata and dependency constraints must match
versions that users can actually resolve.

After publication, repeat the clean external-consumer test using catalog names
only. Remove this roadmap once publication and post-publication acceptance are
complete and any durable procedure belongs in the development documentation.

## Verification Rule

Every Alire-related source or build change shall finish with:

- `rake build` without requiring Alire;
- `rake test` without requiring Alire;
- `rake test-alire` where the accepted Alire environment is available;
- `git diff --check`; and
- confirmation that Fasyn did not modify the selected Clair source working tree.

Catalog publication work additionally requires the unpinned preflight and clean
external-consumer acceptance above.
