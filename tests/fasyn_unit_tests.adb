-- ============================================================================
-- fasyn_unit_tests.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Command_Line;
with Ada.Exceptions;
with GNAT.OS_Lib;

with Clair.Test.Reporter;
with Tests.Generated_Registry;

procedure Fasyn_Unit_Tests is
  reporter : Clair.Test.Reporter.Context;
begin
  Clair.Test.Reporter.configure_from_command_line (reporter);
  Clair.Test.Reporter.print_header (reporter);

  Tests.Generated_Registry.run_all (reporter);

  Clair.Test.Reporter.print_summary (reporter);

  if Clair.Test.Reporter.has_failures (reporter) then
    --  A failed scenario may have aborted before releasing worker tasks or
    --  descriptors.  Do not let those abandoned test resources turn a useful
    --  failure report into an indefinitely hung test process.
    GNAT.OS_Lib.OS_Exit (1);
  else
    Ada.Command_Line.set_exit_status (Ada.Command_Line.Success);
  end if;

exception
  when e : others =>
    Clair.Test.Reporter.print_exception
      (reporter,
       Ada.Exceptions.exception_name (e),
       Ada.Exceptions.exception_message (e),
       Ada.Exceptions.exception_information (e));
    GNAT.OS_Lib.OS_Exit (1);
end Fasyn_Unit_Tests;
