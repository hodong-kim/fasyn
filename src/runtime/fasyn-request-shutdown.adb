-- ============================================================================
-- fasyn-request-shutdown.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Request.Shutdown is

  use type Clair.Event_Loop.Milliseconds;
  use type Clair.Status.Code;
  use type RC.Context_Access;

  type Deadline_Handler is limited new Clair.Event_Loop.Timer_Handler
    with record
    expired : Boolean := False;
  end record;

  overriding function on_timer
    (handler : in out Deadline_Handler;
     timer   : Clair.Event_Loop.Handle) return Clair.Status.Code;

  overriding function on_timer
    (handler : in out Deadline_Handler;
     timer   : Clair.Event_Loop.Handle) return Clair.Status.Code
  is
    pragma Unreferenced (timer);
  begin
    handler.expired := True;
    return Clair.Status.OK;
  end on_timer;

  function drain
    (event_loop   : in out Clair.Event_Loop.Context;
     executor     : in out E.Context;
     connections  : in Connection_Array;
     grace_period : Clair.Event_Loop.Milliseconds;
     result       : out Outcome) return Clair.Status.Code
  is
    deadline       : aliased Deadline_Handler;
    deadline_timer : Clair.Event_Loop.Handle;
    timer_owned    : Boolean := False;
    dispatched     : Boolean;
    depth          : Natural;
    status         : Clair.Status.Code;
    cleanup_status : Clair.Status.Code;

    function all_drained return Boolean is
    begin
      for index in connections'range loop
        if connections(index) /= null and then
           RC.is_active(connections(index).all)
        then
          return False;
        end if;
      end loop;

      return
        E.is_idle(executor) and then
        E.completed_count(executor) = 0;
    end all_drained;

    function remove_deadline return Clair.Status.Code is
    begin
      if not timer_owned then
        return Clair.Status.OK;
      end if;

      cleanup_status :=
        Clair.Event_Loop.remove (event_loop, deadline_timer);
      if cleanup_status = Clair.Status.OK then
        timer_owned := False;
      end if;

      return cleanup_status;
    end remove_deadline;

    function finalize_drained return Clair.Status.Code is
    begin
      for index in connections'range loop
        if connections(index) /= null then
          cleanup_status := RC.finalize (connections(index).all);
          if cleanup_status /= Clair.Status.OK then
            return cleanup_status;
          end if;
        end if;
      end loop;

      return E.finalize (executor);
    end finalize_drained;

    function force_close_connections return Clair.Status.Code is
    begin
      for index in connections'range loop
        if connections(index) /= null and then
           RC.is_active(connections(index).all)
        then
          cleanup_status := RC.finalize (connections(index).all);
          if cleanup_status /= Clair.Status.OK and then
             cleanup_status /= Clair.Status.INVALID_STATE
          then
            return cleanup_status;
          end if;
        end if;
      end loop;

      return Clair.Status.OK;
    end force_close_connections;

  begin
    result := Grace_Expired;

    if grace_period <= 0 then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    status := Clair.Event_Loop.get_depth (event_loop, depth);
    if status /= Clair.Status.OK then
      return status;
    end if;

    if depth /= 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Clair.Event_Loop.add_timer
      (self     => event_loop,
       interval => grace_period,
       handler  => deadline'Unchecked_Access,
       one_shot => True,
       source   => deadline_timer);
    if status /= Clair.Status.OK then
      return status;
    end if;
    timer_owned := True;

    for index in connections'range loop
      if connections(index) /= null and then
         RC.is_active(connections(index).all)
      then
        status := RC.begin_shutdown (connections(index).all);
        if status /= Clair.Status.OK then
          cleanup_status := remove_deadline;
          if cleanup_status /= Clair.Status.OK then
            return cleanup_status;
          end if;
          return status;
        end if;
      end if;
    end loop;

    if E.is_accepting(executor) then
      status := E.begin_shutdown (executor);
      if status /= Clair.Status.OK then
        cleanup_status := remove_deadline;
        if cleanup_status /= Clair.Status.OK then
          return cleanup_status;
        end if;
        return status;
      end if;
    end if;

    loop
      if all_drained then
        cleanup_status := remove_deadline;
        if cleanup_status /= Clair.Status.OK then
          return cleanup_status;
        end if;

        status := finalize_drained;
        if status = Clair.Status.OK then
          result := Drained;
        end if;
        return status;
      end if;

      exit when deadline.expired;

      status := Clair.Event_Loop.iterate
        (self       => event_loop,
         timeout    => grace_period,
         dispatched => dispatched);
      if status /= Clair.Status.OK then
        cleanup_status := remove_deadline;
        if cleanup_status /= Clair.Status.OK then
          return cleanup_status;
        end if;
        return status;
      end if;
    end loop;

    cleanup_status := remove_deadline;
    if cleanup_status /= Clair.Status.OK then
      return cleanup_status;
    end if;

    status := force_close_connections;
    if status /= Clair.Status.OK then
      return status;
    end if;

    result := Grace_Expired;
    return Clair.Status.OK;
  end drain;

end Fasyn.Request.Shutdown;
