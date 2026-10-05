-- ============================================================================
-- fasyn_unit_tests.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Interfaces;
with Interfaces.C;

with Clair.Process.Memory;
with Clair.Status;
with Clair.Test.Reporter;
with Tests.Generated_Registry;

procedure Fasyn_Unit_Tests is
  use type Clair.Status.Code;
  use type Interfaces.Unsigned_64;

  reporter : Clair.Test.Reporter.Context;

  function current_rss_kb return Long_Long_Integer is
    usage  : Clair.Process.Memory.Usage;
    status : Clair.Status.Code;
    kib    : Interfaces.Unsigned_64;
  begin
    status := Clair.Process.Memory.query_current_usage (usage);
    if status /= Clair.Status.OK then
      return -1;
    end if;

    kib := usage.resident_bytes / 1024;
    if usage.resident_bytes mod 1024 /= 0 then
      kib := kib + 1;
    end if;

    if kib > Interfaces.Unsigned_64 (Long_Long_Integer'Last) then
      return -1;
    end if;

    return Long_Long_Integer (kib);
  end current_rss_kb;

  function c_open_fd_count return Interfaces.C.long
  with import,
       convention    => c,
       external_name => "fasyn_test_open_fd_count";

  function repeat_count return Positive is
    name : constant String := "FASYN_TEST_REPEAT";
  begin
    if not Ada.Environment_Variables.exists(name) then
      return 1;
    end if;

    declare
      value : constant Integer :=
        Integer'Value(Ada.Environment_Variables.value(name));
    begin
      if value <= 0 or else value > 10_000 then
        raise Constraint_Error;
      end if;
      return Positive(value);
    end;
  exception
    when Constraint_Error =>
      raise Program_Error with
        "FASYN_TEST_REPEAT must be an integer in 1 .. 10000";
  end repeat_count;

  function image (value : Long_Long_Integer) return String is
  begin
    return Ada.Strings.Fixed.trim
      (Long_Long_Integer'Image(value), Ada.Strings.Both);
  end image;

  repeats : constant Positive := repeat_count;
begin
  Clair.Test.Reporter.configure_from_command_line (reporter);
  Clair.Test.Reporter.print_header (reporter);

  for iteration in 1 .. repeats loop
    Tests.Generated_Registry.run_all (reporter);

    if Clair.Test.Reporter.has_failures (reporter) then
      Clair.Test.Reporter.print_summary (reporter);
      --  A failed scenario may have aborted before releasing worker tasks or
      --  descriptors.  Do not let those abandoned test resources turn a useful
      --  failure report into an indefinitely hung test process.
      GNAT.OS_Lib.OS_Exit (1);
    end if;

    if repeats > 1 then
      declare
        rss_kb : constant Long_Long_Integer := current_rss_kb;
        fds    : constant Interfaces.C.long := c_open_fd_count;
      begin
        Ada.Text_IO.put_line
          ("[SOAK] iteration=" & image(Long_Long_Integer(iteration)) &
           "/" & image(Long_Long_Integer(repeats)) &
           " rss_kb=" & image(rss_kb) &
           " fds=" & image(Long_Long_Integer(fds)));
        Ada.Text_IO.flush;
      end;
    end if;
  end loop;

  Clair.Test.Reporter.print_summary (reporter);
  Ada.Command_Line.set_exit_status (Ada.Command_Line.Success);

exception
  when e : others =>
    Clair.Test.Reporter.print_exception
      (reporter,
       Ada.Exceptions.exception_name (e),
       Ada.Exceptions.exception_message (e),
       Ada.Exceptions.exception_information (e));
    GNAT.OS_Lib.OS_Exit (1);
end Fasyn_Unit_Tests;
