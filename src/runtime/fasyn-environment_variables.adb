-- ============================================================================
-- fasyn-environment_variables.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces.C;
with System;

package body Fasyn.Environment_Variables is

  use type Interfaces.C.int;

  function c_setenv
    (name      : System.Address;
     value     : System.Address;
     overwrite : Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "setenv";

  procedure set
    (name  : String;
     value : String)
  is
    c_name  : aliased String (1 .. name'Length + 1);
    c_value : aliased String (1 .. value'Length + 1);
    result  : Interfaces.C.int;
  begin
    --  WORKAROUND: GCC/GNAT 16 can route Ada.Environment_Variables.Set through
    --  __gnat_setenv's putenv fallback on FreeBSD, leaking the allocated
    --  "name=value" buffer whenever the same variable is replaced. GCC master
    --  fixed the defect and its POSIX detection upstream; see the patch
    --  discussion at:
    --  https://www.mail-archive.com/gcc-patches%40gcc.gnu.org/msg406115.html
    --  Keep this direct setenv path until the supported GNAT baseline contains
    --  the upstream fix.
    c_name (1 .. name'Length) := name;
    c_name (c_name'Last) := ASCII.NUL;
    c_value (1 .. value'Length) := value;
    c_value (c_value'Last) := ASCII.NUL;

    result := c_setenv (c_name'Address, c_value'Address, 1);
    if result /= 0 then
      raise Constraint_Error with "environment variable cannot be defined";
    end if;
  end set;

end Fasyn.Environment_Variables;
