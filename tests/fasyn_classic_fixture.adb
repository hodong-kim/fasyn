-- ============================================================================
-- fasyn_classic_fixture.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Command_Line;
with Interfaces.C;
with System.Storage_Elements;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Clair.Unix.Signal;
with Fasyn.Classic;
with Fasyn.Listener;

procedure Fasyn_Classic_Fixture is

  use type Clair.IO.Byte_Count;
  use type Clair.Status.Code;
  use type Clair.Unix.Signal.Number;

  type Accept_Recorder is new Fasyn.Listener.Accept_Handler with record
    count : Natural := 0;
  end record;

  overriding function on_accept
    (self : in out Accept_Recorder;
     fd   : Clair.IO.Descriptor) return Clair.Status.Code
  is
  begin
    self.count := self.count + 1;
    return Clair.IO.close (fd);
  end on_accept;

  procedure finish (code : Ada.Command_Line.Exit_Status) is
  begin
    Ada.Command_Line.set_exit_status (code);
  end finish;

  loop_context : aliased Clair.Event_Loop.Context;
  classic      : aliased Fasyn.Classic.Context;
  recorder     : aliased Accept_Recorder;
  status       : Clair.Status.Code;
  dispatched   : Boolean := False;
  signal_set   : Clair.Unix.Signal.Set;
  previous_set : Clair.Unix.Signal.Set;
  signo        : Clair.Unix.Signal.Number := Clair.Unix.Signal.TERMINATION;
  signal_masked : Boolean := False;
  loop_ready    : Boolean := False;
  classic_ready : Boolean := False;

  function cleanup return Clair.Status.Code is
    cleanup_status : Clair.Status.Code := Clair.Status.OK;
    item_status    : Clair.Status.Code;
  begin
    if classic_ready then
      item_status := Fasyn.Classic.finalize (classic);
      if item_status /= Clair.Status.OK then
        cleanup_status := item_status;
      end if;
      classic_ready := False;
    end if;

    if loop_ready then
      item_status := Clair.Event_Loop.finalize (loop_context);
      if item_status /= Clair.Status.OK then
        cleanup_status := item_status;
      end if;
      loop_ready := False;
    end if;

    if signal_masked then
      item_status := Clair.Unix.Signal.replace_current_thread_mask
        (previous_set, signal_set);
      if item_status /= Clair.Status.OK then
        cleanup_status := item_status;
      end if;
      signal_masked := False;
    end if;

    return cleanup_status;
  end cleanup;

begin
  if Ada.Command_Line.argument_count < 1 or else
     Ada.Command_Line.argument_count > 2
  then
    finish (64);
    return;
  end if;

  if Ada.Command_Line.argument(1) = "wait-term" then
    status := Clair.Unix.Signal.set_empty (signal_set);
    if status = Clair.Status.OK then
      status := Clair.Unix.Signal.set_add
        (signal_set, Clair.Unix.Signal.TERMINATION);
    end if;
    if status = Clair.Status.OK then
      status := Clair.Unix.Signal.block_current_thread
        (signal_set, previous_set);
      signal_masked := status = Clair.Status.OK;
    end if;
    if status /= Clair.Status.OK then
      finish (65);
      return;
    end if;
  end if;

  status := Clair.Event_Loop.initialize (loop_context);
  loop_ready := status = Clair.Status.OK;
  if status /= Clair.Status.OK then
    finish (66);
    return;
  end if;

  status := Fasyn.Classic.initialize
    (self       => classic,
     event_loop => loop_context'Unchecked_Access,
     handler    => recorder'Unchecked_Access);
  classic_ready := status = Clair.Status.OK;
  if status /= Clair.Status.OK then
    declare
      cleanup_status : constant Clair.Status.Code := cleanup;
    begin
      if cleanup_status = Clair.Status.OK then
        finish (67);
      else
        finish (72);
      end if;
    end;
    return;
  end if;

  if Ada.Command_Line.argument(1) = "wait-term" and then
     Ada.Command_Line.argument_count = 2
  then
    declare
      ready_fd    : constant Clair.IO.Descriptor :=
        Clair.IO.Descriptor(Integer'Value(Ada.Command_Line.argument(2)));
      ready_byte  : aliased System.Storage_Elements.Storage_Element := 1;
      ready_count : Clair.IO.Byte_Count;
      close_status : Clair.Status.Code;
    begin
      status := Clair.IO.write
        (ready_fd, ready_byte'Address, Interfaces.C.size_t(1), ready_count);
      close_status := Clair.IO.close (ready_fd);

      if status /= Clair.Status.OK or else
         ready_count /= 1 or else
         close_status /= Clair.Status.OK
      then
        declare
          cleanup_status : constant Clair.Status.Code := cleanup;
        begin
          if cleanup_status = Clair.Status.OK then
            finish (73);
          else
            finish (72);
          end if;
        end;
        return;
      end if;
    end;
  end if;

  if Ada.Command_Line.argument(1) = "accept" then
    for iteration in 1 .. 20 loop
      pragma Unreferenced (iteration);
      status := Clair.Event_Loop.iterate (loop_context, 100, dispatched);
      exit when status /= Clair.Status.OK or else dispatched;
    end loop;

    declare
      cleanup_status : constant Clair.Status.Code := cleanup;
    begin
      if status /= Clair.Status.OK or else
         cleanup_status /= Clair.Status.OK
      then
        finish (68);
      elsif not dispatched then
        finish (69);
      elsif recorder.count = 1 then
        finish (0);
      else
        finish (70);
      end if;
    end;

  elsif Ada.Command_Line.argument(1) = "wait-term" then
    status := Clair.Unix.Signal.wait (signal_set, signo);

    declare
      cleanup_status : constant Clair.Status.Code := cleanup;
    begin
      if status = Clair.Status.OK and then
         signo = Clair.Unix.Signal.TERMINATION and then
         cleanup_status = Clair.Status.OK
      then
        finish (0);
      else
        finish (71);
      end if;
    end;

  else
    declare
      cleanup_status : constant Clair.Status.Code := cleanup;
    begin
      if cleanup_status = Clair.Status.OK then
        finish (64);
      else
        finish (72);
      end if;
    end;
  end if;
end Fasyn_Classic_Fixture;
