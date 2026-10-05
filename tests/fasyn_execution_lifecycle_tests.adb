-- ============================================================================
-- fasyn_execution_lifecycle_tests.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Command_Line;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Interfaces;

with Clair.Event_Loop;
with Clair.Process.Memory;
with Clair.Status;
with Clair.Test.Assertions;
with Clair.Test.Reporter;
with Fasyn.Request.Execution;

procedure Fasyn_Execution_Lifecycle_Tests is
  package A renames Clair.Test.Assertions;
  package E renames Fasyn.Request.Execution;

  use type Clair.Status.Code;
  use type Interfaces.Unsigned_64;

  WARMUP_CYCLES : constant Positive := 1_000;
  BATCH_CYCLES  : constant Positive := 1_000;
  BATCH_COUNT   : constant Positive := 20;
  RSS_ALLOWANCE : constant Interfaces.Unsigned_64 := 512 * 1_024;

  procedure lifecycle_memory
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    baseline   : Clair.Process.Memory.Usage;
    sample     : Clair.Process.Memory.Usage;
    peak_rss   : Interfaces.Unsigned_64;
    status     : Clair.Status.Code;

    procedure cycle is
    begin
      status := E.initialize
        (executor, event_loop'Unchecked_Access,
         worker_count => 1, pending_capacity => 1,
         max_input_bytes => 64, max_output_bytes => 128,
         deferred_capacity => 4);
      A.assert_true
        (reporter, status = Clair.Status.OK, "executor initializes");
      status := E.begin_shutdown (executor);
      A.assert_true
        (reporter, status = Clair.Status.OK, "executor shutdown begins");
      status := E.finalize (executor);
      A.assert_true
        (reporter, status = Clair.Status.OK, "executor finalizes");
    end cycle;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "event loop initializes");

    for index in 1 .. WARMUP_CYCLES loop
      pragma Unreferenced (index);
      cycle;
    end loop;
    status := Clair.Process.Memory.query_current_usage (baseline);
    A.assert_true
      (reporter, status = Clair.Status.OK, "warmup RSS is available");
    peak_rss := baseline.resident_bytes;

    for batch in 1 .. BATCH_COUNT loop
      for index in 1 .. BATCH_CYCLES loop
        pragma Unreferenced (index);
        cycle;
      end loop;
      status := Clair.Process.Memory.query_current_usage (sample);
      A.assert_true
        (reporter, status = Clair.Status.OK, "batch RSS is available");
      peak_rss := Interfaces.Unsigned_64'Max (peak_rss, sample.resident_bytes);
      Ada.Text_IO.put_line
        ("[EXECUTION MEMORY] batch=" & Positive'Image(batch) &
         " rss_bytes=" & Interfaces.Unsigned_64'Image(sample.resident_bytes));
    end loop;

    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "event loop finalizes");
    Ada.Text_IO.put_line
      ("[EXECUTION MEMORY] baseline_bytes=" &
       Interfaces.Unsigned_64'Image(baseline.resident_bytes) &
       " peak_bytes=" & Interfaces.Unsigned_64'Image(peak_rss));
    -- Memcheck does not account for libthr's private mutex allocator. RSS
    -- detects a native lock retained by every otherwise successful teardown.
    A.assert_true
      (reporter, peak_rss - baseline.resident_bytes <= RSS_ALLOWANCE,
       "20,000 executor lifecycles retain at most 512 KiB after warmup");
  end lifecycle_memory;

  procedure run (reporter : in out Clair.Test.Reporter.Context) is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "executor lifecycle memory",
       lifecycle_memory'Unrestricted_Access);
  end run;

  reporter : Clair.Test.Reporter.Context;
begin
  Clair.Test.Reporter.configure_from_command_line (reporter);
  Clair.Test.Reporter.set_suite_count (reporter, 1);
  Clair.Test.Reporter.print_header (reporter);
  Clair.Test.Reporter.run_suite
    (reporter, "Execution lifecycle memory", run'Unrestricted_Access);
  Clair.Test.Reporter.print_summary (reporter);
  if Clair.Test.Reporter.has_failures(reporter) then
    -- Match the unit runner: interrupted cleanup must not hang a failed test.
    GNAT.OS_Lib.OS_Exit (1);
  end if;
  Ada.Command_Line.set_exit_status (Ada.Command_Line.Success);
end Fasyn_Execution_Lifecycle_Tests;
