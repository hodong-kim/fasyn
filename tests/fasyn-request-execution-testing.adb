-- ============================================================================
-- fasyn-request-execution-testing.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Request.Execution.Testing is

  function output_capacity (item : Completion) return Positive is
  begin
    if item.item = null then
      raise Program_Error with "completion has no work item";
    end if;
    return item.item.response.max_output_bytes;
  end output_capacity;

  function completion_delivery_budget return Positive is
  begin
    return COMPLETION_BYTES_PER_NOTIFICATION;
  end completion_delivery_budget;

  function deferred_index_consistent (self : Context) return Boolean is
  begin
    return internal_deferred_indices_consistent(self);
  end deferred_index_consistent;

  procedure seed_next_connection_identity
    (self : in out Context; value : Connection_Identity)
  is
  begin
    if value = NO_CONNECTION_IDENTITY then
      raise Program_Error with "test connection identity must be nonzero";
    end if;
    self.next_connection_identity := value;
    self.connection_identity_exhausted := False;
  end seed_next_connection_identity;

  function admission_index_churn_consistent return Boolean is
    capacity : constant Positive := 64;
    state : Admission_State (capacity => capacity);
    callback_context : aliased Fasyn.Request.Context (callback_owned => True);
    result : Reservation_Result;
    cause : Cancellation_Cause;
    context : Callback_Context_Access;
    request : Identity;

    function make_identity
      (request_id : Positive;
       generation_value : Generation := 1) return Identity
    is
    begin
      return
        (connection_id => 1,
         request_id    => Fasyn.Protocol.Request_Id(request_id),
         generation    => generation_value);
    end make_identity;
  begin
    for request_id in 1 .. capacity loop
      state.reserve (make_identity(request_id), result);
      if result /= Reservation_Accepted then
        return False;
      end if;
    end loop;
    if state.reserved_count /= capacity or else not state.indices_consistent then
      return False;
    end if;

    state.reserve (make_identity(capacity / 2), result);
    if result /= Reservation_Duplicate then
      return False;
    end if;
    state.reserve (make_identity(capacity + 1), result);
    if result /= Reservation_Full then
      return False;
    end if;

    state.note_cancellation (make_identity(7), Peer_Abort, context);
    if context /= null then
      return False;
    end if;

    for request_id in 1 .. capacity loop
      state.bind_context
        (make_identity(request_id), callback_context'Unchecked_Access, cause);
      if (request_id = 7 and then cause /= Peer_Abort) or else
         (request_id /= 7 and then cause /= Not_Cancelled)
      then
        return False;
      end if;
    end loop;

    state.note_cancellation (make_identity(9), Resource_Limit, context);
    if context = null then
      return False;
    end if;

    for request_id in 1 .. capacity loop
      if request_id mod 2 = 0 then
        state.release (make_identity(request_id));
      end if;
    end loop;
    if state.reserved_count /= capacity / 2 or else
       not state.indices_consistent
    then
      return False;
    end if;

    for request_id in reverse 1 .. capacity loop
      if request_id mod 2 = 0 then
        request := make_identity(request_id, 2);
        state.reserve (request, result);
        if result /= Reservation_Accepted then
          return False;
        end if;
        state.bind_context
          (request, callback_context'Unchecked_Access, cause);
        if cause /= Not_Cancelled then
          return False;
        end if;
      end if;
    end loop;
    if state.reserved_count /= capacity or else not state.indices_consistent then
      return False;
    end if;

    for position in 1 .. capacity loop
      state.prepare_shutdown_entry
        (position, Runtime_Shutdown, request, context);
      if is_null(request) or else context = null then
        return False;
      end if;
    end loop;

    state.stop_accepting;
    state.reserve (make_identity(capacity + 1), result);
    if result /= Reservation_Not_Accepting then
      return False;
    end if;

    for request_id in reverse 1 .. capacity loop
      if request_id mod 2 = 0 then
        state.release (make_identity(request_id, 2));
      else
        state.release (make_identity(request_id));
      end if;
    end loop;

    return state.is_empty and then state.reserved_count = 0 and then
      not state.has_capacity and then state.indices_consistent;
  exception
    when others =>
      return False;
  end admission_index_churn_consistent;

  procedure retire_deferred_request
    (self : in out Context; request : Identity)
  is
  begin
    retire_deferred (self, request);
  end retire_deferred_request;

end Fasyn.Request.Execution.Testing;
