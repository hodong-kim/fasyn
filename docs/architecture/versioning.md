# Version Policy

Versions use `MAJOR.MINOR.MICRO` and follow the traditional GNU/libtool-style
shared-library compatibility policy:

- ABI incompatibility: increment `MAJOR`, reset `MINOR` and `MICRO` to zero.
- Backward-compatible API addition: increment `MINOR`, reset `MICRO` to zero.
- Compatible bug fix: increment `MICRO`.

Compatibility covers Fasyn's supported consumer-facing Ada specifications and
the behavioral contracts documented under `docs/architecture/`. Source
visibility alone does not establish support. Package families named `.Internal`
and equivalent implementation children are explicitly outside the supported API
boundary; they may ship in the source-backed runtime so Fasyn packages can share
bounded implementation seams, but consumers shall not depend on their
identifiers, declarations, or behavior remaining compatible. Private
representation and other undocumented implementation details are likewise not
compatibility commitments.

Fasyn currently ships a static-pic Ada library plus a source-backed runtime
project. Compatibility therefore means that clients written against the
supported package specifications and documented contracts continue to compile
and behave compatibly. The exported GPR entry points, `fasyn.gpr` and
`fasyn_runtime.gpr`, are part of that source/build interface; their inclusion of
an implementation source unit does not promote that unit into supported API.

Fasyn does not promise a cross-release binary ABI for compiler-generated Ada
representation. Unless a public specification explicitly defines a
representation contract, the binary layout of Ada types -- including public
logical records as well as private/limited types -- plus ALI files and object
files may change. Consumers are expected to rebuild against the release
toolchain. Explicit wire codecs, not in-memory Ada record layout, define the
FastCGI byte representation.

Ada source compatibility also constrains what counts as a compatible addition.
For example, adding a literal to a published enumeration can break an exhaustive
`case`, adding an abstract primitive can break an existing interface
implementation, and adding an overload can make a previously legal call
ambiguous. Such changes are not minor/micro-compatible merely because existing
declarations were left in place.
