# Clair Coding Style Guide

This guide originated in Clair and serves as the shared Ada coding-style
baseline for related projects. Project-specific architecture, safety, testing,
or compatibility rules take precedence when they conflict with this guide.

Examples use Clair, Adac, standard-library, external-interface, or generic
identifiers. The goal is consistent, readable, and predictable Ada source.

-----

## Rule Language

The following terms describe rule strength:

- **must** and **do not** state requirements;
- **should** and **avoid** state defaults that require a concrete reason to
  override;
- **may** states an optional form.

An imperative sentence without an explicit qualifier is a requirement.

When rules overlap, apply them in this order:

1. project-specific requirements;
2. the rule for the specific Ada construct;
3. the common formatting rules in this guide.

-----

## Quick Reference

- Indent with 2 spaces and do not use tabs.
- Keep code at or below 80 columns.
- Keep complete constructs on one line when permitted and they fit.
- Break at syntactic boundaries and preserve the construct's visual structure.
- Use `snake_case`, `Mixed_Case`, or `UPPER_CASE_WITH_UNDERSCORES`
  according to identifier role.
- Write comments in English and prefer explicit qualification when name origins
  are not obvious.

-----

## File Headers

The following file-header form is recommended, but not required:

```ada
-- ============================================================================
-- clair.gpr
-- Copyright (c) 2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================
```

Use the file's actual name and applicable copyright year.

-----

## Core Formatting

### Indentation

Use 2 spaces for each indentation level. Do not use tabs.

Continuation indentation follows the rule for the specific construct. Do not
add arbitrary indentation merely to make unrelated lines look aligned.

### Line Length

Keep each code line at or below 80 columns.

Before wrapping code, check whether a trailing comment is the only cause of the
excess. Move such a comment above the code rather than distorting the code's
layout.

### General Wrapping

Keep a complete construct on one line when it fits and no construct-specific
rule requires a vertical layout.

When wrapping is required:

1. preserve tightly coupled tokens, such as a conversion type and its opening
   parenthesis;
2. break at the outermost useful syntactic boundary;
3. keep the first meaningful element with the construct introducer when the
   specific rule permits it;
4. align continuation lines according to the structure of the construct;
5. prefer a stable layout that does not change because of a small name-length
   difference.

Do not introduce a line break immediately after a keyword when the following
constructor or expression still fits naturally on that line.

-----

## Declarations

### Object Declarations

Declare one object per declaration. Do not combine several object names before
one type separator.

```ada
px : Coord;
py : Coord;
pw : Coord;
ph : Coord;
```

Keep an object declaration on one line when it fits and its initializer is not
a multi-line aggregate.

When the declaration does not fit, or when its initializer spans multiple
lines, break before `:=`. Align `:=` with the declaration's type separator.

```ada
options : constant Formatter.Options
        := formatter.default_options;
```

This rule also applies when qualifiers such as `constant` or `aliased` make the
type portion long.

```ada
buffer : aliased Interfaces.C.char_array (0 .. 31)
       := [others => Interfaces.C.char'val (0)];
```

Within a contiguous declaration block, object names and type separators may be
aligned. Do not add alignment spaces to an isolated declaration.

```ada
req_name      : Ada.Strings.Unbounded.Unbounded_String;
req_max_count : Natural := 1000;
```

### Aggregate Initializers

For a multi-line aggregate initializer, keep `:=` and the opening delimiter on
the assignment continuation line. This applies to both parenthesized and
bracketed aggregates.

Align component associations with the first component. Within one aggregate,
align `=>` when doing so improves readability without excessive spacing.

```ada
range_config : constant Range_Config
             := (minimum => 0,
                 maximum => limit,
                 step    => 1);
```

```ada
initial_bytes : constant Byte_Array
              := [0      => HEADER_BYTE,
                  1      => VERSION_BYTE,
                  others => 0];
```

### Type Declarations

Keep a type declaration on one line when it fits.

When an array type declaration exceeds 80 columns, keep the declaration head
and index constraint on the first line when they fit. Break before `of` and put
the component type on the next line.

```ada
type Small_Array is array (1 .. 10) of Integer;
```

```ada
type External_Library_Handle_Table is array (0 .. MAX_REGISTERED_ITEMS)
  of External.Library.Handle;
```

Do not break immediately after `is` when the type constructor still fits on the
same line.

-----

## Subprograms

### Specifications

These rules apply to declarations and to the specification that begins a
subprogram body. They do not apply to calls.

Use the following forms in order:

1. A subprogram with zero or one parameter stays on one line when it fits.
2. A subprogram with two or more parameters uses a vertical parameter list,
   even when the complete specification would fit on one line.
3. In a vertical list, put each complete parameter declaration on its own line
   when it fits.
4. Align parameter names and type separators within the specification.
5. Do not combine several parameter names before one type separator in a
   vertical list.
6. A function with a vertical parameter list puts its `return` clause on a
   separate line aligned with the declaration.
7. When only the `return` clause makes a one-line function too long, move the
   `return` clause to the next line.

```ada
procedure close_file (handle : File_Handle);
```

```ada
procedure enqueue
  (self    : in out Context;
   item    : in Element_Type;
   success : out Boolean);
```

```ada
function find_matching_record
  (table : Record_Table;
   key   : Record_Key)
return Record_Access;
```

For a body with an empty declarative part, keep `is` on the final specification
line when it fits. When a function has a separate `return` clause, keep
`return ... is` together when it fits.

```ada
function make_token
  (kind     : Token_Kind;
   text     : String := "";
   position : Adac.Source.Position)
return Token is
begin
  null;
end make_token;
```

For a body with a non-empty declarative part, put `is` on a separate line
aligned with the subprogram keyword and `begin`.

```ada
procedure update_record_state
  (target : in out Record_State;
   code   : Status_Code;
   flags  : Update_Flags)
is
  changed : Boolean := False;
begin
  null;
end update_record_state;
```

### Calls

Keep a subprogram call on one line when it fits.

```ada
process_record (target, Record_Kind, record_data);
```

When a call exceeds 80 columns, break after the subprogram name and put the
complete argument list on the next line. The opening parenthesis begins that
line.

```ada
logger.write
  ("connection failed: " & Clair.Error.get_error_message (errno_code));
```

-----

## Expressions And Statements

### Type Conversions

Do not put a space between a type name and the opening parenthesis of a type
conversion.

```ada
return Token_Kind(current_token.kind);
```

When a conversion inside an aggregate association would make the line too long,
the type name may remain on the association line and the converted expression
may continue on the next line. Align the continuation under the conversion
expression.

```ada
timeout_ts : constant Clair.Time.Timespec :=
  (tv_sec  => Clair.Time.time_t(actual_timeout / 1000),
   tv_nsec => Interfaces.C.long
                ((actual_timeout rem 1000) * 1_000_000));
```

### Return Statements

Keep `return` and its expression on one line when they fit.

For a multi-line aggregate return value, keep `return` and the opening delimiter
with the first component when that line fits. Align the remaining components
with the first component and align `=>` within the aggregate.

```ada
return (kind     => kind,
        text     => Ada.Strings.Unbounded.to_unbounded_string (text),
        position => position);
```

Do not break immediately after `return` merely to put the aggregate on the next
line.

### Binary Expressions

When a binary expression spans multiple lines, put the operator at the end of
the continued line.

```ada
HEADER_BAR : constant String :=
  "======================================" &
  "======================================";
```

### Assignment Statements

In a contiguous block of two or more assignments at the same nesting level,
align `:=` vertically. Do not align across blank lines, comments, or nested
constructs.

```ada
self.req_state := state;
self.is_active := True;
```

-----

## Spacing

- Put one space between a subprogram name and the opening parenthesis in calls,
  declarations, and bodies: `close_file (handle)`.
- Put one space between an attribute name and an argument list:
  `Interfaces.C.int'image (fd)`.
- Write attributes without arguments directly after the prefix:
  `errmsg'length`.
- Do not put a space between a conversion type and its opening parenthesis:
  `Integer(value)`.
- Do not put a space between an array name and its index:
  `items(index)`.
- Put one space on both sides of `..`: `1 .. 10`.

-----

## Naming

Use a name shape that matches the identifier's role. Prefer complete words over
ad-hoc abbreviations when the full word is clear and reasonably short.

Code that mirrors an external interface may preserve external names or
abbreviations when doing so materially improves traceability. Identifiers
introduced locally still follow the normal naming rules.

### `snake_case`

Use lowercase words separated by underscores for:

- aspects and pragmas;
- variables and parameters;
- subprograms and entries;
- attributes as written in source;
- local constants that hold computed values in a narrow scope.

Use `retval` for a single, unambiguous status-code return value. When multiple
status values coexist, or when their roles affect error precedence, use
descriptive names such as `primary_status`, `cleanup_status`, or
`close_status`. For data values, use a name that describes the value, such as
`bytes_written`.

```ada
pragma import (c, my_func)
with convention => c
my_variable
get_item
errmsg'length
```

Ada aspect and convention identifiers follow this rule even when reference
material displays them in mixed case.

### `Mixed_Case`

Capitalize each word and separate words with underscores for:

- types and subtypes;
- enumeration literals and exceptions;
- protected objects and packages;
- loop names and `goto` labels.

Do not repeat a package name in a type declared inside that package. Use
`File.Descriptor`, not `File.File_Descriptor`.

Use all capitals for an abbreviation when mixed case would be misleading. Use
`Clair.DL`, not `Clair.Dl`.

```ada
Library_Load_Error
Main_Process_Loop
Clair.Process
Clair.DL
```

### `UPPER_CASE_WITH_UNDERSCORES`

Use all capitals with underscores for symbolic constants whose values are fixed
by program text and used as named constants. Preserve standard-library constant
names.

```ada
EXIT_SUCCESS
NULL_HANDLE : constant Handle := Handle(System.NULL_ADDRESS);
System.NULL_ADDRESS
```

-----

## Comments And Documentation

### Source Comments

Write comments in English so code review, maintenance, and tool-assisted
analysis share one working language.

Describe concrete behavior, intent, constraints, or non-obvious reasoning. Do
not restate the code.

Use one space between `--` and the comment text.

```ada
-- Initialize the subsystem.
```

Multiple spaces are allowed only for a specific formatting purpose.

```ada
-- Fields:
--   req_width
```

If a trailing comment makes a line exceed 80 columns, move the comment directly
above the code it describes. Do not wrap the code merely to retain the trailing
comment.

```ada
-- A negative value indicates unconstrained width.
req_max_width : Clair.Coord := -1;
```

### Public API Comments

Use `--!` comments on public API declarations when the contract, ownership,
outputs, return status, or non-obvious obligations require clarification.

Describe the public contract, not private implementation details. Do not expose
internal reference counts, backend-specific cleanup paths, garbage queues, or
similar details unless they are part of the contract.

Use these fields when applicable:

- `summary`
- `contract`
- `ownership`
- `outputs`
- `returns`
- `notes`

Write status names and code symbols in backticks, such as `OK`, `INVALID_STATE`,
`remove`, and `NULL_HANDLE`.

Document obligations and effects such as:

- required initialization state;
- nullability requirements;
- ownership transfer or consumption;
- output initialization on success or failure;
- expected status codes for recoverable failures.

Do not repeat obvious type information. For overloads with identical semantics,
document the first overload unless their contracts, ownership, outputs, or
return behavior differ.

-----

## `use` Clauses

Avoid broad or unnecessary `use` clauses.

A `use` clause may be used in a package body or narrow local scope when it
improves readability and the origin of imported identifiers remains obvious.

```ada
use Adac.Frontend.Tokens;
```

Prefer explicit qualification when the source package is not obvious or when
several packages define similar names.

Do not combine broad packages in a way that obscures identifier origins.

-----

## Design Conventions

These conventions affect API readability and source structure. Project-specific
design and architecture documents take precedence.

### Primary Type Names

Use `Object` for high-level, object-oriented entities with active behavior.

```ada
Window.Object
Button.Object
```

Use `Context` or `Handle` for low-level resource-management or execution-
environment abstractions.

```ada
Clair.Event_Loop.Context
Clair.DL.Handle
```

### Dot Notation

For tagged types, put the receiver first and usually name it `self` so Ada 2012
dot notation remains natural.

### Guard Clauses

Use guard clauses to avoid deeply nested conditionals. Check exceptional or
failure conditions first, then leave early with `return` or a named-loop
`goto`.

```ada
if not is_valid then
  goto Next_Item;
end if;

-- Main logic remains flat.
```
