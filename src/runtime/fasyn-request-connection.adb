-- ============================================================================
-- fasyn-request-connection.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Unchecked_Deallocation;
with Interfaces;
with System.Storage_Elements;
with Clair.IO.Posix;
with Clair.Network;
with Fasyn.Protocol;
with Fasyn.Protocol.Messages;
with Fasyn.Protocol.Name_Values;

package body Fasyn.Request.Connection is

  package D renames Fasyn.Diagnostics;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package M renames Fasyn.Protocol.Messages;
  package N renames Fasyn.Protocol.Name_Values;

  use type Clair.Event_Loop.Context_Access;
  use type Clair.Event_Loop.Event_Mask;
  use type Clair.Event_Loop.Handle;
  use type Clair.Event_Loop.Milliseconds;
  use type Clair.IO.Byte_Count;
  use type Clair.IO.Descriptor;
  use type Clair.Status.Code;
  use type Interfaces.Unsigned_8;
  use type A.Context_Access;
  use type C.Decode_Status;
  use type D.Reporter_Access;
  use type C.Record_Event;
  use type E.Context_Access;
  use type E.Operation_Kind;
  use type E.Deferred_Output_Kind;
  use type M.Body_Status;
  use type P.Request_Id_Type;
  use type P.Role;
  use type PM.Query_Status;
  use type PM.Result_Status;
  use type System.Storage_Elements.Storage_Count;

  MAX_READS_PER_CALLBACK  : constant Positive := 16;
  MAX_WRITES_PER_CALLBACK : constant Positive := 16;
  procedure Free_Slot is new Ada.Unchecked_Deallocation
    (Object => Request_Slot,
     Name   => Request_Slot_Access);

  function refresh_watch
    (self : in out Context) return Clair.Status.Code;

  function process_pending_input
    (self : in out Context) return Clair.Status.Code;

  function try_submit_deferred
    (self : in out Context) return Clair.Status.Code;

  procedure mark_deferred_busy (self : in out Context);

  procedure publish_deferred_state
    (self : in out Context;
     busy : Boolean);

  function has_event
    (events : Clair.Event_Loop.Event_Mask;
     item   : Clair.Event_Loop.Event_Mask) return Boolean
  is
  begin
    return (events and item) /= 0;
  end has_event;

  procedure reset_slot (slot : in out Request_Slot) is
  begin
    N.reset (slot.exchange.params_decoder);
    slot.exchange.begin_body := [others => 0];
    slot.exchange.connection_id := NO_CONNECTION_IDENTITY;
    slot.exchange.request_id := 0;
    slot.exchange.generation := NO_GENERATION;
    slot.exchange.role_value := P.Responder;
    slot.exchange.current_record_type := 0;
    slot.exchange.current_content_length := 0;
    slot.exchange.content_remaining := 0;
    slot.exchange.active := False;
    slot.exchange.complete_flag := False;
    slot.exchange.record_open := False;
    slot.exchange.params_closed := False;
    slot.exchange.stdin_closed := False;
    slot.exchange.data_closed := False;
    slot.exchange.filter_data_length_seen := False;
    slot.exchange.filter_data_last_mod_seen := False;
    slot.exchange.filter_data_length := 0;
    slot.exchange.filter_data_received := 0;
    slot.exchange.keep_flag := False;
    slot.exchange.cancel_reason := Not_Cancelled;
    slot.exchange.failed := False;

    slot.response.length := 0;
    slot.response.limit := slot.response.max_output_bytes;
    slot.params_bytes := 0;
    slot.stdin_bytes := 0;
    slot.data_bytes := 0;
    slot.application_deferred := False;
    slot.response.request_id := 0;
    slot.response.initialized := False;
    slot.response.finished := False;
    slot.response.deferred := False;
    slot.response.failed := False;

    slot.identity_value := NULL_REQUEST_IDENTITY;
    slot.timeout_timer := Clair.Event_Loop.NULL_HANDLE;
    slot.in_use := False;
  end reset_slot;

  procedure release_slots (self : in out Context) is
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null then
        Free_Slot (self.slots(index));
      end if;
    end loop;
  end release_slots;

  procedure reset_management (self : in out Context) is
  begin
    PM.reset (self.management_query);
    self.management_active := False;
    self.management_record_type := 0;
  end reset_management;

  procedure release_admission (self : in out Context) is
  begin
    if self.shared_admission = null then
      return;
    end if;

    for index in self.slots'range loop
      if self.slots(index) /= null and then self.slots(index).in_use then
        A.release_request (self.shared_admission.all);
      end if;
    end loop;

    if self.admission_connection_owned then
      A.release_connection (self.shared_admission.all);
      self.admission_connection_owned := False;
    end if;

    self.shared_admission := null;
  end release_admission;

  procedure clear_deferred (self : in out Context) is
  begin
    self.deferred_name_length := 0;
    self.deferred_value_length := 0;
    self.deferred_data_length := 0;
    self.deferred_request := NULL_REQUEST_IDENTITY;
    self.deferred_active := False;
  end clear_deferred;

  function remove_retry_timer
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not self.retry_timer_active then
      return Clair.Status.OK;
    end if;

    status := Clair.Event_Loop.remove
      (self.event_loop.all, self.retry_timer);

    if status = Clair.Status.OK then
      self.retry_timer_active := False;
    end if;

    return status;
  end remove_retry_timer;

  function remove_request_timer
    (self       : in out Context;
     slot_index : in Positive) return Clair.Status.Code
  is
  begin
    if self.slots(slot_index) = null then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.slots(slot_index).timeout_timer = Clair.Event_Loop.NULL_HANDLE then
      return Clair.Status.OK;
    end if;

    return Clair.Event_Loop.remove
      (self.event_loop.all, self.slots(slot_index).timeout_timer);
  end remove_request_timer;

  function remove_all_request_timers
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null then
        status := remove_request_timer (self, index);
        if status /= Clair.Status.OK then
          return status;
        end if;
      end if;
    end loop;

    return Clair.Status.OK;
  end remove_all_request_timers;

  function arm_request_timer
    (self       : in out Context;
     slot_index : in Positive) return Clair.Status.Code
  is
  begin
    if self.slots(slot_index) = null then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.slots(slot_index).timeout_timer /= Clair.Event_Loop.NULL_HANDLE then
      return Clair.Status.INVALID_STATE;
    end if;

    return Clair.Event_Loop.add_timer
      (self     => self.event_loop.all,
       interval => self.request_timeout,
       handler  => self'Unchecked_Access,
       one_shot => True,
       source   => self.slots(slot_index).timeout_timer);
  end arm_request_timer;

  function find_timer_slot
    (self  : Context;
     timer : Clair.Event_Loop.Handle) return Natural
  is
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null and then
         self.slots(index).timeout_timer = timer
      then
        return index;
      end if;
    end loop;

    return 0;
  end find_timer_slot;

  function clear_deferred_for
    (self    : in out Context;
     request : Request_Identity) return Clair.Status.Code
  is
  begin
    if self.deferred_active and then self.deferred_request = request then
      clear_deferred (self);
      self.application_paused := self.inflight_jobs /= 0;
      return remove_retry_timer (self);
    end if;

    return Clair.Status.OK;
  end clear_deferred_for;

  function close_owned (self : in out Context) return Clair.Status.Code is
    status       : Clair.Status.Code;
    timer_status : Clair.Status.Code;
  begin
    mark_deferred_busy (self);

    if self.executor /= null then
      for index in self.slots'range loop
        if self.slots(index) /= null and then self.slots(index).in_use then
          status := E.signal_cancellation
            (self.executor.all, self.slots(index).identity_value,
             Connection_Failure);
          if status /= Clair.Status.OK then
            return status;
          end if;
        end if;
      end loop;
    end if;

    if self.watch_active then
      status := Clair.Event_Loop.remove (self.event_loop.all, self.watch);
      if status /= Clair.Status.OK then
        return status;
      end if;

      self.watch_active := False;
    end if;

    timer_status := remove_retry_timer (self);
    if timer_status /= Clair.Status.OK then
      return timer_status;
    end if;

    timer_status := remove_all_request_timers (self);
    if timer_status /= Clair.Status.OK then
      return timer_status;
    end if;

    if self.fd /= Clair.IO.INVALID_DESCRIPTOR then
      status := Clair.IO.close (self.fd);
      if status /= Clair.Status.OK then
        return status;
      end if;

      self.fd := Clair.IO.INVALID_DESCRIPTOR;
    end if;

    release_admission (self);
    release_slots (self);
    self.initialized := False;
    self.connection_id := NO_CONNECTION_IDENTITY;
    self.active_requests := 0;
    self.current_slot := 0;
    self.next_output_slot := 1;
    self.output_source := NO_OUTPUT_SOURCE;
    self.output_record_remaining := 0;
    self.control_length := 0;
    self.input_first := 1;
    self.input_length := 0;
    self.stream_batch_length := 0;
    reset_management (self);
    self.read_paused := False;
    self.application_paused := self.inflight_jobs /= 0;
    self.dispatch_failed := False;
    self.skip_record := False;
    self.close_requested := False;
    self.shutdown_requested := False;
    clear_deferred (self);
    C.reset (self.decoder);
    return Clair.Status.OK;
  end close_owned;

  function find_slot
    (self       : Context;
     request_id : P.Request_Id_Type) return Natural
  is
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).identity_value.request_id = request_id
      then
        return index;
      end if;
    end loop;

    return 0;
  end find_slot;

  function find_slot
    (self    : Context;
     request : Request_Identity) return Natural
  is
    index : Natural;
  begin
    if is_null(request) or else request.connection_id /= self.connection_id then
      return 0;
    end if;

    index := find_slot (self, request.request_id);
    if index = 0 or else self.slots(index).identity_value /= request then
      return 0;
    end if;

    return index;
  end find_slot;

  function allocate_slot
    (self       : in out Context;
     request_id : P.Request_Id_Type) return Natural
  is
    generation : Request_Generation;
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null and then not self.slots(index).in_use then
        reset_slot (self.slots(index).all);

        generation := self.next_generation;
        if generation = NO_GENERATION then
          generation := 1;
        end if;

        self.next_generation := generation + 1;
        if self.next_generation = NO_GENERATION then
          self.next_generation := 1;
        end if;

        self.slots(index).identity_value :=
          (connection_id => self.connection_id,
           request_id    => request_id,
           generation    => generation);
        self.slots(index).in_use := True;
        self.active_requests := self.active_requests + 1;
        return index;
      end if;
    end loop;

    return 0;
  end allocate_slot;

  function direct_pending_output_bytes (self : Context) return Natural is
    total : Natural := self.control_length;
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null and then self.slots(index).in_use then
        total := total + self.slots(index).response.length;
      end if;
    end loop;

    return total;
  end direct_pending_output_bytes;

  function pending_output_bytes (self : Context) return Natural is
    direct : constant Natural := direct_pending_output_bytes(self);
    staged : Natural := 0;
  begin
    if self.executor /= null and then
       self.connection_id /= NO_CONNECTION_IDENTITY
    then
      staged := E.deferred_connection_pending_bytes
        (self.executor.all, self.connection_id);
    end if;

    if staged > Natural'Last - direct then
      raise Program_Error with "deferred output accounting overflow";
    end if;

    return direct + staged;
  end pending_output_bytes;

  function has_application_deferred (self : Context) return Boolean is
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).application_deferred
      then
        return True;
      end if;
    end loop;

    return False;
  end has_application_deferred;

  procedure mark_deferred_busy (self : in out Context) is
  begin
    if not has_application_deferred(self) then
      return;
    end if;

    if self.executor /= null and then
       self.connection_id /= NO_CONNECTION_IDENTITY
    then
      E.set_deferred_connection_busy
        (self.executor.all, self.connection_id, True);
    end if;
  end mark_deferred_busy;

  procedure publish_deferred_state
    (self : in out Context;
     busy : Boolean)
  is
  begin
    if self.executor = null or else
       self.connection_id = NO_CONNECTION_IDENTITY or else
       not has_application_deferred(self)
    then
      return;
    end if;

    E.sync_deferred_connection
      (self.executor.all,
       self.connection_id,
       direct_pending_output_bytes(self));

    for index in self.slots'range loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).application_deferred
      then
        E.sync_deferred_request
          (self.executor.all, self.slots(index).identity_value,
           self.slots(index).response.length);
      end if;
    end loop;

    E.set_deferred_connection_busy
      (self.executor.all, self.connection_id, busy);
  end publish_deferred_state;

  procedure prepare_writer_budget
    (self : Context;
     slot : in out Request_Slot)
  is
    total         : constant Natural := pending_output_bytes (self);
    own_pending   : constant Natural := slot.response.length;
    other_pending : Natural;
    available     : Natural;
  begin
    if total < own_pending then
      slot.response.limit := own_pending;
      return;
    end if;

    other_pending := total - own_pending;
    if other_pending >= self.max_output_bytes then
      available := own_pending;
    else
      available := self.max_output_bytes - other_pending;
    end if;

    slot.response.limit :=
      Natural'Min (slot.response.max_output_bytes, available);

    if slot.response.limit < own_pending then
      slot.response.limit := own_pending;
    end if;
  end prepare_writer_budget;

  function account_bytes
    (current : in out Natural;
     amount  : Natural;
     limit   : Positive) return Boolean
  is
  begin
    if current > limit or else amount > limit - current then
      return False;
    end if;

    current := current + amount;
    return True;
  end account_bytes;

  function account_input_record
    (self        : Context;
     slot        : in out Request_Slot;
     record_type : P.Byte;
     amount      : Natural) return Boolean
  is
  begin
    if record_type = P.PARAMS_TYPE then
      return account_bytes
        (slot.params_bytes, amount, self.input_limits.max_params_bytes);
    elsif record_type = P.STDIN_TYPE then
      return account_bytes
        (slot.stdin_bytes, amount, self.input_limits.max_stdin_bytes);
    elsif record_type = P.DATA_TYPE then
      return account_bytes
        (slot.data_bytes, amount, self.input_limits.max_data_bytes);
    end if;

    return True;
  end account_input_record;

  function mark_resource_limit
    (self       : in out Context;
     slot_index : Positive) return Clair.Status.Code
  is
    request : constant Request_Identity :=
      self.slots(slot_index).identity_value;
    status : Clair.Status.Code;
  begin
    status := clear_deferred_for (self, request);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.stream_batch_length := 0;
    self.skip_record := True;
    self.slots(slot_index).exchange.cancel_reason := Resource_Limit;

    status := E.signal_cancellation
      (self.executor.all, request, Resource_Limit);
    if status /= Clair.Status.OK then
      return status;
    end if;

    if self.diagnostics /= null then
      Fasyn.Diagnostics.report
        (self.diagnostics.all, Fasyn.Diagnostics.Resource_Error,
         Clair.Status.RANGE_ERROR,
         "FastCGI request input limit exceeded");
    end if;

    return Clair.Status.OK;
  end mark_resource_limit;

  function complete_resource_limit
    (self       : in out Context;
     slot_index : Positive) return Clair.Status.Code
  is
    request_status : Input_Status;
  begin
    prepare_writer_budget (self, self.slots(slot_index).all);
    cancel
      (self => self.slots(slot_index).exchange,
       response => self.slots(slot_index).response,
       cause => Resource_Limit, status => request_status);

    if request_status /= Request_Complete and then
       request_status /= Ignored_Inactive
    then
      return close_owned (self);
    end if;

    if request_status = Request_Complete and then
       not self.slots(slot_index).exchange.keep_flag
    then
      self.close_requested := True;
    end if;

    return Clair.Status.OK;
  end complete_resource_limit;

  function application_output_limit
    (self    : Context;
     request : Request_Identity) return Natural
  is
    slot_index           : constant Natural := find_slot (self, request);
    pending              : Natural;
    staged_request       : Natural := 0;
    request_used         : Natural;
    request_remaining    : Natural;
    connection_remaining : Natural;
  begin
    if slot_index = 0 then
      return 0;
    end if;

    if self.executor /= null then
      staged_request := E.deferred_pending_bytes (self.executor.all, request);
    end if;

    if staged_request >
         Natural'Last - self.slots(slot_index).response.length
    then
      return 0;
    end if;

    request_used := self.slots(slot_index).response.length + staged_request;
    if request_used >= self.slots(slot_index).response.max_output_bytes then
      request_remaining := 0;
    else
      request_remaining :=
        self.slots(slot_index).response.max_output_bytes - request_used;
    end if;

    pending := pending_output_bytes (self);
    if pending >= self.max_output_bytes then
      connection_remaining := 0;
    else
      connection_remaining := self.max_output_bytes - pending;
    end if;

    return Natural'Min (request_remaining, connection_remaining);
  end application_output_limit;

  function queue_control_record
    (self        : in out Context;
     record_type : P.Byte;
     request_id  : P.Request_Id_Type;
     content     : P.Byte_Array) return Boolean
  is
    record_length : constant Natural := P.HEADER_LENGTH + content'length;
    header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => request_id,
       content_length => P.Content_Length_Type(content'length),
       padding_length => 0,
       reserved       => 0);
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    if self.control_length + record_length > CONTROL_OUTPUT_CAPACITY or else
       self.max_output_bytes < record_length or else
       pending_output_bytes(self) > self.max_output_bytes - record_length
    then
      return False;
    end if;

    C.encode_header (header, header_bytes);

    for index in header_bytes'range loop
      self.control_length := self.control_length + 1;
      self.control_bytes(self.control_length) := header_bytes(index);
    end loop;

    for index in content'range loop
      self.control_length := self.control_length + 1;
      self.control_bytes(self.control_length) := content(index);
    end loop;

    return True;
  end queue_control_record;

  function queue_protocol_status
    (self            : in out Context;
     request_id      : P.Request_Id_Type;
     protocol_status : P.Byte) return Boolean
  is
    end_request : constant M.End_Request_Body :=
      (application_status   => 0,
       protocol_status_code => protocol_status);
    body_bytes  : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
    written     : Natural;
    body_status : M.Body_Status;
  begin
    M.encode_end_request
      (request_body => end_request,
       output       => body_bytes,
       written      => written,
       status       => body_status);

    return
      body_status = M.Body_Complete and then
      written = M.END_REQUEST_BODY_LENGTH and then
      queue_control_record
        (self,
         P.END_REQUEST_TYPE,
         request_id,
         body_bytes);
  end queue_protocol_status;

  function queue_cant_mpx
    (self       : in out Context;
     request_id : P.Request_Id_Type) return Boolean
  is
  begin
    return queue_protocol_status
      (self, request_id, P.CANT_MPX_CONN_STATUS);
  end queue_cant_mpx;

  function queue_overloaded
    (self       : in out Context;
     request_id : P.Request_Id_Type) return Boolean
  is
  begin
    return queue_protocol_status
      (self, request_id, P.OVERLOADED_STATUS);
  end queue_overloaded;

  function effective_management_values (self : Context) return PM.Values is
    max_connections : Positive := 1;
    max_requests    : Positive := self.max_requests_per_connection;
  begin
    if self.shared_admission /= null then
      max_connections := A.max_connections(self.shared_admission.all);
      max_requests := A.max_requests(self.shared_admission.all);
    end if;

    return
      (max_connections => max_connections,
       max_requests    => max_requests,
       multiplexing    =>
         self.max_requests_per_connection > 1 and then max_requests > 1);
  end effective_management_values;

  function queue_get_values_result
    (self : in out Context) return Boolean
  is
    result_bytes  : P.Byte_Array (1 .. MANAGEMENT_RESULT_CAPACITY);
    written       : Natural;
    result_status : PM.Result_Status;
  begin
    PM.encode_result
      (self.management_query,
       effective_management_values(self),
       result_bytes,
       written,
       result_status);

    if result_status /= PM.Result_Complete then
      return False;
    end if;

    if written = 0 then
      declare
        empty : P.Byte_Array (1 .. 0);
      begin
        return queue_control_record
          (self, P.GET_VALUES_RESULT_TYPE, 0, empty);
      end;
    end if;

    return queue_control_record
      (self,
       P.GET_VALUES_RESULT_TYPE,
       0,
       result_bytes(result_bytes'first .. result_bytes'first + written - 1));
  end queue_get_values_result;

  function queue_unknown_type
    (self        : in out Context;
     record_type : P.Byte) return Boolean
  is
    unknown_body : constant M.Unknown_Type_Body :=
      (record_type => record_type);
    body_bytes  : P.Byte_Array (0 .. M.UNKNOWN_TYPE_BODY_LENGTH - 1);
    written     : Natural;
    body_status : M.Body_Status;
  begin
    M.encode_unknown_type
      (unknown_body, body_bytes, written, body_status);

    return
      body_status = M.Body_Complete and then
      written = M.UNKNOWN_TYPE_BODY_LENGTH and then
      queue_control_record (self, P.UNKNOWN_TYPE_TYPE, 0, body_bytes);
  end queue_unknown_type;

  procedure update_backpressure (self : in out Context) is
    high_water : constant Natural :=
      self.max_output_bytes - self.max_output_bytes / 4;
    low_water : constant Natural := self.max_output_bytes / 2;
    pending   : constant Natural := pending_output_bytes (self);
  begin
    if self.read_paused then
      if pending <= low_water then
        self.read_paused := False;
      end if;
    elsif pending >= high_water then
      self.read_paused := True;
    end if;
  end update_backpressure;

  function ensure_retry_timer
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.retry_timer_active then
      return Clair.Status.OK;
    end if;

    status := Clair.Event_Loop.add_timer
      (self     => self.event_loop.all,
       interval => EXECUTION_RETRY_INTERVAL,
       handler  => self'Unchecked_Access,
       one_shot => True,
       source   => self.retry_timer);

    if status = Clair.Status.OK then
      self.retry_timer_active := True;
    end if;

    return status;
  end ensure_retry_timer;

  function begin_deferred
    (self      : in out Context;
     operation : E.Operation_Kind) return Boolean
  is
  begin
    if not self.initialized or else
       self.current_slot = 0 or else
       self.slots(self.current_slot) = null or else
       not self.slots(self.current_slot).in_use or else
       self.application_paused or else
       self.deferred_active or else
       self.inflight_jobs /= 0
    then
      self.dispatch_failed := True;
      return False;
    end if;

    self.deferred_request := self.slots(self.current_slot).identity_value;
    self.deferred_operation := operation;
    self.deferred_name_length := 0;
    self.deferred_value_length := 0;
    self.deferred_data_length := 0;
    self.deferred_active := True;
    self.application_paused := True;
    return True;
  end begin_deferred;

  procedure submit_or_fail (self : in out Context) is
    status : Clair.Status.Code;
  begin
    status := try_submit_deferred (self);
    if status /= Clair.Status.OK then
      self.dispatch_failed := True;
    end if;
  end submit_or_fail;

  overriding procedure on_parameter
    (self    : in out Dispatch_Application;
     context : in Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null or else
       name'length > owner.max_name_bytes or else
       value'length > owner.max_value_bytes
    then
      if owner /= null then
        owner.dispatch_failed := True;
      end if;
      return;
    end if;

    if not begin_deferred (owner.all, E.Deliver_Parameter) then
      return;
    end if;

    owner.deferred_name_length := name'length;
    for index in 1 .. name'length loop
      owner.deferred_name(index) := name(name'first + index - 1);
    end loop;

    owner.deferred_value_length := value'length;
    for index in 1 .. value'length loop
      owner.deferred_value(index) := value(value'first + index - 1);
    end loop;

    submit_or_fail (owner.all);
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     response : in out Writer)
  is
    pragma Unreferenced (context, response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    if begin_deferred (owner.all, E.Finish_Params) then
      submit_or_fail (owner.all);
    end if;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     data     : in P.Byte_Array;
     response : in out Writer)
  is
    pragma Unreferenced (context, response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null or else data'length > owner.read_buffer_bytes then
      if owner /= null then
        owner.dispatch_failed := True;
      end if;
      return;
    end if;

    if not begin_deferred (owner.all, E.Deliver_Stdin) then
      return;
    end if;

    owner.deferred_data_length := data'length;
    for index in 1 .. data'length loop
      owner.deferred_data(index) := data(data'first + index - 1);
    end loop;

    submit_or_fail (owner.all);
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     response : in out Writer)
  is
    pragma Unreferenced (context, response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    if begin_deferred (owner.all, E.Finish_Stdin) then
      submit_or_fail (owner.all);
    end if;
  end on_stdin_end;

  overriding procedure on_data
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     data     : in P.Byte_Array;
     response : in out Writer)
  is
    pragma Unreferenced (context, response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null or else data'length > owner.read_buffer_bytes then
      if owner /= null then
        owner.dispatch_failed := True;
      end if;
      return;
    end if;

    if not begin_deferred (owner.all, E.Deliver_Data) then
      return;
    end if;

    owner.deferred_data_length := data'length;
    for index in 1 .. data'length loop
      owner.deferred_data(index) := data(data'first + index - 1);
    end loop;

    submit_or_fail (owner.all);
  end on_data;

  overriding procedure on_data_end
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     response : in out Writer)
  is
    pragma Unreferenced (context, response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    if begin_deferred (owner.all, E.Finish_Data) then
      submit_or_fail (owner.all);
    end if;
  end on_data_end;

  function try_submit_deferred
    (self : in out Context) return Clair.Status.Code
  is
    accepted     : Boolean;
    output_limit : Natural;
    slot_index   : Natural;
    request_role : P.Role;
    status       : Clair.Status.Code;
    timer_status : Clair.Status.Code;
  begin
    if not self.deferred_active then
      return Clair.Status.OK;
    end if;

    if self.executor = null or else not E.is_accepting(self.executor.all) then
      return Clair.Status.INVALID_STATE;
    end if;

    slot_index := find_slot (self, self.deferred_request);
    if slot_index = 0 then
      clear_deferred (self);
      self.application_paused := self.inflight_jobs /= 0;
      return Clair.Status.OK;
    end if;

    request_role := self.slots(slot_index).exchange.role_value;

    if request_role = P.Filter and then
       not self.slots(slot_index).exchange.stdin_closed
    then
      output_limit := 0;
    else
      output_limit := application_output_limit (self, self.deferred_request);

      if self.deferred_operation /= E.Deliver_Parameter and then
         output_limit = 0
      then
        if pending_output_bytes(self) > 0 then
          return Clair.Status.OK;
        end if;

        return Clair.Status.RANGE_ERROR;
      end if;
    end if;

    case self.deferred_operation is
      when E.Deliver_Parameter =>
        status := E.submit_parameter
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.handler,
           completion_handler => self'Unchecked_Access,
           name               =>
             self.deferred_name(1 .. self.deferred_name_length),
           value              =>
             self.deferred_value(1 .. self.deferred_value_length),
           output_limit       => output_limit,
           accepted           => accepted,
           role               => request_role);

      when E.Finish_Params =>
        status := E.submit_params_end
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.handler,
           completion_handler => self'Unchecked_Access,
           output_limit       => output_limit,
           accepted           => accepted,
           role               => request_role);

      when E.Deliver_Stdin =>
        status := E.submit_stdin
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.handler,
           completion_handler => self'Unchecked_Access,
           data               =>
             self.deferred_data(1 .. self.deferred_data_length),
           output_limit       => output_limit,
           accepted           => accepted,
           role               => request_role);

      when E.Finish_Stdin =>
        status := E.submit_stdin_end
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.handler,
           completion_handler => self'Unchecked_Access,
           output_limit       => output_limit,
           accepted           => accepted,
           role               => request_role);

      when E.Deliver_Data =>
        status := E.submit_data
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.handler,
           completion_handler => self'Unchecked_Access,
           data               =>
             self.deferred_data(1 .. self.deferred_data_length),
           output_limit       => output_limit,
           accepted           => accepted,
           role               => request_role);

      when E.Finish_Data =>
        status := E.submit_data_end
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.handler,
           completion_handler => self'Unchecked_Access,
           output_limit       => output_limit,
           accepted           => accepted,
           role               => request_role);
    end case;

    if status /= Clair.Status.OK then
      return status;
    end if;

    if accepted then
      clear_deferred (self);
      self.inflight_jobs := 1;
      timer_status := remove_retry_timer (self);
      return timer_status;
    end if;

    if not E.is_accepting(self.executor.all) then
      return Clair.Status.INVALID_STATE;
    end if;

    return ensure_retry_timer (self);
  end try_submit_deferred;

  function retire_completed_requests
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    for index in self.slots'range loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).exchange.complete_flag and then
         self.slots(index).response.length = 0
      then
        status := remove_request_timer (self, index);
        if status /= Clair.Status.OK then
          return status;
        end if;

        if not self.slots(index).exchange.keep_flag then
          self.close_requested := True;
        end if;

        if self.executor /= null then
          E.retire_deferred
            (self.executor.all, self.slots(index).identity_value);
        end if;

        if self.shared_admission /= null then
          A.release_request (self.shared_admission.all);
        end if;

        reset_slot (self.slots(index).all);
        self.active_requests := self.active_requests - 1;
      end if;
    end loop;

    return Clair.Status.OK;
  end retire_completed_requests;

  function settle_connection
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    status := retire_completed_requests (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    if self.close_requested and then
       self.active_requests = 0 and then
       pending_output_bytes (self) = 0 and then
       self.inflight_jobs = 0 and then
       not self.deferred_active
    then
      return close_owned (self);
    end if;

    return Clair.Status.OK;
  end settle_connection;

  function process_paused_probe
    (self : in out Context) return Clair.Status.Code;

  function paused_probe_can_read (self : Context) return Boolean;

  function refresh_watch (self : in out Context) return Clair.Status.Code is
    events : Clair.Event_Loop.Event_Mask := 0;
    status : Clair.Status.Code;
  begin
    if not self.initialized then
      return Clair.Status.OK;
    end if;

    status := settle_connection (self);
    if status /= Clair.Status.OK or else not self.initialized then
      return status;
    end if;

    update_backpressure (self);

    if self.application_paused then
      status := process_paused_probe (self);
      if status /= Clair.Status.OK or else not self.initialized then
        return status;
      end if;
    end if;

    if not self.shutdown_requested and then
       not self.read_paused and then
       (not self.close_requested or else self.active_requests > 0) and then
       (not self.application_paused or else paused_probe_can_read(self))
    then
      events := events or Clair.Event_Loop.EVENT_INPUT;
    end if;

    if direct_pending_output_bytes (self) > 0 then
      events := events or Clair.Event_Loop.EVENT_OUTPUT;
    end if;

    if events = 0 then
      if self.application_paused or else
         self.inflight_jobs /= 0 or else
         self.deferred_active or else
         pending_output_bytes(self) > 0
      then
        if self.watch_active then
          status := Clair.Event_Loop.remove
            (self.event_loop.all, self.watch);
          if status /= Clair.Status.OK then
            return status;
          end if;
          self.watch_active := False;
        end if;

        return Clair.Status.OK;
      end if;

      return close_owned (self);
    end if;

    if self.watch_active then
      return Clair.Event_Loop.modify_watch
        (self.event_loop.all, self.watch, events);
    end if;

    status := Clair.Event_Loop.add_watch
      (self    => self.event_loop.all,
       fd      => self.fd,
       events  => events,
       handler => self'Unchecked_Access,
       source  => self.watch);

    if status = Clair.Status.OK then
      self.watch_active := True;
    end if;

    return status;
  end refresh_watch;

  procedure compact_control
    (self  : in out Context;
     count : Natural)
  is
    remaining : Natural;
  begin
    if count >= self.control_length then
      self.control_length := 0;
      return;
    end if;

    remaining := self.control_length - count;
    for index in 1 .. remaining loop
      self.control_bytes(index) := self.control_bytes(index + count);
    end loop;
    self.control_length := remaining;
  end compact_control;

  procedure compact_slot_output
    (slot  : in out Request_Slot;
     count : Natural)
  is
    remaining : Natural;
  begin
    if count >= slot.response.length then
      slot.response.length := 0;
      return;
    end if;

    remaining := slot.response.length - count;
    for index in 1 .. remaining loop
      slot.response.bytes(index) := slot.response.bytes(index + count);
    end loop;
    slot.response.length := remaining;
  end compact_slot_output;

  function drain_output (self : in out Context) return Clair.Status.Code is
    type Consumption_Array is array (Natural range <>) of Natural;
    consumed : Consumption_Array (0 .. self.max_requests_per_connection) :=
      [others => 0];

    status : Clair.Status.Code;

    function source_length (source : Natural) return Natural is
    begin
      if source = 0 then
        return self.control_length - consumed(0);
      end if;

      if self.slots(source) = null or else not self.slots(source).in_use then
        return 0;
      end if;

      return self.slots(source).response.length - consumed(source);
    end source_length;

    function source_byte
      (source : Natural;
       index  : Positive) return P.Byte
    is
    begin
      if source = 0 then
        return self.control_bytes(consumed(0) + index);
      end if;

      return self.slots(source).response.bytes(consumed(source) + index);
    end source_byte;

    function choose_source return Integer is
      candidate : Positive;
    begin
      if self.output_source /= NO_OUTPUT_SOURCE then
        return self.output_source;
      end if;

      if source_length(0) > 0 then
        return CONTROL_OUTPUT_SOURCE;
      end if;

      for offset in 0 .. self.max_requests_per_connection - 1 loop
        candidate :=
          ((self.next_output_slot - 1 + offset) mod
             self.max_requests_per_connection) + 1;

        if source_length(candidate) > 0 then
          return Integer(candidate);
        end if;
      end loop;

      return NO_OUTPUT_SOURCE;
    end choose_source;

    function start_record (source : Natural) return Boolean is
      available      : constant Natural := source_length(source);
      content_length : Natural;
      record_length  : Natural;
    begin
      if available < P.HEADER_LENGTH then
        return False;
      end if;

      content_length :=
        Natural(source_byte(source, 5)) * 256 +
        Natural(source_byte(source, 6));
      record_length :=
        P.HEADER_LENGTH + content_length + Natural(source_byte(source, 7));

      if record_length > available then
        return False;
      end if;

      self.output_record_remaining := record_length;
      return True;
    end start_record;

    source    : Integer;
    source_id : Natural;
    available : Natural;
    count     : Natural;
  begin
    for attempt in 1 .. MAX_WRITES_PER_CALLBACK loop
      pragma Unreferenced (attempt);

      source := choose_source;
      exit when source = NO_OUTPUT_SOURCE;
      source_id := Natural(source);

      if self.output_source = NO_OUTPUT_SOURCE then
        self.output_source := source;
        if not start_record (source_id) then
          return close_owned (self);
        end if;
      end if;

      available := source_length(source_id);
      if available = 0 or else self.output_record_remaining = 0 then
        return close_owned (self);
      end if;

      count := Natural'Min (available, self.write_chunk_bytes);
      count := Natural'Min (count, self.output_record_remaining);

      declare
        buffer : System.Storage_Elements.Storage_Array
          (1 .. System.Storage_Elements.Storage_Offset(count));
        sent : System.Storage_Elements.Storage_Count;
      begin
        for index in 1 .. count loop
          buffer(System.Storage_Elements.Storage_Offset(index)) :=
            System.Storage_Elements.Storage_Element
              (source_byte(source_id, index));
        end loop;

        status := Clair.Network.send
          (fd     => self.fd,
           buffer => buffer,
           sent   => sent);

        if status = Clair.Status.OK then
          if sent = 0 then
            return close_owned (self);
          end if;

          consumed(source_id) := consumed(source_id) + Natural(sent);
          self.output_record_remaining :=
            self.output_record_remaining - Natural(sent);

          if self.output_record_remaining = 0 then
            if source_id > 0 then
              self.next_output_slot :=
                (source_id mod self.max_requests_per_connection) + 1;
            end if;

            self.output_source := NO_OUTPUT_SOURCE;
          end if;
        elsif Clair.IO.Posix.is_would_block (status) then
          exit;
        else
          return close_owned (self);
        end if;
      end;
    end loop;

    if consumed(0) > 0 then
      compact_control (self, consumed(0));
    end if;

    for index in self.slots'range loop
      if consumed(index) > 0 and then self.slots(index) /= null then
        compact_slot_output (self.slots(index).all, consumed(index));
      end if;
    end loop;

    update_backpressure (self);

    if self.deferred_active and then
       not self.read_paused and then
       application_output_limit(self, self.deferred_request) > 0
    then
      status := try_submit_deferred (self);
      if status /= Clair.Status.OK then
        return status;
      end if;
    end if;

    return settle_connection (self);
  end drain_output;

  function reject_protocol (self : in out Context) return Clair.Status.Code is
  begin
    if self.diagnostics /= null then
      D.report
        (self.diagnostics.all,
         D.Protocol_Error,
         Clair.Status.INVALID_ARGUMENT,
         "FastCGI protocol error; connection closed");
    end if;

    return close_owned (self);
  end reject_protocol;

  function flush_stream_batch
    (self : in out Context) return Clair.Status.Code
  is
    request_status : Input_Status;
  begin
    if self.stream_batch_length = 0 then
      return Clair.Status.OK;
    end if;

    if self.current_slot = 0 or else
       self.slots(self.current_slot) = null or else
       not self.slots(self.current_slot).in_use
    then
      return Clair.Status.INVALID_STATE;
    end if;

    prepare_writer_budget (self, self.slots(self.current_slot).all);
    feed_content
      (self     => self.slots(self.current_slot).exchange,
       data     => self.stream_batch(1 .. self.stream_batch_length),
       handler  => self.dispatcher,
       response => self.slots(self.current_slot).response,
       status   => request_status);

    if request_status /= Input_Progress then
      return Clair.Status.INVALID_STATE;
    end if;

    self.stream_batch_length := 0;

    if self.dispatch_failed then
      return Clair.Status.CALLBACK_FAILED;
    end if;

    return Clair.Status.OK;
  end flush_stream_batch;

  function process_byte
    (self  : in out Context;
     value : P.Byte) return Clair.Status.Code
  is
    event          : C.Record_Event;
    record_header  : P.Header;
    decode_status  : C.Decode_Status;
    request_status    : Input_Status;
    management_status : PM.Query_Status;
    request_admitted  : Boolean;
    slot_index        : Natural;
    one_byte          : P.Byte_Array (1 .. 1);
    status            : Clair.Status.Code;
  begin
    C.feed
      (self          => self.decoder,
       value         => value,
       event         => event,
       record_header => record_header,
       status        => decode_status);

    if event = C.Decode_Error or else
       (decode_status /= C.Complete and then decode_status /= C.Need_More_Data)
    then
      return reject_protocol (self);
    end if;

    case event is
      when C.Header_Progress =>
        null;

      when C.Header_Ready =>
        if self.stream_batch_length /= 0 then
          return reject_protocol (self);
        end if;

        self.skip_record := False;
        self.current_slot := 0;
        self.management_active := False;

        if record_header.request_id = 0 then
          if record_header.record_type = P.GET_VALUES_TYPE then
            PM.reset (self.management_query);
            self.management_active := True;
            self.management_record_type := record_header.record_type;
          elsif not P.is_known_record_type(record_header.record_type) then
            self.management_active := True;
            self.management_record_type := record_header.record_type;
          else
            return reject_protocol (self);
          end if;

        elsif P.is_management_record(record_header.record_type) or else
              not P.is_known_record_type(record_header.record_type)
        then
          return reject_protocol (self);

        elsif record_header.record_type = P.BEGIN_REQUEST_TYPE then
          if Natural(record_header.content_length) /=
               M.BEGIN_REQUEST_BODY_LENGTH
          then
            return reject_protocol (self);
          end if;

          if find_slot(self, record_header.request_id) /= 0 then
            return reject_protocol (self);
          end if;

          if self.close_requested or else
             self.active_requests >= self.max_requests_per_connection
          then
            if not queue_cant_mpx (self, record_header.request_id) then
              return reject_protocol (self);
            end if;

            self.skip_record := True;
          else
            request_admitted := True;
            if self.shared_admission /= null then
              A.try_acquire_request
                (self.shared_admission.all, request_admitted);
            end if;

            if not request_admitted then
              if not queue_overloaded (self, record_header.request_id) then
                return reject_protocol (self);
              end if;
              self.skip_record := True;
            else
              slot_index := allocate_slot (self, record_header.request_id);
              if slot_index = 0 then
                if self.shared_admission /= null then
                  A.release_request (self.shared_admission.all);
                end if;
                return reject_protocol (self);
              end if;

              self.current_slot := slot_index;
              prepare_writer_budget (self, self.slots(slot_index).all);
              begin_record
                (self          => self.slots(slot_index).exchange,
                 record_header => record_header,
                 response      => self.slots(slot_index).response,
                 status        => request_status,
                 connection_id => self.connection_id,
                 generation    =>
                   self.slots(slot_index).identity_value.generation);

              if request_status /= Input_Progress then
                return reject_protocol (self);
              end if;

              status := arm_request_timer (self, slot_index);
              if status /= Clair.Status.OK then
                declare
                  failure_status : constant Clair.Status.Code := status;
                  cleanup_status : constant Clair.Status.Code :=
                    close_owned (self);
                begin
                  if cleanup_status /= Clair.Status.OK then
                    return cleanup_status;
                  end if;
                  return failure_status;
                end;
              end if;
            end if;
          end if;
        else
          slot_index := find_slot (self, record_header.request_id);

          if slot_index = 0 then
            self.skip_record := True;
          else
            self.current_slot := slot_index;
            prepare_writer_budget (self, self.slots(slot_index).all);
            begin_record
              (self          => self.slots(slot_index).exchange,
               record_header => record_header,
               response      => self.slots(slot_index).response,
               status        => request_status);

            case request_status is
              when Input_Progress =>
                if not account_input_record
                  (self, self.slots(slot_index).all,
                   record_header.record_type,
                   Natural(record_header.content_length))
                then
                  status := mark_resource_limit (self, slot_index);
                  if status /= Clair.Status.OK then
                    return status;
                  end if;
                end if;
              when Ignored_Inactive =>
                self.skip_record := True;
                self.current_slot := 0;
              when others =>
                return reject_protocol (self);
            end case;
          end if;
        end if;

      when C.Content_Byte =>
        if self.management_active then
          if self.management_record_type = P.GET_VALUES_TYPE then
            PM.feed (self.management_query, value, management_status);
            if management_status = PM.Query_Limit_Exceeded or else
               management_status = PM.Query_Invalid
            then
              return reject_protocol (self);
            end if;
          end if;

        elsif not self.skip_record then
          if self.current_slot = 0 or else
             self.slots(self.current_slot) = null or else
             not self.slots(self.current_slot).in_use
          then
            return reject_protocol (self);
          end if;

          if self.slots(self.current_slot).exchange.current_record_type =
               P.STDIN_TYPE or else
             self.slots(self.current_slot).exchange.current_record_type =
               P.DATA_TYPE
          then
            self.stream_batch_length := self.stream_batch_length + 1;
            self.stream_batch(self.stream_batch_length) := value;

            if self.stream_batch_length = self.read_buffer_bytes then
              status := flush_stream_batch (self);
              if status /= Clair.Status.OK then
                return reject_protocol (self);
              end if;
            end if;
          else
            one_byte(1) := value;
            prepare_writer_budget (self, self.slots(self.current_slot).all);
            feed_content
              (self     => self.slots(self.current_slot).exchange,
               data     => one_byte,
               handler  => self.dispatcher,
               response => self.slots(self.current_slot).response,
               status   => request_status);

            if request_status /= Input_Progress or else
               self.dispatch_failed
            then
              return reject_protocol (self);
            end if;
          end if;
        end if;

      when C.Padding_Byte =>
        if not self.skip_record and then self.stream_batch_length > 0 then
          status := flush_stream_batch (self);
          if status /= Clair.Status.OK then
            return reject_protocol (self);
          end if;
        end if;

      when C.Decode_Error =>
        return reject_protocol (self);
    end case;

    if C.record_complete (self.decoder) then
      if self.management_active then
        if self.management_record_type = P.GET_VALUES_TYPE then
          if not PM.at_pair_boundary(self.management_query) or else
             not queue_get_values_result(self)
          then
            return reject_protocol (self);
          end if;
        elsif not queue_unknown_type
          (self, self.management_record_type)
        then
          return reject_protocol (self);
        end if;

        reset_management (self);

      elsif self.skip_record and then
            self.current_slot /= 0 and then
            self.slots(self.current_slot) /= null and then
            self.slots(self.current_slot).in_use and then
            self.slots(self.current_slot).exchange.cancel_reason =
              Resource_Limit
      then
        status := complete_resource_limit (self, self.current_slot);
        if status /= Clair.Status.OK then
          return status;
        end if;

      elsif not self.skip_record then
        if self.current_slot = 0 or else
           self.slots(self.current_slot) = null or else
           not self.slots(self.current_slot).in_use
        then
          return reject_protocol (self);
        end if;

        if self.stream_batch_length > 0 then
          status := flush_stream_batch (self);
          if status /= Clair.Status.OK then
            return reject_protocol (self);
          end if;
        end if;

        if self.slots(self.current_slot).exchange.current_record_type =
             P.ABORT_REQUEST_TYPE
        then
          status := E.signal_cancellation
            (self.executor.all,
             self.slots(self.current_slot).identity_value,
             Peer_Abort);
          if status /= Clair.Status.OK then
            return status;
          end if;
        end if;

        prepare_writer_budget (self, self.slots(self.current_slot).all);
        end_record
          (self     => self.slots(self.current_slot).exchange,
           handler  => self.dispatcher,
           response => self.slots(self.current_slot).response,
           status   => request_status);

        if request_status /= Record_Complete and then
           request_status /= Request_Complete
        then
          return reject_protocol (self);
        end if;

        if self.dispatch_failed then
          return reject_protocol (self);
        end if;

        if request_status = Request_Complete and then
           not self.slots(self.current_slot).exchange.keep_flag
        then
          self.close_requested := True;
        end if;
      end if;

      self.skip_record := False;
      self.current_slot := 0;
    end if;

    update_backpressure (self);
    return Clair.Status.OK;
  end process_byte;

  function process_pending_input
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    while self.input_length > 0 and then
          not self.read_paused and then
          not self.application_paused
    loop
      status := process_byte (self, self.input_bytes(self.input_first));
      if status /= Clair.Status.OK or else not self.initialized then
        return status;
      end if;

      self.input_length := self.input_length - 1;
      if self.input_length = 0 then
        self.input_first := 1;
      else
        self.input_first := self.input_first + 1;
      end if;
    end loop;

    return Clair.Status.OK;
  end process_pending_input;

  procedure reset_paused_probe (self : in out Context) is
  begin
    self.paused_probe_length := 0;
    self.paused_probe_target := P.HEADER_LENGTH;
    self.paused_probe_is_abort := False;
  end reset_paused_probe;

  procedure consume_pending_input
    (self  : in out Context;
     count : Natural)
  is
  begin
    if count >= self.input_length then
      self.input_first := 1;
      self.input_length := 0;
    else
      self.input_first := self.input_first + count;
      self.input_length := self.input_length - count;
    end if;
  end consume_pending_input;

  function analyze_paused_probe
    (self : in out Context) return Clair.Status.Code
  is
    header_bytes  : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    record_header : P.Header;
    decode_status : C.Decode_Status;
  begin
    if self.paused_probe_length < P.HEADER_LENGTH then
      return Clair.Status.OK;
    end if;

    for index in 0 .. P.HEADER_LENGTH - 1 loop
      header_bytes(index) := self.paused_probe_bytes(index + 1);
    end loop;

    C.decode_header (header_bytes, record_header, decode_status);
    if decode_status /= C.Complete then
      return reject_protocol (self);
    end if;

    if record_header.record_type /= P.ABORT_REQUEST_TYPE then
      self.paused_probe_target := P.HEADER_LENGTH;
      self.paused_probe_is_abort := False;
      return Clair.Status.OK;
    end if;

    if Natural(record_header.content_length) /= 0 then
      return reject_protocol (self);
    end if;

    self.paused_probe_target :=
      P.HEADER_LENGTH + Natural(record_header.padding_length);
    self.paused_probe_is_abort := True;
    return Clair.Status.OK;
  end analyze_paused_probe;

  function replay_paused_probe
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
    length : constant Natural := self.paused_probe_length;
  begin
    for index in 1 .. length loop
      status := process_byte (self, self.paused_probe_bytes(index));
      if status /= Clair.Status.OK or else not self.initialized then
        return status;
      end if;
    end loop;

    reset_paused_probe (self);
    return Clair.Status.OK;
  end replay_paused_probe;

  function process_paused_probe
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not self.application_paused or else self.current_slot /= 0 then
      return Clair.Status.OK;
    end if;

    while self.input_length > 0 and then
          self.paused_probe_length < self.paused_probe_target
    loop
      self.paused_probe_length := self.paused_probe_length + 1;
      self.paused_probe_bytes(self.paused_probe_length) :=
        self.input_bytes(self.input_first);
      consume_pending_input (self, 1);

      if self.paused_probe_length = P.HEADER_LENGTH then
        status := analyze_paused_probe (self);
        if status /= Clair.Status.OK or else not self.initialized then
          return status;
        end if;

        exit when not self.paused_probe_is_abort;
      end if;
    end loop;

    if self.paused_probe_is_abort and then
       self.paused_probe_length = self.paused_probe_target
    then
      return replay_paused_probe (self);
    end if;

    return Clair.Status.OK;
  end process_paused_probe;

  function paused_probe_can_read (self : Context) return Boolean is
  begin
    return self.application_paused and then
      self.current_slot = 0 and then
      (self.paused_probe_length < P.HEADER_LENGTH or else
       (self.paused_probe_is_abort and then
        self.paused_probe_length < self.paused_probe_target));
  end paused_probe_can_read;

  function read_paused_probe
    (self : in out Context) return Clair.Status.Code
  is
    status     : Clair.Status.Code;
    read_count : Clair.IO.Byte_Count;
    remaining  : Natural;
  begin
    status := process_paused_probe (self);
    if status /= Clair.Status.OK or else not self.initialized then
      return status;
    end if;

    for attempt in 1 .. MAX_READS_PER_CALLBACK loop
      pragma Unreferenced (attempt);
      exit when not paused_probe_can_read(self);

      remaining := self.paused_probe_target - self.paused_probe_length;
      declare
        buffer : System.Storage_Elements.Storage_Array
          (1 .. System.Storage_Elements.Storage_Offset(remaining));
      begin
        status := Clair.IO.read (self.fd, buffer, read_count);

        if status = Clair.Status.OK then
          if read_count = 0 then
            return close_owned (self);
          end if;

          for index in 1 .. Natural(read_count) loop
            self.paused_probe_length := self.paused_probe_length + 1;
            self.paused_probe_bytes(self.paused_probe_length) :=
              P.Byte
                (buffer
                   (buffer'first +
                    System.Storage_Elements.Storage_Offset(index - 1)));
          end loop;

          if self.paused_probe_length >= P.HEADER_LENGTH and then
             self.paused_probe_target = P.HEADER_LENGTH
          then
            status := analyze_paused_probe (self);
            if status /= Clair.Status.OK or else not self.initialized then
              return status;
            end if;
          end if;

          if self.paused_probe_is_abort and then
             self.paused_probe_length = self.paused_probe_target
          then
            status := replay_paused_probe (self);
            if status /= Clair.Status.OK or else not self.initialized then
              return status;
            end if;

            status := process_paused_probe (self);
            if status /= Clair.Status.OK or else not self.initialized then
              return status;
            end if;
          end if;
        elsif Clair.IO.Posix.is_would_block (status) then
          exit;
        else
          return close_owned (self);
        end if;
      end;
    end loop;

    return Clair.Status.OK;
  end read_paused_probe;

  procedure store_input
    (self   : in out Context;
     source : in System.Storage_Elements.Storage_Array;
     count  : Natural)
  is
  begin
    self.input_first := 1;
    self.input_length := count;

    for index in 1 .. count loop
      self.input_bytes(index) :=
        P.Byte
          (source
             (source'first +
              System.Storage_Elements.Storage_Offset(index - 1)));
    end loop;
  end store_input;

  function read_input (self : in out Context) return Clair.Status.Code is
    buffer : System.Storage_Elements.Storage_Array
      (1 .. System.Storage_Elements.Storage_Offset(self.read_buffer_bytes));
    read_count : Clair.IO.Byte_Count;
    status     : Clair.Status.Code;
  begin
    status := process_pending_input (self);
    if status /= Clair.Status.OK or else
       not self.initialized or else
       self.read_paused or else
       self.application_paused
    then
      return status;
    end if;

    for attempt in 1 .. MAX_READS_PER_CALLBACK loop
      pragma Unreferenced (attempt);
      status := Clair.IO.read (self.fd, buffer, read_count);

      if status = Clair.Status.OK then
        if read_count = 0 then
          return close_owned (self);
        end if;

        store_input (self, buffer, Natural(read_count));
        status := process_pending_input (self);

        if status /= Clair.Status.OK or else
           not self.initialized or else
           self.read_paused or else
           self.application_paused
        then
          return status;
        end if;
      elsif Clair.IO.Posix.is_would_block (status) then
        exit;
      else
        return close_owned (self);
      end if;
    end loop;

    return Clair.Status.OK;
  end read_input;

  function initialize
    (self            : in out Context;
     event_loop      : Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     handler         : Application_Access;
     executor        : E.Context_Access;
     request_timeout : Clair.Event_Loop.Milliseconds;
     connection_id   : Connection_Identity;
     admission       : A.Context_Access := null;
     diagnostics     : Fasyn.Diagnostics.Reporter_Access := null;
     input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS)
  return Clair.Status.Code
  is
    status              : Clair.Status.Code;
    connection_accepted : Boolean := True;
  begin
    if self.initialized or else self.inflight_jobs /= 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    if event_loop = null or else
       handler = null or else
       executor = null or else
       request_timeout <= 0 or else
       connection_id = NO_CONNECTION_IDENTITY
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if not E.is_accepting(executor.all) then
      return Clair.Status.INVALID_STATE;
    end if;

    if fd = Clair.IO.INVALID_DESCRIPTOR then
      return Clair.Status.INVALID_HANDLE;
    end if;

    if self.max_request_output_bytes > self.max_output_bytes then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if admission /= null then
      A.try_acquire_connection (admission.all, connection_accepted);
      if not connection_accepted then
        return Clair.Status.RANGE_ERROR;
      end if;
      self.shared_admission := admission;
      self.admission_connection_owned := True;
    end if;

    begin
      for index in self.slots'range loop
        self.slots(index) := new Request_Slot
          (max_name_bytes           => self.max_name_bytes,
           max_value_bytes          => self.max_value_bytes,
           max_request_output_bytes => self.max_request_output_bytes);
        reset_slot (self.slots(index).all);
      end loop;
    exception
      when Storage_Error =>
        release_admission (self);
        release_slots (self);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    self.event_loop := event_loop;
    self.fd := fd;
    self.handler := handler;
    self.executor := executor;
    self.diagnostics := diagnostics;
    self.request_timeout := request_timeout;
    self.input_limits := input_limits;
    self.dispatcher.owner := self'Unchecked_Access;
    self.connection_id := connection_id;
    self.active_requests := 0;
    self.next_generation := 1;
    self.current_slot := 0;
    self.next_output_slot := 1;
    self.output_source := NO_OUTPUT_SOURCE;
    self.output_record_remaining := 0;
    self.control_length := 0;
    self.input_first := 1;
    self.input_length := 0;
    reset_paused_probe (self);
    self.stream_batch_length := 0;
    reset_management (self);
    self.inflight_jobs := 0;
    self.read_paused := False;
    self.application_paused := False;
    self.deferred_active := False;
    self.retry_timer_active := False;
    self.dispatch_failed := False;
    self.skip_record := False;
    self.close_requested := False;
    self.shutdown_requested := False;
    clear_deferred (self);
    C.reset (self.decoder);

    status := Clair.Event_Loop.add_watch
      (self    => event_loop.all,
       fd      => fd,
       events  => Clair.Event_Loop.EVENT_INPUT,
       handler => self'Unchecked_Access,
       source  => self.watch);

    if status /= Clair.Status.OK then
      release_admission (self);
      release_slots (self);
      self.event_loop := null;
      self.fd := Clair.IO.INVALID_DESCRIPTOR;
      self.handler := null;
      self.executor := null;
      self.diagnostics := null;
      self.dispatcher.owner := null;
      self.connection_id := NO_CONNECTION_IDENTITY;
      return status;
    end if;

    self.watch_active := True;
    self.initialized := True;
    return Clair.Status.OK;
  end initialize;

  function begin_shutdown
    (self : in out Context) return Clair.Status.Code
  is
    status         : Clair.Status.Code;
    request_status : Input_Status;

    procedure publish_if_active is
    begin
      if self.initialized then
        publish_deferred_state (self, self.inflight_jobs /= 0);
      end if;
    end publish_if_active;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.shutdown_requested then
      return Clair.Status.OK;
    end if;

    mark_deferred_busy (self);

    self.shutdown_requested := True;
    self.close_requested := True;
    self.input_first := 1;
    self.input_length := 0;
    reset_paused_probe (self);
    self.stream_batch_length := 0;
    reset_management (self);
    self.current_slot := 0;
    self.skip_record := False;
    C.reset (self.decoder);

    status := remove_retry_timer (self);
    if status /= Clair.Status.OK then
      publish_if_active;
      return status;
    end if;

    clear_deferred (self);
    self.application_paused := self.inflight_jobs /= 0;

    for index in self.slots'range loop
      if self.slots(index) /= null and then self.slots(index).in_use then
        status := E.signal_cancellation
          (self.executor.all,
           self.slots(index).identity_value,
           Runtime_Shutdown);
        if status /= Clair.Status.OK then
          return status;
        end if;

        status := remove_request_timer (self, index);
        if status /= Clair.Status.OK then
          return status;
        end if;

        prepare_writer_budget (self, self.slots(index).all);
        cancel
          (self     => self.slots(index).exchange,
           response => self.slots(index).response,
           cause    => Runtime_Shutdown,
           status   => request_status);

        if request_status /= Request_Complete and then
           request_status /= Ignored_Inactive
        then
          return close_owned (self);
        end if;
      end if;
    end loop;

    update_backpressure (self);
    status := refresh_watch (self);
    publish_if_active;
    return status;
  end begin_shutdown;

  function finalize (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if self.initialized then
      status := close_owned (self);
      if status /= Clair.Status.OK then
        return status;
      end if;
    else
      release_slots (self);
    end if;

    if self.inflight_jobs /= 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    self.application_paused := False;
    self.event_loop := null;
    self.handler := null;
    self.executor := null;
    self.diagnostics := null;
    self.dispatcher.owner := null;
    return Clair.Status.OK;
  end finalize;

  function is_active (self : Context) return Boolean is
  begin
    return self.initialized;
  end is_active;

  function is_read_paused (self : Context) return Boolean is
  begin
    return self.shutdown_requested or else
      self.read_paused or else self.application_paused;
  end is_read_paused;

  function active_request_count (self : Context) return Natural is
  begin
    return self.active_requests;
  end active_request_count;

  function pending_input_bytes (self : Context) return Natural is
  begin
    return self.input_length + self.paused_probe_length;
  end pending_input_bytes;

  function request_is_current
    (self    : Context;
     request : Request_Identity) return Boolean
  is
  begin
    return find_slot (self, request) /= 0;
  end request_is_current;

  overriding function on_io
    (self   : in out Context;
     io     : Clair.Event_Loop.Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code
  is
    pragma Unreferenced (io);

    status : Clair.Status.Code;

    procedure publish_if_active is
    begin
      if self.initialized then
        publish_deferred_state (self, self.inflight_jobs /= 0);
      end if;
    end publish_if_active;
  begin
    if not self.initialized or else fd /= self.fd then
      return Clair.Status.INVALID_STATE;
    end if;

    mark_deferred_busy (self);

    if not self.shutdown_requested and then
       (has_event (events, Clair.Event_Loop.EVENT_INPUT) or else
        has_event (events, Clair.Event_Loop.EVENT_HANG_UP) or else
        has_event (events, Clair.Event_Loop.EVENT_ERROR))
    then
      if self.application_paused then
        status := read_paused_probe (self);
      else
        status := read_input (self);
      end if;

      if status /= Clair.Status.OK or else not self.initialized then
        publish_if_active;
        return status;
      end if;
    end if;

    if direct_pending_output_bytes(self) > 0 and then
       has_event (events, Clair.Event_Loop.EVENT_OUTPUT)
    then
      status := drain_output (self);
      if status /= Clair.Status.OK or else not self.initialized then
        publish_if_active;
        return status;
      end if;
    end if;

    status := settle_connection (self);
    if status /= Clair.Status.OK or else not self.initialized then
      publish_if_active;
      return status;
    end if;

    update_backpressure (self);

    if not self.shutdown_requested and then
       not self.read_paused and then
       not self.application_paused and then
       self.paused_probe_length > 0
    then
      status := replay_paused_probe (self);
      if status /= Clair.Status.OK or else not self.initialized then
        publish_if_active;
        return status;
      end if;

      status := settle_connection (self);
      if status /= Clair.Status.OK or else not self.initialized then
        publish_if_active;
        return status;
      end if;
    end if;

    if not self.shutdown_requested and then
       not self.read_paused and then
       not self.application_paused and then
       self.input_length > 0
    then
      status := process_pending_input (self);
      if status /= Clair.Status.OK or else not self.initialized then
        publish_if_active;
        return status;
      end if;

      status := settle_connection (self);
      if status /= Clair.Status.OK or else not self.initialized then
        publish_if_active;
        return status;
      end if;
    end if;

    status := refresh_watch (self);
    publish_if_active;
    return status;
  end on_io;

  overriding function on_timer
    (self  : in out Context;
     timer : Clair.Event_Loop.Handle) return Clair.Status.Code
  is
    status         : Clair.Status.Code;
    request_status : Input_Status;
    slot_index     : Natural;
    request        : Request_Identity;

    procedure publish_if_active is
    begin
      if self.initialized then
        publish_deferred_state (self, self.inflight_jobs /= 0);
      end if;
    end publish_if_active;
  begin
    if self.initialized then
      mark_deferred_busy (self);
    end if;

    if self.retry_timer_active and then timer = self.retry_timer then
      status := remove_retry_timer (self);
      if status /= Clair.Status.OK then
        publish_if_active;
        return status;
      end if;

      if not self.initialized then
        return Clair.Status.OK;
      end if;

      status := try_submit_deferred (self);
      if status /= Clair.Status.OK then
        return close_owned (self);
      end if;

      status := refresh_watch (self);
      publish_if_active;
      return status;
    end if;

    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    slot_index := find_timer_slot (self, timer);
    if slot_index = 0 or else
       self.slots(slot_index) = null or else
       not self.slots(slot_index).in_use
    then
      return Clair.Status.INVALID_STATE;
    end if;

    request := self.slots(slot_index).identity_value;
    status := remove_request_timer (self, slot_index);
    if status /= Clair.Status.OK then
      publish_if_active;
      return status;
    end if;

    status := clear_deferred_for (self, request);
    if status /= Clair.Status.OK then
      publish_if_active;
      return status;
    end if;

    -- A resource-limited request may still be discarding its rejected record,
    -- and a completed request may still own undrained output. At the request
    -- deadline neither state may retain the transport indefinitely.
    if self.slots(slot_index).exchange.cancel_reason = Resource_Limit or else
       self.slots(slot_index).exchange.complete_flag
    then
      return close_owned (self);
    end if;

    if self.current_slot = slot_index then
      self.current_slot := 0;
      self.stream_batch_length := 0;
      self.skip_record := True;
    end if;

    status := E.signal_cancellation
      (self.executor.all, request, Request_Timeout);
    if status /= Clair.Status.OK then
      publish_if_active;
      return status;
    end if;

    prepare_writer_budget (self, self.slots(slot_index).all);
    cancel
      (self     => self.slots(slot_index).exchange,
       response => self.slots(slot_index).response,
       cause    => Request_Timeout,
       status   => request_status);

    if request_status /= Request_Complete and then
       request_status /= Ignored_Inactive
    then
      return close_owned (self);
    end if;

    if request_status = Request_Complete and then
       not self.slots(slot_index).exchange.keep_flag
    then
      self.close_requested := True;
    end if;

    update_backpressure (self);
    status := refresh_watch (self);
    publish_if_active;
    return status;
  end on_timer;

  overriding function on_completion
    (self            : in out Context;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
    request      : constant Request_Identity := E.completion_request (item);
    slot_index   : Natural;
    output_count : constant Natural := E.output_length (item);
    completion_write_status : Write_Status;
    status       : Clair.Status.Code;

    procedure append_output (slot : Positive) is
    begin
      if self.slots(slot).response.length >
           self.slots(slot).response.max_output_bytes or else
         output_count >
           self.slots(slot).response.max_output_bytes -
             self.slots(slot).response.length or else
         pending_output_bytes(self) > self.max_output_bytes or else
         output_count > self.max_output_bytes - pending_output_bytes(self)
      then
        raise Program_Error with "execution output reservation violated";
      end if;

      for index in 1 .. output_count loop
        self.slots(slot).response.length :=
          self.slots(slot).response.length + 1;
        self.slots(slot).response.bytes
          (self.slots(slot).response.length) := E.output_byte (item, index);
      end loop;
    end append_output;

    procedure apply_deferred_output (slot : Positive) is
      kind   : constant E.Deferred_Output_Kind := E.deferred_kind(item);
      total  : constant Natural := E.deferred_data_length(item);
      offset : Natural := 0;
      count  : Natural;
      copied : Natural;
    begin
      prepare_writer_budget (self, self.slots(slot).all);

      if kind = E.Deferred_Finish_Output then
        finish
          (self.slots(slot).response, E.deferred_application_status(item),
           completion_write_status);
        if completion_write_status /= Write_Complete then
          raise Program_Error with "deferred completion reservation violated";
        end if;
        return;
      end if;

      while offset < total loop
        count := Natural'Min (E.DEFERRED_OUTPUT_CHUNK_BYTES, total - offset);
        declare
          buffer : P.Byte_Array (1 .. count);
        begin
          E.copy_deferred_data (item, offset, buffer, copied);
          if copied /= count then
            raise Program_Error with "deferred payload copy invariant violated";
          end if;

          if kind = E.Deferred_Stdout_Output then
            write_stdout
              (self.slots(slot).response, buffer, completion_write_status);
          else
            write_stderr
              (self.slots(slot).response, buffer, completion_write_status);
          end if;

          if completion_write_status /= Write_Complete then
            raise Program_Error with "deferred output reservation violated";
          end if;
        end;
        offset := offset + count;
      end loop;
    end apply_deferred_output;
  begin
    if E.is_deferred_output(item) then
      if callback_status /= Clair.Status.OK then
        return Clair.Status.CALLBACK_FAILED;
      end if;

      if not self.initialized then
        return Clair.Status.OK;
      end if;

      slot_index := find_slot (self, request);
      if slot_index = 0 or else
         not self.slots(slot_index).application_deferred or else
         self.slots(slot_index).exchange.cancel_reason /= Not_Cancelled or else
         self.slots(slot_index).exchange.complete_flag
      then
        return Clair.Status.OK;
      end if;

      apply_deferred_output (Positive(slot_index));

      if E.deferred_kind(item) = E.Deferred_Finish_Output then
        self.slots(slot_index).exchange.active := False;
        self.slots(slot_index).exchange.complete_flag := True;
        E.retire_deferred (self.executor.all, request);
      end if;

      if self.slots(slot_index).exchange.complete_flag and then
         not self.slots(slot_index).exchange.keep_flag
      then
        self.close_requested := True;
      end if;

      update_backpressure (self);
      publish_deferred_state (self, True);
      return refresh_watch (self);
    end if;

    if self.inflight_jobs /= 1 then
      raise Program_Error with "unexpected execution completion";
    end if;

    mark_deferred_busy (self);
    self.inflight_jobs := 0;

    if not self.initialized then
      self.application_paused := False;
      return Clair.Status.OK;
    end if;

    slot_index := find_slot (self, request);

    if slot_index /= 0 and then
       self.slots(slot_index).exchange.cancel_reason = Not_Cancelled and then
       not self.slots(slot_index).exchange.complete_flag
    then
      if callback_status /= Clair.Status.OK or else E.output_failed(item) then
        E.retire_deferred (self.executor.all, request);
        self.slots(slot_index).response.deferred := False;
        prepare_writer_budget (self, self.slots(slot_index).all);
        finish (self.slots(slot_index).response, 1, completion_write_status);

        if completion_write_status /= Write_Complete then
          return close_owned (self);
        end if;

        self.slots(slot_index).exchange.active := False;
        self.slots(slot_index).exchange.complete_flag := True;
      else
        append_output (Positive(slot_index));

        if E.output_finished(item) then
          self.slots(slot_index).response.finished := True;
          self.slots(slot_index).exchange.active := False;
          self.slots(slot_index).exchange.complete_flag := True;
          E.retire_deferred (self.executor.all, request);
        elsif E.deferred_requested(self.executor.all, request) then
          status := E.activate_deferred
            (self               => self.executor.all,
             request            => request,
             request_pending    => self.slots(slot_index).response.length,
             request_limit      =>
               self.slots(slot_index).response.max_output_bytes,
             connection_pending => direct_pending_output_bytes(self),
             connection_limit   => self.max_output_bytes);
          if status /= Clair.Status.OK then
            return close_owned (self);
          end if;
          self.slots(slot_index).application_deferred := True;
        end if;
      end if;

      if self.slots(slot_index).exchange.complete_flag and then
         not self.slots(slot_index).exchange.keep_flag
      then
        self.close_requested := True;
      end if;
    else
      E.retire_deferred (self.executor.all, request);
    end if;

    self.application_paused := False;
    update_backpressure (self);

    if not self.read_paused and then self.paused_probe_length > 0 then
      status := replay_paused_probe (self);
      if status /= Clair.Status.OK or else not self.initialized then
        if self.initialized then
          publish_deferred_state (self, self.inflight_jobs /= 0);
        end if;
        return status;
      end if;
    end if;

    if not self.read_paused and then self.input_length > 0 then
      status := process_pending_input (self);
      if status /= Clair.Status.OK or else not self.initialized then
        if self.initialized then
          publish_deferred_state (self, self.inflight_jobs /= 0);
        end if;
        return status;
      end if;
    end if;

    if self.initialized then
      publish_deferred_state (self, self.inflight_jobs /= 0);
      return refresh_watch (self);
    end if;

    return Clair.Status.OK;
  end on_completion;


end Fasyn.Request.Connection;
