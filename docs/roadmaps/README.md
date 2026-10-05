# Roadmaps

Roadmaps track current implementation and delivery work. Durable contracts
belong under `../architecture/`, reproducible procedures belong under
`../workflows/`, and source conventions belong under `../conventions/`.

Completed roadmaps are removed after any durable information has been moved to
the document that owns it. Version control retains historical investigation and
acceptance detail; roadmap files shall not duplicate that history.

## Current State

The FastCGI protocol/runtime implementation, public API cleanup, Clair API
migration, dependency-build isolation, security hardening, long-run resource
gates, callback-memory regression, and FreeBSD GNAT cleanup investigation are
complete as repository work. Their durable contracts and procedures live in the
architecture, workflow, and convention documentation.

The supported asynchronous runtime covers Linux, FreeBSD, and macOS. Platform
acceptance and test coverage are defined in `../workflows/testing.md`; a
completed API migration does not retain a separate roadmap solely for later
routine platform revalidation.

## Current Roadmaps

- `alire-support.md` - repository integration is implemented; remaining work is
  the public dependency-resolution and publication sequence.

## Work Ordering

Do not start speculative compatibility or publication work merely because a
technical gate exists. Follow the explicit remaining work in the active
roadmap, and remove that roadmap when its delivery gates are complete and its
durable procedures are owned elsewhere.
