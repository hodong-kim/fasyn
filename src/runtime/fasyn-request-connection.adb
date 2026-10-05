-- ============================================================================
-- fasyn-request-connection.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Unchecked_Deallocation;
with Ada.Unchecked_Conversion;
with Interfaces;
with Clair.IO.Posix;
with Clair.Unix.Network;
with Fasyn.Protocol;
with Fasyn.Protocol.Bodies;
with Fasyn.Protocol.Name_Values;
with System;

package body Fasyn.Request.Connection is

  package D renames Fasyn.Diagnostics;
  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package B renames Fasyn.Protocol.Bodies;
  package N renames Fasyn.Protocol.Name_Values;

  use type Clair.Event_Loop.Context_Access;
  use type Clair.Event_Loop.Event_Mask;
  use type Clair.Event_Loop.Source_Handle;
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
  use type EI.Operation_Kind;
  use type E.Deferred_Output_Kind;
  use type B.Body_Status;
  use type N.Encode_Status;
  use type P.Request_Id;
  use type P.Role;
  use type PM.Result_Status;
  use type System.Storage_Elements.Storage_Count;

  type IO_Adapter_Access is access all IO_Adapter;
  type Timer_Adapter_Access is access all Timer_Adapter;

  function address_to_io_adapter is new Ada.Unchecked_Conversion
    (System.Address, IO_Adapter_Access);
  function address_to_timer_adapter is new Ada.Unchecked_Conversion
    (System.Address, Timer_Adapter_Access);

  function io_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address) return Clair.Status.Code
  with Convention => C;

  function timer_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     context : System.Address) return Clair.Status.Code
  with Convention => C;

  function io_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     fd      : Clair.IO.Descriptor;
     events  : Clair.Event_Loop.Event_Mask;
     context : System.Address) return Clair.Status.Code
  is
    adapter : constant IO_Adapter_Access := address_to_io_adapter (context);
  begin
    if adapter = null or else source = null then
      return Clair.Status.INVALID_STATE;
    end if;
    return on_io (adapter.all, source.all, fd, events);
  exception
    when others =>
      return Clair.Status.CALLBACK_FAILED;
  end io_callback;

  function timer_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     context : System.Address) return Clair.Status.Code
  is
    adapter : constant Timer_Adapter_Access :=
      address_to_timer_adapter (context);
  begin
    if adapter = null or else source = null then
      return Clair.Status.INVALID_STATE;
    end if;
    return on_timer (adapter.all, source.all);
  exception
    when others =>
      return Clair.Status.CALLBACK_FAILED;
  end timer_callback;

  procedure report_diagnostic
    (self    : in out Context;
     kind    : D.Category;
     status  : Clair.Status.Code;
     message : String)
  is
  begin
    if self.diagnostics = null then
      return;
    end if;

    begin
      D.report (self.diagnostics.all, kind, status, message);
    exception
      when others =>
        null;
    end;
  end report_diagnostic;

  function connection_active (self : Context) return Boolean is
    (self.lifecycle = Active_State);

  MAX_READS_PER_CALLBACK  : constant Positive := 16;
  MAX_WRITES_PER_CALLBACK : constant Positive := 16;
  INITIAL_SLOT_CAPACITY    : constant Positive := 4;
  MIN_REQUEST_TERMINAL_BYTES : constant Positive :=
    3 * P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH;
  procedure Free_Slot is new Ada.Unchecked_Deallocation
    (Object => Request_Slot,
     Name   => Request_Slot_Access);

  procedure Free_Slot_Array is new Ada.Unchecked_Deallocation
    (Object => Request_Slot_Array,
     Name   => Request_Slot_Array_Access);

  procedure Free_Slot_Index_Array is new Ada.Unchecked_Deallocation
    (Object => Request_Slot_Index_Array,
     Name   => Request_Slot_Index_Array_Access);

  procedure Free_Byte_Buffer is new Ada.Unchecked_Deallocation
    (Object => P.Byte_Array,
     Name   => Byte_Buffer_Access);

  procedure Free_Storage_Buffer is new Ada.Unchecked_Deallocation
    (Object => System.Storage_Elements.Storage_Array,
     Name   => Storage_Buffer_Access);

  type Control_Queue_Status is
    (Control_Queued, Control_Would_Block, Control_Impossible);

  function pending_slot_output (slot : Request_Slot) return Natural is
  begin
    return slot.response.length;
  end pending_slot_output;

  function pending_control_output (self : Context) return Natural is
  begin
    if self.control_consumed > self.control_length then
      raise Program_Error with "control consumption exceeds stored output";
    end if;
    return self.control_length - self.control_consumed;
  end pending_control_output;

  procedure reclaim_control_output (self : in out Context) is
    remaining : constant Natural := pending_control_output(self);
  begin
    if self.control_consumed = 0 then
      return;
    end if;

    for index in 1 .. remaining loop
      self.control_bytes(index) :=
        self.control_bytes(self.control_consumed + index);
    end loop;
    self.control_length := remaining;
    self.control_consumed := 0;
  end reclaim_control_output;

  procedure sync_slot_output
    (self       : in out Context;
     slot_index : Positive);

  procedure advance_slot_output
    (self       : in out Context;
     slot_index : Positive;
     count      : Natural)
  is
  begin
    consume_buffered (self.slots(slot_index).response, count);
    sync_slot_output (self, slot_index);
  end advance_slot_output;

  procedure advance_control_output
    (self  : in out Context;
     count : Natural)
  is
    pending : constant Natural := pending_control_output(self);
  begin
    if count > pending then
      raise Program_Error with "control consumption exceeds pending output";
    elsif count = pending then
      self.control_length := 0;
      self.control_consumed := 0;
    else
      self.control_consumed := self.control_consumed + count;
    end if;
  end advance_control_output;

  function refresh_watch
    (self : in out Context) return Clair.Status.Code;

  function process_pending_input
    (self : in out Context) return Clair.Status.Code;

  function try_submit_deferred
    (self : in out Context) return Clair.Status.Code;

  function try_submit_application_batch
    (self : in out Context) return Clair.Status.Code;

  function flush_application_batch
    (self   : in out Context;
     finish : Boolean := False) return Clair.Status.Code;

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

    slot.response.first := 1;
    slot.response.length := 0;
    slot.accounted_output_bytes := 0;
    slot.active_position := 0;
    slot.tree_parent := 0;
    slot.tree_left := 0;
    slot.tree_right := 0;
    slot.tree_height := 1;
    slot.response.limit := slot.response.max_output_bytes;
    slot.params_bytes := 0;
    slot.stdin_bytes := 0;
    slot.data_bytes := 0;
    slot.application_deferred := False;
    slot.deferred_previous := 0;
    slot.deferred_next := 0;
    slot.retirement_ready := False;
    slot.retirement_next := 0;
    slot.free_next := 0;
    slot.response.request_id := 0;
    slot.response.initialized := False;
    slot.response.finished := False;
    slot.response.deferred := False;
    slot.response.failed := False;

    slot.identity_value := NULL_IDENTITY;
    slot.timeout_handler.owner := null;
    slot.timeout_handler.slot_index := 0;
    slot.timeout_timer := Clair.Event_Loop.NULL_SOURCE;
    slot.in_use := False;
  end reset_slot;

  procedure release_slots (self : in out Context) is
  begin
    if self.slots /= null then
      for index in 1 .. self.slot_capacity loop
        if self.slots(index) /= null then
          Free_Slot (self.slots(index));
        end if;
      end loop;
      Free_Slot_Array (self.slots);
    end if;
    if self.slot_order /= null then
      Free_Slot_Index_Array (self.slot_order);
    end if;

    self.slot_capacity := 0;
    self.slot_order_count := 0;
    self.slot_tree_root := 0;
    self.next_unused_slot := 1;
    self.free_slot_head := 0;
    self.deferred_slot_head := 0;
    self.retirement_head := 0;
  end release_slots;

  function grow_slot_storage
    (self : in out Context) return Clair.Status.Code
  is
    new_capacity : Natural;
    new_slots    : Request_Slot_Array_Access := null;
    new_order    : Request_Slot_Index_Array_Access := null;
  begin
    if self.slot_capacity >= self.max_requests_per_connection then
      return Clair.Status.RANGE_ERROR;
    end if;

    if self.slot_capacity = 0 then
      new_capacity := Natural'Min
        (INITIAL_SLOT_CAPACITY, self.max_requests_per_connection);
    elsif self.slot_capacity > self.max_requests_per_connection / 2 then
      new_capacity := self.max_requests_per_connection;
    else
      new_capacity := self.slot_capacity * 2;
    end if;

    begin
      new_slots := new Request_Slot_Array (1 .. Positive(new_capacity));
      new_slots.all := [others => null];
      new_order := new Request_Slot_Index_Array (1 .. Positive(new_capacity));
      new_order.all := [others => 0];
    exception
      when Storage_Error =>
        if new_slots /= null then
          Free_Slot_Array (new_slots);
        end if;
        if new_order /= null then
          Free_Slot_Index_Array (new_order);
        end if;
        return Clair.Status.OUT_OF_MEMORY;
    end;

    for index in 1 .. self.slot_capacity loop
      new_slots(index) := self.slots(index);
      new_order(index) := self.slot_order(index);
    end loop;

    if self.slots /= null then
      Free_Slot_Array (self.slots);
    end if;
    if self.slot_order /= null then
      Free_Slot_Index_Array (self.slot_order);
    end if;

    self.slots := new_slots;
    self.slot_order := new_order;
    self.slot_capacity := new_capacity;
    return Clair.Status.OK;
  end grow_slot_storage;

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

    for position in 1 .. self.slot_order_count loop
      A.release_request (self.shared_admission.all);
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
    self.deferred_request := NULL_IDENTITY;
    self.deferred_active := False;
  end clear_deferred;

  procedure reset_application_batch (self : in out Context) is
  begin
    self.application_batch_length := 0;
    self.application_batch_pairs := 0;
    self.application_batch_request := NULL_IDENTITY;
    self.batch_kind := No_Application_Batch;
    self.application_batch_finish := False;
    self.application_batch_ready := False;
    self.application_batch_flush_requested := False;
  end reset_application_batch;

  procedure release_connection_buffers (self : in out Context) is
  begin
    if self.input_bytes /= null then
      Free_Byte_Buffer (self.input_bytes);
    end if;
    if self.stream_batch /= null then
      Free_Byte_Buffer (self.stream_batch);
    end if;
    if self.application_batch /= null then
      Free_Byte_Buffer (self.application_batch);
    end if;
    if self.deferred_name /= null then
      Free_Byte_Buffer (self.deferred_name);
    end if;
    if self.deferred_value /= null then
      Free_Byte_Buffer (self.deferred_value);
    end if;
    if self.deferred_data /= null then
      Free_Byte_Buffer (self.deferred_data);
    end if;
    if self.write_scratch /= null then
      Free_Storage_Buffer (self.write_scratch);
    end if;

    self.application_batch_capacity := 0;
    self.application_batch_append_reserve := 0;
    self.input_first := 1;
    self.input_length := 0;
    self.stream_batch_length := 0;
    self.deferred_name_length := 0;
    self.deferred_value_length := 0;
    self.deferred_data_length := 0;
    reset_application_batch (self);
  end release_connection_buffers;

  function application_batch_matches
    (self    : Context;
     request : Identity;
     kind    : Application_Batch_Kind) return Boolean
  is
  begin
    return self.application_batch_length > 0 and then
      self.application_batch_request = request and then
      self.batch_kind = kind;
  end application_batch_matches;

  function application_batch_remaining (self : Context) return Natural is
  begin
    if self.application_batch_length > self.application_batch_capacity then
      raise Program_Error with "application batch length overflow";
    end if;
    return self.application_batch_capacity - self.application_batch_length;
  end application_batch_remaining;

  function cancel_execution_wait
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not self.execution_waiting then
      return Clair.Status.OK;
    end if;

    if self.executor = null then
      return Clair.Status.INVALID_STATE;
    end if;

    status := E.cancel_capacity_wait
      (self.executor.all, self.capacity_wait_node);
    if status = Clair.Status.OK then
      self.execution_waiting := False;
    end if;
    return status;
  end cancel_execution_wait;

  function remove_idle_timer
    (self : in out Context) return Clair.Status.Code
  is
  begin
    if self.idle_timer = Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.OK;
    end if;

    return Clair.Event_Loop.remove (self.event_loop.all, self.idle_timer);
  end remove_idle_timer;

  function arm_idle_timer
    (self : in out Context) return Clair.Status.Code
  is
  begin
    if self.idle_timer /= Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.INVALID_STATE;
    end if;

    return Clair.Event_Loop.add_timer
      (self     => self.event_loop.all,
       interval         => self.idle_connection_timeout,
       callback         => timer_callback'Access,
       callback_context => self.timer_handler'Address,
       one_shot         => True,
       source           => self.idle_timer);
  end arm_idle_timer;

  function remove_request_timer
    (self       : in out Context;
     slot_index : in Positive) return Clair.Status.Code
  is
  begin
    if self.slots(slot_index) = null then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.slots(slot_index).timeout_timer = Clair.Event_Loop.NULL_SOURCE then
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
    for index in 1 .. self.slot_capacity loop
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

    if self.slots(slot_index).timeout_timer /= Clair.Event_Loop.NULL_SOURCE then
      return Clair.Status.INVALID_STATE;
    end if;

    return Clair.Event_Loop.add_timer
      (self     => self.event_loop.all,
       interval         => self.request_lifetime_timeout,
       callback         => timer_callback'Access,
       callback_context => self.slots(slot_index).timeout_handler'Address,
       one_shot         => True,
       source           => self.slots(slot_index).timeout_timer);
  end arm_request_timer;

  function clear_deferred_for
    (self    : in out Context;
     request : Identity) return Clair.Status.Code
  is
    clear_batch : constant Boolean :=
      self.application_batch_length > 0 and then
      self.application_batch_request = request;
    clear_job : constant Boolean :=
      self.deferred_active and then self.deferred_request = request;
    status : Clair.Status.Code;
  begin
    if not clear_batch and then not clear_job then
      return Clair.Status.OK;
    end if;

    status := cancel_execution_wait (self);
    if status /= Clair.Status.OK then
      return status;
    end if;

    if clear_batch then
      reset_application_batch (self);
    end if;
    if clear_job then
      clear_deferred (self);
    end if;
    self.application_paused := self.inflight_jobs /= 0;
    return Clair.Status.OK;
  end clear_deferred_for;

  function close_owned (self : in out Context) return Clair.Status.Code is
    status         : Clair.Status.Code;
    cleanup_status : Clair.Status.Code;
  begin
    if self.lifecycle = Reusable_State then
      return Clair.Status.INVALID_STATE;
    end if;

    self.lifecycle := Finalization_Required_State;
    mark_deferred_busy (self);

    if self.executor /= null then
      for index in 1 .. self.slot_capacity loop
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

    if self.watch /= Clair.Event_Loop.NULL_SOURCE then
      if self.event_loop = null then
        return Clair.Status.CONTRACT_VIOLATION;
      end if;

      status := Clair.Event_Loop.remove (self.event_loop.all, self.watch);
      if status /= Clair.Status.OK then
        return status;
      end if;

      self.watch_active := False;
    end if;

    cleanup_status := cancel_execution_wait (self);
    if cleanup_status /= Clair.Status.OK then
      return cleanup_status;
    end if;

    cleanup_status := remove_idle_timer (self);
    if cleanup_status /= Clair.Status.OK then
      return cleanup_status;
    end if;

    cleanup_status := remove_all_request_timers (self);
    if cleanup_status /= Clair.Status.OK then
      return cleanup_status;
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
    release_connection_buffers (self);
    self.connection_id := NO_CONNECTION_IDENTITY;
    self.active_requests := 0;
    self.current_slot := 0;
    self.next_output_position := 1;
    self.output_source := NO_OUTPUT_SOURCE;
    self.output_record_remaining := 0;
    self.input_budget_remaining := 0;
    self.output_budget_remaining := 0;
    self.request_output_bytes := 0;
    self.control_length := 0;
    self.control_consumed := 0;
    self.pending_control := No_Pending_Control;
    self.pending_control_request_id := 0;
    self.pending_control_value := 0;
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
    self.idle_timer := Clair.Event_Loop.NULL_SOURCE;
    clear_deferred (self);
    C.reset (self.decoder);
    self.decoder_at_record_boundary := True;
    return Clair.Status.OK;
  end close_owned;

  function slot_tree_height
    (self  : Context;
     index : Natural) return Natural
  is
  begin
    if index = 0 then
      return 0;
    end if;
    if index > self.slot_capacity or else self.slots(index) = null then
      raise Program_Error with "request tree contains invalid slot";
    end if;
    return self.slots(index).tree_height;
  end slot_tree_height;

  procedure update_slot_tree_height
    (self  : in out Context;
     index : Positive)
  is
    left_height  : constant Natural :=
      slot_tree_height (self, self.slots(index).tree_left);
    right_height : constant Natural :=
      slot_tree_height (self, self.slots(index).tree_right);
  begin
    self.slots(index).tree_height :=
      Positive(Natural'Max(left_height, right_height) + 1);
  end update_slot_tree_height;

  function slot_tree_balance
    (self  : Context;
     index : Positive) return Integer
  is
  begin
    return Integer(slot_tree_height(self, self.slots(index).tree_left)) -
      Integer(slot_tree_height(self, self.slots(index).tree_right));
  end slot_tree_balance;

  function rotate_slot_tree_left
    (self  : in out Context;
     index : Positive) return Positive
  is
    pivot  : constant Natural := self.slots(index).tree_right;
    parent : constant Natural := self.slots(index).tree_parent;
    middle : Natural;
  begin
    if pivot = 0 then
      raise Program_Error with "request tree left rotation without right child";
    end if;
    middle := self.slots(pivot).tree_left;

    if parent = 0 then
      self.slot_tree_root := pivot;
    elsif self.slots(parent).tree_left = index then
      self.slots(parent).tree_left := pivot;
    elsif self.slots(parent).tree_right = index then
      self.slots(parent).tree_right := pivot;
    else
      raise Program_Error with "request tree parent link mismatch";
    end if;
    self.slots(pivot).tree_parent := parent;

    self.slots(pivot).tree_left := index;
    self.slots(index).tree_parent := pivot;
    self.slots(index).tree_right := middle;
    if middle /= 0 then
      self.slots(middle).tree_parent := index;
    end if;

    update_slot_tree_height (self, index);
    update_slot_tree_height (self, Positive(pivot));
    return Positive(pivot);
  end rotate_slot_tree_left;

  function rotate_slot_tree_right
    (self  : in out Context;
     index : Positive) return Positive
  is
    pivot  : constant Natural := self.slots(index).tree_left;
    parent : constant Natural := self.slots(index).tree_parent;
    middle : Natural;
  begin
    if pivot = 0 then
      raise Program_Error with "request tree right rotation without left child";
    end if;
    middle := self.slots(pivot).tree_right;

    if parent = 0 then
      self.slot_tree_root := pivot;
    elsif self.slots(parent).tree_left = index then
      self.slots(parent).tree_left := pivot;
    elsif self.slots(parent).tree_right = index then
      self.slots(parent).tree_right := pivot;
    else
      raise Program_Error with "request tree parent link mismatch";
    end if;
    self.slots(pivot).tree_parent := parent;

    self.slots(pivot).tree_right := index;
    self.slots(index).tree_parent := pivot;
    self.slots(index).tree_left := middle;
    if middle /= 0 then
      self.slots(middle).tree_parent := index;
    end if;

    update_slot_tree_height (self, index);
    update_slot_tree_height (self, Positive(pivot));
    return Positive(pivot);
  end rotate_slot_tree_right;

  procedure rebalance_slot_tree
    (self  : in out Context;
     start : Natural)
  is
    current    : Natural := start;
    subtree    : Positive := 1;
    child      : Natural;
    adjustment : Integer;
  begin
    while current /= 0 loop
      update_slot_tree_height (self, Positive(current));
      adjustment := slot_tree_balance (self, Positive(current));

      if adjustment > 1 then
        child := self.slots(current).tree_left;
        if child = 0 then
          raise Program_Error with "request tree balance lacks left child";
        end if;
        if slot_tree_balance(self, Positive(child)) < 0 then
          subtree := rotate_slot_tree_left (self, Positive(child));
          if self.slots(current).tree_left /= subtree then
            raise Program_Error with "request tree left-child rotation mismatch";
          end if;
        end if;
        subtree := rotate_slot_tree_right (self, Positive(current));
      elsif adjustment < -1 then
        child := self.slots(current).tree_right;
        if child = 0 then
          raise Program_Error with "request tree balance lacks right child";
        end if;
        if slot_tree_balance(self, Positive(child)) > 0 then
          subtree := rotate_slot_tree_right (self, Positive(child));
          if self.slots(current).tree_right /= subtree then
            raise Program_Error with "request tree right-child rotation mismatch";
          end if;
        end if;
        subtree := rotate_slot_tree_left (self, Positive(current));
      else
        subtree := Positive(current);
      end if;

      current := self.slots(subtree).tree_parent;
    end loop;
  end rebalance_slot_tree;

  function find_slot
    (self       : Context;
     request_id : P.Request_Id) return Natural
  is
    index     : Natural := self.slot_tree_root;
    candidate : P.Request_Id;
  begin
    while index /= 0 loop
      if index > self.slot_capacity or else self.slots(index) = null or else
         not self.slots(index).in_use
      then
        raise Program_Error with "request tree index is inconsistent";
      end if;

      candidate := self.slots(index).identity_value.request_id;
      if candidate = request_id then
        return index;
      elsif request_id < candidate then
        index := self.slots(index).tree_left;
      else
        index := self.slots(index).tree_right;
      end if;
    end loop;

    return 0;
  end find_slot;

  function find_slot
    (self    : Context;
     request : Identity) return Natural
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

  function insert_slot_index
    (self  : in out Context;
     index : Positive) return Boolean
  is
    request_id : constant P.Request_Id :=
      self.slots(index).identity_value.request_id;
    parent     : Natural := 0;
    current    : Natural := self.slot_tree_root;
    candidate  : P.Request_Id;
  begin
    if self.slots(index).active_position /= 0 or else
       self.slots(index).tree_parent /= 0 or else
       self.slots(index).tree_left /= 0 or else
       self.slots(index).tree_right /= 0
    then
      raise Program_Error with "request slot index inserted twice";
    end if;

    while current /= 0 loop
      parent := current;
      candidate := self.slots(current).identity_value.request_id;
      if request_id = candidate then
        return False;
      elsif request_id < candidate then
        current := self.slots(current).tree_left;
      else
        current := self.slots(current).tree_right;
      end if;
    end loop;

    self.slots(index).tree_parent := parent;
    self.slots(index).tree_height := 1;
    if parent = 0 then
      self.slot_tree_root := index;
    elsif request_id < self.slots(parent).identity_value.request_id then
      self.slots(parent).tree_left := index;
    else
      self.slots(parent).tree_right := index;
    end if;

    self.slot_order_count := self.slot_order_count + 1;
    self.slot_order(self.slot_order_count) := index;
    self.slots(index).active_position := self.slot_order_count;
    rebalance_slot_tree (self, parent);
    return True;
  end insert_slot_index;

  procedure replace_slot_tree_node
    (self        : in out Context;
     old_index   : Positive;
     replacement : Natural)
  is
    parent : constant Natural := self.slots(old_index).tree_parent;
  begin
    if parent = 0 then
      if self.slot_tree_root /= old_index then
        raise Program_Error with "request tree root mismatch";
      end if;
      self.slot_tree_root := replacement;
    elsif self.slots(parent).tree_left = old_index then
      self.slots(parent).tree_left := replacement;
    elsif self.slots(parent).tree_right = old_index then
      self.slots(parent).tree_right := replacement;
    else
      raise Program_Error with "request tree replacement parent mismatch";
    end if;

    if replacement /= 0 then
      self.slots(replacement).tree_parent := parent;
    end if;
  end replace_slot_tree_node;

  procedure remove_slot_index
    (self  : in out Context;
     index : Positive)
  is
    left_child      : constant Natural := self.slots(index).tree_left;
    right_child     : constant Natural := self.slots(index).tree_right;
    rebalance_start : Natural := 0;
    successor       : Natural;
    successor_parent : Natural;
    successor_right  : Natural;
    position         : constant Natural := self.slots(index).active_position;
    moved            : Natural;
  begin
    if position = 0 or else position > self.slot_order_count or else
       self.slot_order(position) /= index
    then
      raise Program_Error with "request active-slot index removal mismatch";
    end if;

    if left_child = 0 then
      rebalance_start := self.slots(index).tree_parent;
      replace_slot_tree_node (self, index, right_child);
    elsif right_child = 0 then
      rebalance_start := self.slots(index).tree_parent;
      replace_slot_tree_node (self, index, left_child);
    else
      successor := right_child;
      while self.slots(successor).tree_left /= 0 loop
        successor := self.slots(successor).tree_left;
      end loop;

      if self.slots(successor).tree_parent = index then
        replace_slot_tree_node (self, index, successor);
        self.slots(successor).tree_left := left_child;
        self.slots(left_child).tree_parent := successor;
        update_slot_tree_height (self, Positive(successor));
        rebalance_start := successor;
      else
        successor_parent := self.slots(successor).tree_parent;
        successor_right := self.slots(successor).tree_right;
        replace_slot_tree_node (self, Positive(successor), successor_right);
        self.slots(successor).tree_right := right_child;
        self.slots(right_child).tree_parent := successor;
        replace_slot_tree_node (self, index, successor);
        self.slots(successor).tree_left := left_child;
        self.slots(left_child).tree_parent := successor;
        update_slot_tree_height (self, Positive(successor));
        rebalance_start := successor_parent;
      end if;
    end if;

    self.slots(index).tree_parent := 0;
    self.slots(index).tree_left := 0;
    self.slots(index).tree_right := 0;
    self.slots(index).tree_height := 1;

    if rebalance_start /= 0 then
      rebalance_slot_tree (self, rebalance_start);
    end if;

    moved := self.slot_order(self.slot_order_count);
    if position < self.slot_order_count then
      self.slot_order(position) := moved;
      self.slots(moved).active_position := position;
    end if;
    self.slot_order(self.slot_order_count) := 0;
    self.slots(index).active_position := 0;
    self.slot_order_count := self.slot_order_count - 1;
  end remove_slot_index;

  procedure unlink_deferred_slot
    (self  : in out Context;
     index : Positive)
  is
    previous : constant Natural := self.slots(index).deferred_previous;
    next     : constant Natural := self.slots(index).deferred_next;
  begin
    if not self.slots(index).application_deferred then
      return;
    end if;

    if previous = 0 then
      if self.deferred_slot_head /= index then
        raise Program_Error with "deferred slot head mismatch";
      end if;
      self.deferred_slot_head := next;
    else
      self.slots(previous).deferred_next := next;
    end if;

    if next /= 0 then
      self.slots(next).deferred_previous := previous;
    end if;

    self.slots(index).application_deferred := False;
    self.slots(index).deferred_previous := 0;
    self.slots(index).deferred_next := 0;
  end unlink_deferred_slot;

  procedure mark_slot_deferred
    (self  : in out Context;
     index : Positive)
  is
  begin
    if self.slots(index).application_deferred then
      return;
    end if;

    self.slots(index).application_deferred := True;
    self.slots(index).deferred_previous := 0;
    self.slots(index).deferred_next := self.deferred_slot_head;
    if self.deferred_slot_head /= 0 then
      self.slots(self.deferred_slot_head).deferred_previous := index;
    end if;
    self.deferred_slot_head := index;
  end mark_slot_deferred;

  procedure release_slot
    (self  : in out Context;
     index : Positive)
  is
  begin
    if self.slots(index) = null or else not self.slots(index).in_use then
      raise Program_Error with "inactive request slot released";
    end if;

    if self.slots(index).response.length /= 0 or else
       self.slots(index).accounted_output_bytes /= 0
    then
      raise Program_Error with "request slot released with pending output";
    end if;
    if self.slots(index).retirement_ready or else
       self.slots(index).retirement_next /= 0
    then
      raise Program_Error with "request slot released while retirement-linked";
    end if;

    unlink_deferred_slot (self, index);
    remove_slot_index (self, index);
    reset_slot (self.slots(index).all);
    self.slots(index).free_next := self.free_slot_head;
    self.free_slot_head := index;
    self.active_requests := self.active_requests - 1;
  end release_slot;

  function allocate_slot
    (self       : in out Context;
     request_id : P.Request_Id;
     index      : out Natural) return Clair.Status.Code
  is
    generation : Fasyn.Request.Generation;
    status     : Clair.Status.Code;
  begin
    index := 0;
    if self.generation_exhausted then
      return Clair.Status.RANGE_ERROR;
    end if;

    if self.free_slot_head /= 0 then
      index := self.free_slot_head;
      self.free_slot_head := self.slots(index).free_next;
    elsif self.next_unused_slot <= self.max_requests_per_connection then
      if self.next_unused_slot > self.slot_capacity then
        status := grow_slot_storage (self);
        if status /= Clair.Status.OK then
          return status;
        end if;
      end if;
      index := self.next_unused_slot;
      begin
        self.slots(index) := new Request_Slot
          (max_name_bytes           => self.max_name_bytes,
           max_value_bytes          => self.max_value_bytes,
           max_request_output_bytes => self.max_request_output_bytes);
      exception
        when Storage_Error =>
          index := 0;
          return Clair.Status.OUT_OF_MEMORY;
      end;
      self.next_unused_slot := self.next_unused_slot + 1;
    else
      raise Program_Error with "request slot free-list exhausted";
    end if;

    reset_slot (self.slots(index).all);
    self.slots(index).timeout_handler.owner := self.dispatcher.owner;
    self.slots(index).timeout_handler.slot_index := index;
    generation := self.next_generation;
    if generation = NO_GENERATION then
      raise Program_Error with "zero request generation in active allocator";
    end if;

    if generation = Fasyn.Request.Generation'Last then
      self.generation_exhausted := True;
    else
      self.next_generation := generation + 1;
    end if;

    self.slots(index).identity_value :=
      (connection_id => self.connection_id,
       request_id    => request_id,
       generation    => generation);
    self.slots(index).in_use := True;
    if not insert_slot_index (self, Positive(index)) then
      raise Program_Error with "duplicate request slot insertion";
    end if;

    self.active_requests := self.active_requests + 1;
    return Clair.Status.OK;
  end allocate_slot;

  procedure queue_retirement_if_ready
    (self       : in out Context;
     slot_index : Positive)
  is
  begin
    if self.slots(slot_index) = null or else
       not self.slots(slot_index).in_use
    then
      raise Program_Error with "retirement check targets inactive request slot";
    end if;

    if not self.slots(slot_index).exchange.complete_flag or else
       pending_slot_output(self.slots(slot_index).all) /= 0
    then
      return;
    end if;

    if self.slots(slot_index).retirement_ready then
      return;
    end if;

    self.slots(slot_index).retirement_ready := True;
    self.slots(slot_index).retirement_next := self.retirement_head;
    self.retirement_head := slot_index;
  end queue_retirement_if_ready;

  procedure sync_slot_output
    (self       : in out Context;
     slot_index : Positive)
  is
    actual    : constant Natural := self.slots(slot_index).response.length;
    accounted : constant Natural :=
      self.slots(slot_index).accounted_output_bytes;
    change    : Natural;
  begin
    if actual > accounted then
      change := actual - accounted;
      if self.request_output_bytes > self.max_connection_output_bytes or else
         change > self.max_connection_output_bytes - self.request_output_bytes
      then
        raise Program_Error with "request output accounting exceeds connection bound";
      end if;
      self.request_output_bytes := self.request_output_bytes + change;
    elsif actual < accounted then
      change := accounted - actual;
      if change > self.request_output_bytes then
        raise Program_Error with "request output accounting underflow";
      end if;
      self.request_output_bytes := self.request_output_bytes - change;
    end if;

    self.slots(slot_index).accounted_output_bytes := actual;
    queue_retirement_if_ready (self, slot_index);
  end sync_slot_output;

  function direct_pending_output_bytes (self : Context) return Natural is
    control : constant Natural := pending_control_output(self);
  begin
    if control > Natural'Last - self.request_output_bytes then
      raise Program_Error with "direct output accounting overflow";
    end if;

    return control + self.request_output_bytes;
  end direct_pending_output_bytes;

  function pending_output_bytes (self : Context) return Natural is
    direct : constant Natural := direct_pending_output_bytes(self);
    staged : Natural := 0;
  begin
    if self.executor /= null and then
       self.connection_id /= NO_CONNECTION_IDENTITY
    then
      staged := EI.deferred_connection_pending_bytes
        (self.executor.all, self.connection_id);
    end if;

    if staged > Natural'Last - direct then
      raise Program_Error with "deferred output accounting overflow";
    end if;

    return direct + staged;
  end pending_output_bytes;

  function has_application_deferred (self : Context) return Boolean is
  begin
    return self.deferred_slot_head /= 0;
  end has_application_deferred;

  procedure mark_deferred_busy (self : in out Context) is
  begin
    if not has_application_deferred(self) then
      return;
    end if;

    if self.executor /= null and then
       self.connection_id /= NO_CONNECTION_IDENTITY
    then
      EI.set_deferred_connection_busy
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

    EI.sync_deferred_connection
      (self.executor.all,
       self.connection_id,
       direct_pending_output_bytes(self));

    declare
      index : Natural := self.deferred_slot_head;
    begin
      while index /= 0 loop
        EI.sync_deferred_request
          (self.executor.all, self.slots(index).identity_value,
           pending_slot_output(self.slots(index).all));
        index := self.slots(index).deferred_next;
      end loop;
    end;

    EI.set_deferred_connection_busy
      (self.executor.all, self.connection_id, busy);
  end publish_deferred_state;

  procedure prepare_writer_budget
    (self : Context;
     slot : in out Request_Slot)
  is
    total         : Natural;
    own_pending   : Natural;
    other_pending : Natural;
    available     : Natural;
  begin
    total := pending_output_bytes (self);
    own_pending := slot.response.length;
    if total < own_pending then
      slot.response.limit := own_pending;
      return;
    end if;

    other_pending := total - own_pending;
    if other_pending >= self.max_connection_output_bytes then
      available := own_pending;
    else
      available := self.max_connection_output_bytes - other_pending;
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
     limit   : Natural) return Boolean
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
    if record_type = P.PARAMS then
      return account_bytes
        (slot.params_bytes, amount, self.input_limits.max_params_bytes);
    elsif record_type = P.STDIN then
      return account_bytes
        (slot.stdin_bytes, amount, self.input_limits.max_stdin_bytes);
    elsif record_type = P.DATA then
      return account_bytes
        (slot.data_bytes, amount, self.input_limits.max_data_bytes);
    end if;

    return True;
  end account_input_record;

  function mark_resource_limit
    (self       : in out Context;
     slot_index : Positive) return Clair.Status.Code
  is
    request : constant Identity :=
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

    report_diagnostic
      (self, D.Resource_Error, Clair.Status.RANGE_ERROR,
       "FastCGI request input limit exceeded");

    return Clair.Status.OK;
  end mark_resource_limit;

  function complete_resource_limit
    (self       : in out Context;
     slot_index : Positive) return Clair.Status.Code
  is
    request_status : Input_Status;
  begin
    prepare_writer_budget (self, self.slots(slot_index).all);
    request_status := cancel
      (self     => self.slots(slot_index).exchange,
       response => self.slots(slot_index).response,
       cause    => Resource_Limit);
    sync_slot_output (self, slot_index);

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
     request : Identity) return Natural
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
      staged_request := EI.deferred_pending_bytes (self.executor.all, request);
    end if;

    if staged_request >
         Natural'Last - pending_slot_output(self.slots(slot_index).all)
    then
      return 0;
    end if;

    request_used :=
      pending_slot_output(self.slots(slot_index).all) + staged_request;
    if request_used >= self.slots(slot_index).response.max_output_bytes then
      request_remaining := 0;
    else
      request_remaining :=
        self.slots(slot_index).response.max_output_bytes - request_used;
    end if;

    pending := pending_output_bytes (self);
    if pending >= self.max_connection_output_bytes then
      connection_remaining := 0;
    else
      connection_remaining := self.max_connection_output_bytes - pending;
    end if;

    return Natural'Min (request_remaining, connection_remaining);
  end application_output_limit;

  function try_submit_application_batch
    (self : in out Context) return Clair.Status.Code
  is
    accepted     : Boolean;
    output_limit : Natural := 0;
    slot_index   : Natural;
    role : P.Role;
    status       : Clair.Status.Code;
  begin
    if not self.application_batch_ready or else self.execution_waiting then
      return Clair.Status.OK;
    end if;

    if self.application_batch = null or else
       self.application_batch_length = 0 or else
       self.batch_kind = No_Application_Batch
    then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.executor = null or else not E.is_accepting(self.executor.all) then
      return Clair.Status.INVALID_STATE;
    end if;

    slot_index := find_slot (self, self.application_batch_request);
    if slot_index = 0 then
      reset_application_batch (self);
      self.application_paused := self.inflight_jobs /= 0;
      return Clair.Status.OK;
    end if;

    role := self.slots(slot_index).exchange.role_value;

    if self.batch_kind = Parameter_Application_Batch and then
       not self.application_batch_finish
    then
      output_limit := 0;
    elsif role = P.Filter and then
          not self.slots(slot_index).exchange.stdin_closed
    then
      output_limit := 0;
    else
      output_limit :=
        application_output_limit (self, self.application_batch_request);
      if output_limit = 0 then
        if pending_output_bytes(self) > 0 then
          return Clair.Status.OK;
        end if;
        return Clair.Status.RANGE_ERROR;
      end if;
    end if;

    case self.batch_kind is
      when Parameter_Application_Batch =>
        status := EI.submit_parameter_batch
          (self               => self.executor.all,
           request            => self.application_batch_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           encoded            =>
             self.application_batch(1 .. self.application_batch_length),
           finish_params      => self.application_batch_finish,
           output_limit       => output_limit,
           accepted           => accepted,
           role               => role);

      when Stdin_Application_Batch =>
        status := EI.submit_stdin_batch
          (self               => self.executor.all,
           request            => self.application_batch_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           data               =>
             self.application_batch(1 .. self.application_batch_length),
           finish_stream      => self.application_batch_finish,
           output_limit       => output_limit,
           accepted           => accepted,
           role               => role);

      when Data_Application_Batch =>
        status := EI.submit_data_batch
          (self               => self.executor.all,
           request            => self.application_batch_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           data               =>
             self.application_batch(1 .. self.application_batch_length),
           finish_stream      => self.application_batch_finish,
           output_limit       => output_limit,
           accepted           => accepted);

      when No_Application_Batch =>
        return Clair.Status.INVALID_STATE;
    end case;

    if status /= Clair.Status.OK then
      return status;
    end if;

    if accepted then
      reset_application_batch (self);
      self.inflight_jobs := 1;
      return Clair.Status.OK;
    end if;

    if not E.is_accepting(self.executor.all) then
      return Clair.Status.INVALID_STATE;
    end if;

    status := E.wait_for_capacity
      (self.executor.all, self.capacity_wait_node,
       self.capacity_handler'Unchecked_Access);
    if status = Clair.Status.OK then
      self.execution_waiting := True;
    end if;
    return status;
  end try_submit_application_batch;

  function flush_application_batch
    (self   : in out Context;
     finish : Boolean := False) return Clair.Status.Code
  is
  begin
    if self.application_batch_length = 0 then
      return Clair.Status.OK;
    end if;

    if self.application_batch_ready then
      if finish and then not self.application_batch_finish then
        return Clair.Status.INVALID_STATE;
      end if;
      return try_submit_application_batch (self);
    end if;

    if self.inflight_jobs /= 0 or else self.deferred_active then
      return Clair.Status.INVALID_STATE;
    end if;

    self.application_batch_finish := finish;
    self.application_batch_ready := True;
    self.application_batch_flush_requested := False;
    self.application_paused := True;
    return try_submit_application_batch (self);
  end flush_application_batch;

  function flush_collected_application_batch
    (self : in out Context) return Clair.Status.Code
  is
  begin
    if self.application_batch_length = 0 or else
       self.application_batch_ready or else
       self.application_paused
    then
      return Clair.Status.OK;
    end if;

    return flush_application_batch
      (self, self.application_batch_finish);
  end flush_collected_application_batch;

  function queue_control_record
    (self        : in out Context;
     record_type : P.Byte;
     request_id  : P.Request_Id;
     content     : P.Byte_Array) return Control_Queue_Status
  is
    record_length : constant Natural := P.HEADER_LENGTH + content'length;
    header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => request_id,
       content_length => P.Content_Length(content'length),
       padding_length => 0);
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    if record_length > CONTROL_OUTPUT_CAPACITY or else
       self.max_connection_output_bytes < record_length
    then
      return Control_Impossible;
    end if;

    if self.control_length + record_length > CONTROL_OUTPUT_CAPACITY and then
       self.control_consumed > 0
    then
      reclaim_control_output (self);
    end if;

    if self.control_length + record_length > CONTROL_OUTPUT_CAPACITY or else
       pending_output_bytes(self) >
         self.max_connection_output_bytes - record_length
    then
      return Control_Would_Block;
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

    return Control_Queued;
  end queue_control_record;

  function queue_protocol_status
    (self            : in out Context;
     request_id      : P.Request_Id;
     protocol_status : P.Byte) return Control_Queue_Status
  is
    end_request : constant B.End_Request_Body :=
      (application_status   => 0,
       protocol_status_code => protocol_status);
    body_bytes  : P.Byte_Array (0 .. B.END_REQUEST_BODY_LENGTH - 1);
    written     : Natural;
    body_status : B.Body_Status;
  begin
    body_status := B.encode_end_request
      (request_body => end_request,
       output       => body_bytes,
       written      => written);

    if body_status /= B.Body_Complete or else
       written /= B.END_REQUEST_BODY_LENGTH
    then
      return Control_Impossible;
    end if;

    return queue_control_record
      (self, P.END_REQUEST, request_id, body_bytes);
  end queue_protocol_status;

  function queue_cant_mpx
    (self       : in out Context;
     request_id : P.Request_Id) return Control_Queue_Status
  is
  begin
    return queue_protocol_status
      (self, request_id, P.CANT_MPX_CONN);
  end queue_cant_mpx;

  function queue_overloaded
    (self       : in out Context;
     request_id : P.Request_Id) return Control_Queue_Status
  is
  begin
    return queue_protocol_status
      (self, request_id, P.OVERLOADED);
  end queue_overloaded;

  function effective_management_values (self : Context) return PM.Values is
    max_connections : Natural := 1;
    max_requests    : Natural := self.max_requests_per_connection;
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
    (self : in out Context) return Control_Queue_Status
  is
    result_bytes  : P.Byte_Array (1 .. MANAGEMENT_RESULT_CAPACITY);
    written       : Natural;
    result_status : PM.Result_Status;
  begin
    result_status := PM.encode_result
      (self.management_query,
       effective_management_values(self),
       result_bytes,
       written);

    if result_status /= PM.Result_Complete then
      return Control_Impossible;
    end if;

    if written = 0 then
      declare
        empty : P.Byte_Array (1 .. 0);
      begin
        return queue_control_record
          (self, P.GET_VALUES_RESULT, 0, empty);
      end;
    end if;

    return queue_control_record
      (self,
       P.GET_VALUES_RESULT,
       0,
       result_bytes(result_bytes'first .. result_bytes'first + written - 1));
  end queue_get_values_result;

  function queue_unknown_type
    (self        : in out Context;
     record_type : P.Byte) return Control_Queue_Status
  is
    unknown_body : constant B.Unknown_Type_Body :=
      (record_type => record_type);
    body_bytes  : P.Byte_Array (0 .. B.UNKNOWN_TYPE_BODY_LENGTH - 1);
    written     : Natural;
    body_status : B.Body_Status;
  begin
    body_status := B.encode_unknown_type
      (unknown_body, body_bytes, written);

    if body_status /= B.Body_Complete or else
       written /= B.UNKNOWN_TYPE_BODY_LENGTH
    then
      return Control_Impossible;
    end if;

    return queue_control_record
      (self, P.UNKNOWN_TYPE, 0, body_bytes);
  end queue_unknown_type;

  procedure defer_control
    (self       : in out Context;
     kind       : Pending_Control_Kind;
     request_id : P.Request_Id := 0;
     value      : P.Byte := 0)
  is
  begin
    if kind = No_Pending_Control or else
       self.pending_control /= No_Pending_Control
    then
      raise Program_Error with "invalid pending control transition";
    end if;

    self.pending_control := kind;
    self.pending_control_request_id := request_id;
    self.pending_control_value := value;
  end defer_control;

  function flush_pending_control
    (self : in out Context) return Clair.Status.Code
  is
    kind   : constant Pending_Control_Kind := self.pending_control;
    queued : Control_Queue_Status;
  begin
    case kind is
      when No_Pending_Control =>
        return Clair.Status.OK;
      when Pending_Protocol_Status =>
        queued := queue_protocol_status
          (self, self.pending_control_request_id, self.pending_control_value);
      when Pending_Get_Values_Result =>
        queued := queue_get_values_result (self);
      when Pending_Unknown_Type =>
        queued := queue_unknown_type (self, self.pending_control_value);
    end case;

    case queued is
      when Control_Would_Block =>
        return Clair.Status.OK;
      when Control_Impossible =>
        return close_owned (self);
      when Control_Queued =>
        null;
    end case;

    self.pending_control := No_Pending_Control;
    self.pending_control_request_id := 0;
    self.pending_control_value := 0;

    if kind = Pending_Get_Values_Result or else
       kind = Pending_Unknown_Type
    then
      reset_management (self);
    end if;

    return Clair.Status.OK;
  end flush_pending_control;

  procedure update_backpressure (self : in out Context) is
    high_water : constant Natural :=
      self.max_connection_output_bytes - self.max_connection_output_bytes / 4;
    low_water : constant Natural := self.max_connection_output_bytes / 2;
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

  function begin_deferred
    (self      : in out Context;
     operation : EI.Operation_Kind) return Boolean
  is
  begin
    if not connection_active (self) or else
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

  function prepare_application_batch
    (self    : in out Context;
     request : Identity;
     kind    : Application_Batch_Kind) return Boolean
  is
  begin
    if self.application_batch = null or else
       self.application_batch_capacity = 0 or else
       self.application_batch_ready or else
       self.application_paused or else
       self.inflight_jobs /= 0 or else
       self.deferred_active or else
       self.execution_waiting
    then
      return False;
    end if;

    if self.application_batch_length = 0 then
      self.application_batch_request := request;
      self.batch_kind := kind;
      self.application_batch_pairs := 0;
      self.application_batch_finish := False;
      return True;
    end if;

    return application_batch_matches (self, request, kind);
  end prepare_application_batch;

  overriding procedure on_parameter
    (self    : in out Dispatch_Application;
     context : in Fasyn.Request.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    owner        : constant Context_Access := self.owner;
    encoded_size : Natural;
    written      : Natural;
    encode_status : N.Encode_Status;
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

    if not prepare_application_batch
      (owner.all, context.request_value, Parameter_Application_Batch)
    then
      owner.dispatch_failed := True;
      return;
    end if;

    encoded_size := N.encoded_size (name'length, value'length);
    if encoded_size > application_batch_remaining(owner.all) then
      owner.dispatch_failed := True;
      return;
    end if;

    encode_status := N.encode_pair
      (name,
       value,
       owner.application_batch
         (owner.application_batch_length + 1 ..
          owner.application_batch_capacity),
       written);
    if encode_status /= N.Encode_Complete or else written /= encoded_size then
      owner.dispatch_failed := True;
      return;
    end if;

    owner.application_batch_length :=
      owner.application_batch_length + written;
    owner.application_batch_pairs := owner.application_batch_pairs + 1;

    if owner.application_batch_pairs = EI.max_parameter_pairs_per_batch or else
       application_batch_remaining(owner.all) <
         owner.application_batch_append_reserve
    then
      owner.application_batch_flush_requested := True;
    end if;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer)
  is
    pragma Unreferenced (response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    if application_batch_matches
      (owner.all, context.request_value, Parameter_Application_Batch)
    then
      owner.application_batch_finish := True;
      owner.application_batch_flush_requested := True;
    elsif owner.application_batch_length /= 0 then
      owner.dispatch_failed := True;
    elsif begin_deferred (owner.all, EI.Finish_Params) then
      submit_or_fail (owner.all);
    end if;
  end on_params_end;

  procedure append_stream_application_batch
    (owner   : in out Context;
     request : Identity;
     kind    : Application_Batch_Kind;
     data    : P.Byte_Array)
  is
  begin
    if data'length = 0 or else data'length > owner.read_buffer_bytes or else
       not prepare_application_batch(owner, request, kind) or else
       data'length > application_batch_remaining(owner)
    then
      owner.dispatch_failed := True;
      return;
    end if;

    for index in data'range loop
      owner.application_batch_length := owner.application_batch_length + 1;
      owner.application_batch(owner.application_batch_length) := data(index);
    end loop;

    if application_batch_remaining(owner) <
         owner.application_batch_append_reserve
    then
      owner.application_batch_flush_requested := True;
    end if;
  end append_stream_application_batch;

  overriding procedure on_stdin
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     data     : in P.Byte_Array;
     response : in out Writer)
  is
    pragma Unreferenced (response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    append_stream_application_batch
      (owner.all, context.request_value, Stdin_Application_Batch, data);
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer)
  is
    pragma Unreferenced (response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    if application_batch_matches
      (owner.all, context.request_value, Stdin_Application_Batch)
    then
      owner.application_batch_finish := True;
      owner.application_batch_flush_requested := True;
    elsif owner.application_batch_length /= 0 then
      owner.dispatch_failed := True;
    elsif begin_deferred (owner.all, EI.Finish_Stdin) then
      submit_or_fail (owner.all);
    end if;
  end on_stdin_end;

  overriding procedure on_data
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     data     : in P.Byte_Array;
     response : in out Writer)
  is
    pragma Unreferenced (response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    append_stream_application_batch
      (owner.all, context.request_value, Data_Application_Batch, data);
  end on_data;

  overriding procedure on_data_end
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer)
  is
    pragma Unreferenced (response);
    owner : constant Context_Access := self.owner;
  begin
    if owner = null then
      return;
    end if;

    if application_batch_matches
      (owner.all, context.request_value, Data_Application_Batch)
    then
      owner.application_batch_finish := True;
      owner.application_batch_flush_requested := True;
    elsif owner.application_batch_length /= 0 then
      owner.dispatch_failed := True;
    elsif begin_deferred (owner.all, EI.Finish_Data) then
      submit_or_fail (owner.all);
    end if;
  end on_data_end;

  function try_submit_deferred
    (self : in out Context) return Clair.Status.Code
  is
    accepted     : Boolean;
    output_limit : Natural;
    slot_index   : Natural;
    role : P.Role;
    status       : Clair.Status.Code;
  begin
    if not self.deferred_active or else self.execution_waiting then
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

    role := self.slots(slot_index).exchange.role_value;

    if role = P.Filter and then
       not self.slots(slot_index).exchange.stdin_closed
    then
      output_limit := 0;
    else
      output_limit := application_output_limit (self, self.deferred_request);

      if self.deferred_operation /= EI.Deliver_Parameter and then
         output_limit = 0
      then
        if pending_output_bytes(self) > 0 then
          return Clair.Status.OK;
        end if;

        return Clair.Status.RANGE_ERROR;
      end if;
    end if;

    case self.deferred_operation is
      when EI.Deliver_Parameter =>
        status := E.submit_parameter
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           name               =>
             self.deferred_name(1 .. self.deferred_name_length),
           value              =>
             self.deferred_value(1 .. self.deferred_value_length),
           accepted           => accepted,
           role               => role);

      when EI.Finish_Params =>
        status := E.submit_params_end
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           output_limit       => output_limit,
           accepted           => accepted,
           role               => role);

      when EI.Deliver_Stdin =>
        status := E.submit_stdin
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           data               =>
             self.deferred_data(1 .. self.deferred_data_length),
           output_limit       => output_limit,
           accepted           => accepted,
           role               => role);

      when EI.Finish_Stdin =>
        status := E.submit_stdin_end
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           output_limit       => output_limit,
           accepted           => accepted,
           role               => role);

      when EI.Deliver_Data =>
        status := E.submit_data
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           data               =>
             self.deferred_data(1 .. self.deferred_data_length),
           output_limit       => output_limit,
           accepted           => accepted);

      when EI.Finish_Data =>
        status := E.submit_data_end
          (self               => self.executor.all,
           request            => self.deferred_request,
           application        => self.application,
           completion_handler => self.completion_handler'Unchecked_Access,
           output_limit       => output_limit,
           accepted           => accepted);

    end case;

    if status /= Clair.Status.OK then
      return status;
    end if;

    if accepted then
      clear_deferred (self);
      self.inflight_jobs := 1;
      return Clair.Status.OK;
    end if;

    if not E.is_accepting(self.executor.all) then
      return Clair.Status.INVALID_STATE;
    end if;

    status := E.wait_for_capacity
      (self.executor.all, self.capacity_wait_node,
       self.capacity_handler'Unchecked_Access);
    if status = Clair.Status.OK then
      self.execution_waiting := True;
    end if;
    return status;
  end try_submit_deferred;

  function retire_completed_requests
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
    index  : Natural;
  begin
    while self.retirement_head /= 0 loop
      index := self.retirement_head;
      if index > self.slot_capacity or else self.slots(index) = null or else
         not self.slots(index).in_use or else
         not self.slots(index).retirement_ready
      then
        raise Program_Error with "retirement queue contains invalid request slot";
      end if;

      if not self.slots(index).exchange.complete_flag or else
         pending_slot_output(self.slots(index).all) /= 0
      then
        raise Program_Error with "retirement queue contains non-retireable request";
      end if;

      -- Keep the slot linked until the only fallible cleanup step succeeds.
      -- A transient timer-removal failure can then be retried without losing
      -- the completed request from retirement discovery.
      status := remove_request_timer (self, Positive(index));
      if status /= Clair.Status.OK then
        return status;
      end if;

      self.retirement_head := self.slots(index).retirement_next;
      self.slots(index).retirement_ready := False;
      self.slots(index).retirement_next := 0;

      if not self.slots(index).exchange.keep_flag then
        self.close_requested := True;
      end if;

      if self.executor /= null then
        EI.retire_deferred
          (self.executor.all, self.slots(index).identity_value);
      end if;

      if self.shared_admission /= null then
        A.release_request (self.shared_admission.all);
      end if;

      release_slot (self, Positive(index));
    end loop;

    if self.active_requests = 0 and then
       not self.close_requested and then
       not self.shutdown_requested and then
       self.idle_timer = Clair.Event_Loop.NULL_SOURCE
    then
      status := arm_idle_timer (self);
      if status /= Clair.Status.OK then
        return status;
      end if;
    end if;

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
       self.pending_control = No_Pending_Control and then
       pending_output_bytes (self) = 0 and then
       self.inflight_jobs = 0 and then
       not self.deferred_active and then
       self.application_batch_length = 0
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

    function contain_watch_failure
      (failure_status : Clair.Status.Code) return Clair.Status.Code
    is
      cleanup_status : constant Clair.Status.Code := close_owned (self);
    begin
      if cleanup_status /= Clair.Status.OK then
        report_diagnostic
          (self, D.System_Error, cleanup_status,
           "connection cleanup after watch failure");
      end if;

      return failure_status;
    end contain_watch_failure;
  begin
    if not connection_active (self) then
      return Clair.Status.OK;
    end if;

    status := settle_connection (self);
    if status /= Clair.Status.OK or else not connection_active (self) then
      return status;
    end if;

    status := flush_pending_control (self);
    if status /= Clair.Status.OK or else not connection_active (self) then
      return status;
    end if;

    update_backpressure (self);

    if self.application_paused then
      status := process_paused_probe (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        return status;
      end if;
    end if;

    if not self.shutdown_requested and then
       not self.read_paused and then
       self.pending_control = No_Pending_Control and then
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
         self.pending_control /= No_Pending_Control or else
         pending_output_bytes(self) > 0
      then
        if self.watch_active then
          status := Clair.Event_Loop.remove
            (self.event_loop.all, self.watch);
          if status /= Clair.Status.OK then
            return contain_watch_failure (status);
          end if;
          self.watch_active := False;
        end if;

        return Clair.Status.OK;
      end if;

      return close_owned (self);
    end if;

    if self.watch_active then
      status := Clair.Event_Loop.modify_watch
        (self.event_loop.all, self.watch, events);
      if status /= Clair.Status.OK then
        return contain_watch_failure (status);
      end if;
      return Clair.Status.OK;
    end if;

    status := Clair.Event_Loop.add_watch
      (self    => self.event_loop.all,
       fd      => self.fd,
       events           => events,
       callback         => io_callback'Access,
       callback_context => self.io_handler'Address,
       source           => self.watch);

    if status /= Clair.Status.OK then
      return contain_watch_failure (status);
    end if;

    self.watch_active := True;
    return Clair.Status.OK;
  end refresh_watch;

  function drain_output (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;

    function source_length (source : Natural) return Natural is
    begin
      if source = 0 then
        return pending_control_output(self);
      end if;

      if self.slots(source) = null or else not self.slots(source).in_use then
        return 0;
      end if;

      return pending_slot_output(self.slots(source).all);
    end source_length;

    function source_byte
      (source : Natural;
       index  : Positive) return P.Byte
    is
    begin
      if source = 0 then
        return self.control_bytes(self.control_consumed + index);
      end if;

      return buffered_byte (self.slots(source).response, index);
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

      if self.slot_order_count = 0 then
        return NO_OUTPUT_SOURCE;
      end if;

      for offset in 0 .. self.slot_order_count - 1 loop
        declare
          position : constant Positive :=
            ((self.next_output_position - 1 + offset) mod
             self.slot_order_count) + 1;
        begin
          candidate := Positive(self.slot_order(position));
        end;

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
    sent      : System.Storage_Elements.Storage_Count;
  begin
    if self.write_scratch = null then
      return Clair.Status.INVALID_STATE;
    end if;

    for attempt in 1 .. MAX_WRITES_PER_CALLBACK loop
      pragma Unreferenced (attempt);
      exit when self.output_budget_remaining = 0;

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
      count := Natural'Min (count, self.output_budget_remaining);

      for index in 1 .. count loop
        self.write_scratch(System.Storage_Elements.Storage_Offset(index)) :=
          System.Storage_Elements.Storage_Element
            (source_byte(source_id, index));
      end loop;

      status := Clair.Unix.Network.send
        (fd     => self.fd,
         buffer => self.write_scratch
           (1 .. System.Storage_Elements.Storage_Offset(count)),
         sent   => sent);

      if status = Clair.Status.OK then
        if sent = 0 then
          return close_owned (self);
        end if;

        if source_id = 0 then
          advance_control_output (self, Natural(sent));
        else
          advance_slot_output (self, Positive(source_id), Natural(sent));
        end if;

        self.output_record_remaining :=
          self.output_record_remaining - Natural(sent);
        self.output_budget_remaining :=
          self.output_budget_remaining - Natural(sent);

        if self.output_record_remaining = 0 then
          if source_id > 0 then
            if self.slots(source_id).active_position = 0 or else
               self.slots(source_id).active_position > self.slot_order_count
            then
              raise Program_Error with "output source missing from active index";
            end if;
            self.next_output_position :=
              (self.slots(source_id).active_position mod
               self.slot_order_count) + 1;
          end if;

          self.output_source := NO_OUTPUT_SOURCE;
        end if;
      elsif Clair.IO.Posix.is_would_block (status) then
        exit;
      else
        return close_owned (self);
      end if;
    end loop;

    status := flush_pending_control (self);
    if status /= Clair.Status.OK or else not connection_active (self) then
      return status;
    end if;

    update_backpressure (self);

    if self.application_batch_ready then
      status := try_submit_application_batch (self);
      if status /= Clair.Status.OK then
        return status;
      end if;
    elsif self.deferred_active and then
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

  function batch_accepts_record_type
    (kind        : Application_Batch_Kind;
     record_type : P.Byte) return Boolean
  is
  begin
    case kind is
      when Parameter_Application_Batch =>
        return record_type = P.PARAMS;
      when Stdin_Application_Batch =>
        return record_type = P.STDIN;
      when Data_Application_Batch =>
        return record_type = P.DATA;
      when No_Application_Batch =>
        return False;
    end case;
  end batch_accepts_record_type;

  function next_buffered_record_requires_batch_flush
    (self : Context) return Boolean
  is
    header_bytes  : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
    record_header : P.Header;
    decode_status : C.Decode_Status;
    remaining     : Natural;
  begin
    if self.application_batch_length = 0 or else
       self.application_batch_ready or else
       self.input_length = 0
    then
      return False;
    end if;

    remaining := self.input_length - 1;
    if remaining < P.HEADER_LENGTH then
      return False;
    end if;

    for offset in 0 .. P.HEADER_LENGTH - 1 loop
      header_bytes(offset) :=
        self.input_bytes(self.input_first + 1 + offset);
    end loop;

    decode_status := C.decode_header (header_bytes, record_header);
    if decode_status /= C.Complete then
      return True;
    end if;

    return record_header.request_id = 0 or else
      record_header.request_id /=
        self.application_batch_request.request_id or else
      not batch_accepts_record_type
        (self.batch_kind, record_header.record_type);
  end next_buffered_record_requires_batch_flush;

  function reject_protocol (self : in out Context) return Clair.Status.Code is
  begin
    report_diagnostic
      (self, D.Protocol_Error, Clair.Status.INVALID_ARGUMENT,
       "FastCGI protocol error; connection closed");

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

    request_status := feed_content
      (self        => self.slots(self.current_slot).exchange,
       data        => self.stream_batch(1 .. self.stream_batch_length),
       application => self.dispatcher,
       response    => self.slots(self.current_slot).response);

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
    request_admitted  : Boolean;
    slot_index        : Natural;
    one_byte          : P.Byte_Array (1 .. 1);
    control_status    : Control_Queue_Status;
    output_before     : Natural;
    output_changed    : Boolean := False;
    status            : Clair.Status.Code;
  begin
    self.decoder_at_record_boundary := False;
    decode_status := C.feed
      (self          => self.decoder,
       value         => value,
       event         => event,
       record_header => record_header);

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
          if record_header.record_type = P.GET_VALUES then
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

        elsif record_header.record_type = P.BEGIN_REQUEST then
          if Natural(record_header.content_length) /=
               B.BEGIN_REQUEST_BODY_LENGTH
          then
            return reject_protocol (self);
          end if;

          if find_slot(self, record_header.request_id) /= 0 then
            return reject_protocol (self);
          end if;

          if self.close_requested or else
             self.active_requests >= self.max_requests_per_connection
          then
            control_status := queue_cant_mpx (self, record_header.request_id);
            case control_status is
              when Control_Queued =>
                update_backpressure (self);
              when Control_Would_Block =>
                defer_control
                  (self, Pending_Protocol_Status, record_header.request_id,
                   P.CANT_MPX_CONN);
              when Control_Impossible =>
                return close_owned (self);
            end case;

            self.skip_record := True;
          else
            request_admitted := True;
            if self.shared_admission /= null then
              request_admitted :=
                A.try_acquire_request (self.shared_admission.all);
            end if;

            if not request_admitted then
              control_status :=
                queue_overloaded (self, record_header.request_id);
              case control_status is
                when Control_Queued =>
                  update_backpressure (self);
                when Control_Would_Block =>
                  defer_control
                    (self, Pending_Protocol_Status, record_header.request_id,
                     P.OVERLOADED);
                when Control_Impossible =>
                  return close_owned (self);
              end case;
              self.skip_record := True;
            else
              status := allocate_slot
                (self, record_header.request_id, slot_index);
              if status /= Clair.Status.OK then
                if self.shared_admission /= null then
                  A.release_request (self.shared_admission.all);
                end if;
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

              self.current_slot := slot_index;
              request_status := begin_record
                (self          => self.slots(slot_index).exchange,
                 record_header => record_header,
                 response      => self.slots(slot_index).response,
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

              if self.active_requests = 1 then
                status := remove_idle_timer (self);
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
          end if;
        else
          slot_index := find_slot (self, record_header.request_id);

          if slot_index = 0 then
            self.skip_record := True;
          else
            self.current_slot := slot_index;
            request_status := begin_record
              (self          => self.slots(slot_index).exchange,
               record_header => record_header,
               response      => self.slots(slot_index).response);

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
          if self.management_record_type = P.GET_VALUES then
            PM.feed (self.management_query, value);
          end if;

        elsif not self.skip_record then
          if self.current_slot = 0 or else
             self.slots(self.current_slot) = null or else
             not self.slots(self.current_slot).in_use
          then
            return reject_protocol (self);
          end if;

          if self.slots(self.current_slot).exchange.current_record_type =
               P.STDIN or else
             self.slots(self.current_slot).exchange.current_record_type =
               P.DATA
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
            request_status := feed_content
              (self        => self.slots(self.current_slot).exchange,
               data        => one_byte,
               application => self.dispatcher,
               response    => self.slots(self.current_slot).response);

            if request_status = Parameter_Limit_Exceeded then
              status := mark_resource_limit (self, self.current_slot);
              if status /= Clair.Status.OK then
                return status;
              end if;
            elsif request_status /= Input_Progress or else
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

    if C.is_complete (self.decoder) then
      if self.management_active then
        if self.management_record_type = P.GET_VALUES then
          if not PM.at_pair_boundary(self.management_query) then
            return reject_protocol (self);
          end if;

          control_status := queue_get_values_result (self);
          if control_status = Control_Would_Block then
            defer_control (self, Pending_Get_Values_Result);
          end if;
        else
          control_status :=
            queue_unknown_type (self, self.management_record_type);
          if control_status = Control_Would_Block then
            defer_control
              (self, Pending_Unknown_Type,
               value => self.management_record_type);
          end if;
        end if;

        if control_status = Control_Impossible then
          return close_owned (self);
        elsif control_status = Control_Queued then
          output_changed := True;
          reset_management (self);
        end if;

      elsif self.skip_record and then
            self.current_slot /= 0 and then
            self.slots(self.current_slot) /= null and then
            self.slots(self.current_slot).in_use and then
            self.slots(self.current_slot).exchange.cancel_reason =
              Resource_Limit
      then
        output_before :=
          pending_slot_output(self.slots(self.current_slot).all);
        status := complete_resource_limit (self, self.current_slot);
        if status /= Clair.Status.OK then
          return status;
        end if;
        output_changed := output_changed or else
          pending_slot_output(self.slots(self.current_slot).all) /=
            output_before;

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
             P.ABORT_REQUEST
        then
          status := clear_deferred_for
            (self, self.slots(self.current_slot).identity_value);
          if status /= Clair.Status.OK then
            return status;
          end if;

          status := E.signal_cancellation
            (self.executor.all,
             self.slots(self.current_slot).identity_value,
             Peer_Abort);
          if status /= Clair.Status.OK then
            return status;
          end if;
        end if;

        if self.slots(self.current_slot).exchange.current_record_type =
             P.BEGIN_REQUEST or else
           self.slots(self.current_slot).exchange.current_record_type =
             P.ABORT_REQUEST
        then
          prepare_writer_budget (self, self.slots(self.current_slot).all);
        end if;

        output_before :=
          pending_slot_output(self.slots(self.current_slot).all);
        request_status := end_record
          (self        => self.slots(self.current_slot).exchange,
           application => self.dispatcher,
           response    => self.slots(self.current_slot).response);
        sync_slot_output (self, Positive(self.current_slot));

        if request_status /= Record_Complete and then
           request_status /= Request_Complete
        then
          return reject_protocol (self);
        end if;

        output_changed := output_changed or else
          pending_slot_output(self.slots(self.current_slot).all) /=
            output_before;

        if self.dispatch_failed then
          return reject_protocol (self);
        end if;

        if request_status = Request_Complete and then
           not self.slots(self.current_slot).exchange.keep_flag
        then
          self.close_requested := True;
        end if;
      end if;

      if self.application_batch_length > 0 and then
         not self.application_batch_ready and then
         next_buffered_record_requires_batch_flush(self)
      then
        self.application_batch_flush_requested := True;
      end if;

      self.skip_record := False;
      self.current_slot := 0;
      self.decoder_at_record_boundary := True;
      if output_changed then
        update_backpressure (self);
      end if;
    end if;

    if self.application_batch_flush_requested then
      status := flush_application_batch
        (self, self.application_batch_finish);
      if status /= Clair.Status.OK then
        return status;
      end if;
    end if;

    return Clair.Status.OK;
  end process_byte;

  function process_pending_input
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    while self.input_length > 0 and then
          self.input_budget_remaining > 0 and then
          not self.read_paused and then
          not self.application_paused and then
          self.pending_control = No_Pending_Control
    loop
      status := process_byte (self, self.input_bytes(self.input_first));
      if status /= Clair.Status.OK or else not connection_active (self) then
        return status;
      end if;

      self.input_length := self.input_length - 1;
      self.input_budget_remaining := self.input_budget_remaining - 1;
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

    decode_status := C.decode_header (header_bytes, record_header);
    if decode_status /= C.Complete then
      return reject_protocol (self);
    end if;

    if record_header.record_type /= P.ABORT_REQUEST then
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
      if status /= Clair.Status.OK or else not connection_active (self) then
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
    if not self.application_paused or else
       self.current_slot /= 0 or else
       not self.decoder_at_record_boundary
    then
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
        if status /= Clair.Status.OK or else not connection_active (self) then
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
      self.decoder_at_record_boundary and then
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
    if status /= Clair.Status.OK or else not connection_active (self) then
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
            if status /= Clair.Status.OK or else
               not connection_active (self)
            then
              return status;
            end if;
          end if;

          if self.paused_probe_is_abort and then
             self.paused_probe_length = self.paused_probe_target
          then
            status := replay_paused_probe (self);
            if status /= Clair.Status.OK or else
               not connection_active (self)
            then
              return status;
            end if;

            status := process_paused_probe (self);
            if status /= Clair.Status.OK or else
               not connection_active (self)
            then
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

  function read_input (self : in out Context) return Clair.Status.Code is
    read_count : Clair.IO.Byte_Count;
    status     : Clair.Status.Code;
  begin
    if self.input_bytes = null then
      return Clair.Status.INVALID_STATE;
    end if;

    status := process_pending_input (self);
    if status /= Clair.Status.OK or else
       not connection_active (self) or else
       self.read_paused or else
       self.application_paused or else
       self.pending_control /= No_Pending_Control
    then
      return status;
    end if;

    for attempt in 1 .. MAX_READS_PER_CALLBACK loop
      pragma Unreferenced (attempt);
      exit when self.input_budget_remaining = 0;

      status := Clair.IO.read
        (fd         => self.fd,
         buffer     => self.input_bytes(1)'Address,
         count      => Clair.IO.Byte_Count
           (Natural'Min
              (self.read_buffer_bytes, self.input_budget_remaining)),
         bytes_read => read_count);

      if status = Clair.Status.OK then
        if read_count = 0 then
          return close_owned (self);
        end if;

        self.input_first := 1;
        self.input_length := Natural(read_count);
        status := process_pending_input (self);

        if status /= Clair.Status.OK or else
           not connection_active (self) or else
           self.read_paused or else
           self.application_paused or else
           self.pending_control /= No_Pending_Control
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

  function initialize_core
    (self            : aliased in out Context;
     event_loop      : not null Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     application     : not null Application_Access;
     executor        : not null E.Context_Access;
     request_lifetime_timeout : Clair.Event_Loop.Milliseconds;
     idle_connection_timeout : Clair.Event_Loop.Milliseconds;
     admission       : A.Context_Access;
     outcome          : out Initialization_Outcome;
     diagnostics     : Fasyn.Diagnostics.Reporter_Access;
     input_limits    : Stream_Limits) return Clair.Status.Code
  is
    status                   : Clair.Status.Code;
    connection_accepted      : Boolean;
    connection_id            : Connection_Identity := NO_CONNECTION_IDENTITY;
    required_parameter_bytes : Natural;
    required_pair_bytes      : Positive;
    required_input_bytes     : Positive;
    batch_append_reserve     : Positive;
    batch_input_capacity     : Positive;
  begin
    outcome := Failed_Releasable;

    if self.lifecycle /= Reusable_State or else self.inflight_jobs /= 0 then
      return Clair.Status.INVALID_STATE;
    end if;

    if request_lifetime_timeout <= 0 or else idle_connection_timeout <= 0 then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if not E.is_accepting(executor.all) then
      return Clair.Status.INVALID_STATE;
    end if;

    if not EI.uses_event_loop(executor.all, event_loop) then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if fd = Clair.IO.INVALID_DESCRIPTOR then
      return Clair.Status.INVALID_HANDLE;
    end if;

    if self.max_request_output_bytes > self.max_connection_output_bytes or else
       self.max_request_output_bytes < MIN_REQUEST_TERMINAL_BYTES or else
       self.max_name_bytes > Natural'Last - self.max_value_bytes
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    required_parameter_bytes := self.max_name_bytes + self.max_value_bytes;
    if required_parameter_bytes > Natural'Last - 8 then
      return Clair.Status.INVALID_ARGUMENT;
    end if;
    required_pair_bytes := Positive(required_parameter_bytes + 8);
    if required_parameter_bytes > self.read_buffer_bytes then
      required_input_bytes := Positive(required_parameter_bytes);
    else
      required_input_bytes := self.read_buffer_bytes;
    end if;
    batch_append_reserve :=
      Positive'Max (required_pair_bytes, self.read_buffer_bytes);
    if required_input_bytes > Positive'Last - batch_append_reserve then
      return Clair.Status.INVALID_ARGUMENT;
    end if;
    batch_input_capacity := required_input_bytes + batch_append_reserve;

    if not EI.supports_work_limits
      (executor.all, required_input_bytes,
       self.max_request_output_bytes) or else
       not EI.supports_batch_input_bytes(executor.all, batch_input_capacity)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if admission /= null then
      connection_accepted := A.try_acquire_connection (admission.all);
      if not connection_accepted then
        outcome := Capacity_Refused;
        return Clair.Status.OK;
      end if;
      self.shared_admission := admission;
      self.admission_connection_owned := True;
    end if;

    begin
      self.input_bytes := new P.Byte_Array (1 .. self.read_buffer_bytes);
      self.stream_batch := new P.Byte_Array (1 .. self.read_buffer_bytes);
      self.application_batch := new P.Byte_Array (1 .. batch_input_capacity);
      self.deferred_name := new P.Byte_Array (1 .. self.max_name_bytes);
      self.deferred_value := new P.Byte_Array (1 .. self.max_value_bytes);
      self.deferred_data := new P.Byte_Array (1 .. self.read_buffer_bytes);
      self.write_scratch := new System.Storage_Elements.Storage_Array
        (1 .. System.Storage_Elements.Storage_Offset(self.write_chunk_bytes));
      self.application_batch_capacity := batch_input_capacity;
      self.application_batch_append_reserve := batch_append_reserve;
    exception
      when Storage_Error =>
        release_connection_buffers (self);
        release_admission (self);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    self.slot_order_count := 0;
    self.slot_tree_root := 0;
    self.next_unused_slot := 1;
    self.free_slot_head := 0;
    self.deferred_slot_head := 0;
    self.retirement_head := 0;

    status := EI.issue_connection_identity (executor.all, connection_id);
    if status /= Clair.Status.OK then
      release_admission (self);
      release_slots (self);
      release_connection_buffers (self);
      return status;
    end if;

    self.event_loop := event_loop;
    self.fd := Clair.IO.INVALID_DESCRIPTOR;
    self.application := application;
    self.executor := executor;
    self.diagnostics := diagnostics;
    self.request_lifetime_timeout := request_lifetime_timeout;
    self.idle_connection_timeout := idle_connection_timeout;
    self.input_limits := input_limits;
    self.dispatcher.owner := self'Unchecked_Access;
    self.io_handler.owner := self'Unchecked_Access;
    self.timer_handler.owner := self'Unchecked_Access;
    self.timer_handler.slot_index := 0;
    self.completion_handler.owner := self'Unchecked_Access;
    self.capacity_handler.owner := self'Unchecked_Access;
    self.connection_id := connection_id;
    self.active_requests := 0;
    self.slot_order_count := 0;
    self.slot_tree_root := 0;
    self.next_unused_slot := 1;
    self.free_slot_head := 0;
    self.deferred_slot_head := 0;
    self.retirement_head := 0;
    self.next_generation := 1;
    self.generation_exhausted := False;
    self.current_slot := 0;
    self.next_output_position := 1;
    self.output_source := NO_OUTPUT_SOURCE;
    self.output_record_remaining := 0;
    self.input_budget_remaining := 0;
    self.output_budget_remaining := 0;
    self.request_output_bytes := 0;
    self.control_length := 0;
    self.control_consumed := 0;
    self.pending_control := No_Pending_Control;
    self.pending_control_request_id := 0;
    self.pending_control_value := 0;
    self.input_first := 1;
    self.input_length := 0;
    reset_paused_probe (self);
    self.stream_batch_length := 0;
    reset_application_batch (self);
    reset_management (self);
    self.inflight_jobs := 0;
    self.read_paused := False;
    self.application_paused := False;
    self.deferred_active := False;
    self.execution_waiting := False;
    self.dispatch_failed := False;
    self.skip_record := False;
    self.close_requested := False;
    self.shutdown_requested := False;
    clear_deferred (self);
    C.reset (self.decoder);
    self.decoder_at_record_boundary := True;

    status := arm_idle_timer (self);
    if status /= Clair.Status.OK then
      release_admission (self);
      release_slots (self);
      release_connection_buffers (self);
      self.event_loop := null;
      self.application := null;
      self.executor := null;
      self.diagnostics := null;
      self.dispatcher.owner := null;
      self.io_handler.owner := null;
      self.timer_handler.owner := null;
      self.timer_handler.slot_index := 0;
      self.completion_handler.owner := null;
      self.capacity_handler.owner := null;
      self.connection_id := NO_CONNECTION_IDENTITY;
      return status;
    end if;

    status := Clair.Event_Loop.add_watch
      (self    => event_loop.all,
       fd      => fd,
       events           => Clair.Event_Loop.EVENT_INPUT,
       callback         => io_callback'Access,
       callback_context => self.io_handler'Address,
       source           => self.watch);

    if status /= Clair.Status.OK then
      declare
        failure_status : constant Clair.Status.Code := status;
        cleanup_status : constant Clair.Status.Code := remove_idle_timer (self);
      begin
        release_slots (self);
        release_connection_buffers (self);

        if self.watch /= Clair.Event_Loop.NULL_SOURCE or else
           cleanup_status /= Clair.Status.OK
        then
          -- Retain shared connection admission while Event Loop cleanup keeps
          -- a transport lifetime obligation. This keeps failure retention
          -- inside the same aggregate connection bound as active transports.
          self.application := null;
          self.executor := null;
          self.diagnostics := null;
          self.dispatcher.owner := null;
          self.completion_handler.owner := null;
          self.capacity_handler.owner := null;
          self.connection_id := NO_CONNECTION_IDENTITY;
          self.lifecycle := Finalization_Required_State;
          outcome := Cleanup_Pending;
          return failure_status;
        end if;

        release_admission (self);
        self.event_loop := null;
        self.application := null;
        self.executor := null;
        self.diagnostics := null;
        self.dispatcher.owner := null;
        self.io_handler.owner := null;
        self.timer_handler.owner := null;
        self.timer_handler.slot_index := 0;
        self.completion_handler.owner := null;
        self.capacity_handler.owner := null;
        self.connection_id := NO_CONNECTION_IDENTITY;
        return failure_status;
      end;
    end if;

    self.fd := fd;
    self.watch_active := True;
    self.lifecycle := Active_State;
    outcome := Activated;
    return Clair.Status.OK;
  end initialize_core;

  function initialize
    (self            : aliased in out Context;
     event_loop      : not null Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     application     : not null Application_Access;
     executor        : not null E.Context_Access;
     request_lifetime_timeout : Clair.Event_Loop.Milliseconds;
     idle_connection_timeout : Clair.Event_Loop.Milliseconds :=
       DEFAULT_IDLE_CONNECTION_TIMEOUT;
     admission       : not null A.Context_Access;
     outcome          : out Initialization_Outcome;
     diagnostics     : Fasyn.Diagnostics.Reporter_Access := null;
     input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS)
     return Clair.Status.Code
  is
  begin
    return initialize_core
      (self, event_loop, fd, application, executor, request_lifetime_timeout,
       idle_connection_timeout, admission, outcome, diagnostics, input_limits);
  end initialize;

  function initialize_without_shared_admission
    (self            : aliased in out Context;
     event_loop      : not null Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     application     : not null Application_Access;
     executor        : not null E.Context_Access;
     request_lifetime_timeout : Clair.Event_Loop.Milliseconds;
     idle_connection_timeout : Clair.Event_Loop.Milliseconds :=
       DEFAULT_IDLE_CONNECTION_TIMEOUT;
     outcome          : out Initialization_Outcome;
     diagnostics     : Fasyn.Diagnostics.Reporter_Access := null;
     input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS)
     return Clair.Status.Code
  is
  begin
    return initialize_core
      (self, event_loop, fd, application, executor, request_lifetime_timeout,
       idle_connection_timeout, null, outcome, diagnostics, input_limits);
  end initialize_without_shared_admission;

  function begin_shutdown
    (self : in out Context) return Clair.Status.Code
  is
    status         : Clair.Status.Code;
    request_status : Input_Status;

    procedure publish_if_active is
    begin
      if connection_active (self) then
        publish_deferred_state (self, self.inflight_jobs /= 0);
      end if;
    end publish_if_active;
  begin
    if not connection_active (self) then
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
    self.pending_control := No_Pending_Control;
    self.pending_control_request_id := 0;
    self.pending_control_value := 0;
    self.current_slot := 0;
    self.skip_record := False;
    C.reset (self.decoder);
    self.decoder_at_record_boundary := True;

    status := cancel_execution_wait (self);
    if status /= Clair.Status.OK then
      publish_if_active;
      return status;
    end if;

    reset_application_batch (self);
    clear_deferred (self);
    self.application_paused := self.inflight_jobs /= 0;

    for position in 1 .. self.slot_order_count loop
      declare
        index : constant Positive := Positive(self.slot_order(position));
      begin
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
        request_status := cancel
          (self     => self.slots(index).exchange,
           response => self.slots(index).response,
           cause    => Runtime_Shutdown);
        sync_slot_output (self, index);

        if request_status /= Request_Complete and then
           request_status /= Ignored_Inactive
        then
          return close_owned (self);
        end if;
      end;
    end loop;

    update_backpressure (self);
    status := refresh_watch (self);
    publish_if_active;
    return status;
  end begin_shutdown;

  function finalize (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if self.lifecycle /= Reusable_State then
      status := close_owned (self);
      if status /= Clair.Status.OK then
        return status;
      end if;
    end if;

    if self.inflight_jobs /= 0 then
      self.lifecycle := Finalization_Required_State;
      return Clair.Status.INVALID_STATE;
    end if;

    self.application_paused := False;
    self.event_loop := null;
    self.application := null;
    self.executor := null;
    self.diagnostics := null;
    self.dispatcher.owner := null;
    self.io_handler.owner := null;
    self.timer_handler.owner := null;
    self.timer_handler.slot_index := 0;
    self.completion_handler.owner := null;
    self.capacity_handler.owner := null;
    self.lifecycle := Reusable_State;
    return Clair.Status.OK;
  end finalize;

  function is_active (self : Context) return Boolean is
  begin
    return connection_active (self);
  end is_active;

  function is_read_paused (self : Context) return Boolean is
  begin
    return self.shutdown_requested or else
      self.read_paused or else
      self.application_paused or else
      self.pending_control /= No_Pending_Control;
  end is_read_paused;

  function active_requests (self : Context) return Natural is
  begin
    return self.active_requests;
  end active_requests;

  function pending_input_bytes (self : Context) return Natural is
  begin
    return self.input_length + self.paused_probe_length;
  end pending_input_bytes;

  function request_is_current
    (self    : Context;
     request : Identity) return Boolean
  is
  begin
    return find_slot (self, request) /= 0;
  end request_is_current;

  function handle_io
    (self   : in out Context;
     io     : Clair.Event_Loop.Source_Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code
  is
    pragma Unreferenced (io);

    status : Clair.Status.Code;

    procedure publish_if_active is
    begin
      if connection_active (self) then
        publish_deferred_state (self, self.inflight_jobs /= 0);
      end if;
    end publish_if_active;
  begin
    if not connection_active (self) or else fd /= self.fd then
      return Clair.Status.INVALID_STATE;
    end if;

    self.input_budget_remaining := INPUT_BYTES_PER_CALLBACK;
    self.output_budget_remaining := OUTPUT_BYTES_PER_CALLBACK;
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

      if status /= Clair.Status.OK or else not connection_active (self) then
        publish_if_active;
        return status;
      end if;
    end if;

    if direct_pending_output_bytes(self) > 0 and then
       has_event (events, Clair.Event_Loop.EVENT_OUTPUT)
    then
      status := drain_output (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        publish_if_active;
        return status;
      end if;
    end if;

    status := settle_connection (self);
    if status /= Clair.Status.OK or else not connection_active (self) then
      publish_if_active;
      return status;
    end if;

    update_backpressure (self);

    if not self.shutdown_requested and then
       not self.read_paused and then
       not self.application_paused and then
       self.pending_control = No_Pending_Control and then
       self.paused_probe_length > 0
    then
      status := replay_paused_probe (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        publish_if_active;
        return status;
      end if;

      status := settle_connection (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        publish_if_active;
        return status;
      end if;
    end if;

    if not self.shutdown_requested and then
       not self.read_paused and then
       not self.application_paused and then
       self.pending_control = No_Pending_Control and then
       self.input_length > 0
    then
      status := process_pending_input (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        publish_if_active;
        return status;
      end if;

      status := settle_connection (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        publish_if_active;
        return status;
      end if;
    end if;

    status := flush_collected_application_batch (self);
    if status /= Clair.Status.OK or else not connection_active (self) then
      publish_if_active;
      return status;
    end if;

    status := refresh_watch (self);
    publish_if_active;
    return status;
  end handle_io;

  function handle_capacity_available
    (self : in out Context) return Clair.Status.Code
  is
    status         : Clair.Status.Code;
    cleanup_status : Clair.Status.Code;

    procedure publish_if_active is
    begin
      if connection_active (self) then
        publish_deferred_state (self, self.inflight_jobs /= 0);
      end if;
    end publish_if_active;
  begin
    if not self.execution_waiting then
      return Clair.Status.INVALID_STATE;
    end if;

    self.execution_waiting := False;
    if not connection_active (self) then
      return Clair.Status.INVALID_STATE;
    end if;

    mark_deferred_busy (self);
    if self.application_batch_ready then
      status := try_submit_application_batch (self);
    elsif self.deferred_active then
      status := try_submit_deferred (self);
    else
      status := Clair.Status.INVALID_STATE;
    end if;
    if status /= Clair.Status.OK then
      cleanup_status := close_owned (self);
      if cleanup_status /= Clair.Status.OK then
        return cleanup_status;
      end if;
      return status;
    end if;

    status := refresh_watch (self);
    publish_if_active;
    return status;
  end handle_capacity_available;

  function handle_timer
    (self       : in out Context;
     timer      : Clair.Event_Loop.Source_Handle;
     slot_index : Natural) return Clair.Status.Code
  is
    status         : Clair.Status.Code;
    request_status : Input_Status;
    request        : Identity;

    procedure publish_if_active is
    begin
      if connection_active (self) then
        publish_deferred_state (self, self.inflight_jobs /= 0);
      end if;
    end publish_if_active;
  begin
    if connection_active (self) then
      mark_deferred_busy (self);
    end if;

    if not connection_active (self) then
      return Clair.Status.INVALID_STATE;
    end if;

    if slot_index = 0 then
      if timer /= self.idle_timer then
        return Clair.Status.INVALID_STATE;
      end if;

      status := remove_idle_timer (self);
      if status /= Clair.Status.OK then
        publish_if_active;
        return status;
      end if;

      if self.active_requests /= 0 then
        publish_if_active;
        return Clair.Status.INVALID_STATE;
      end if;

      return close_owned (self);
    end if;

    if slot_index > self.slot_capacity or else
       self.slots(slot_index) = null or else
       not self.slots(slot_index).in_use or else
       self.slots(slot_index).timeout_timer /= timer or else
       self.slots(slot_index).timeout_handler.slot_index /= slot_index
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
    request_status := cancel
      (self     => self.slots(slot_index).exchange,
       response => self.slots(slot_index).response,
       cause    => Request_Timeout);
    sync_slot_output (self, Positive(slot_index));

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
  end handle_timer;

  function handle_completion
    (self            : in out Context;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
    request      : constant Identity := E.completion_request (item);
    slot_index   : Natural;
    output_count  : constant Natural := E.output_length (item);
    delivery_final : constant Boolean := E.delivery_complete (item);
    completion_write_status : Write_Status;
    status       : Clair.Status.Code;

    procedure append_output (slot : Positive) is
      connection_pending : Natural;
    begin
      connection_pending := pending_output_bytes (self);

      if self.slots(slot).response.length >
           self.slots(slot).response.max_output_bytes or else
         output_count >
           self.slots(slot).response.max_output_bytes -
             self.slots(slot).response.length or else
         connection_pending > self.max_connection_output_bytes or else
         output_count > self.max_connection_output_bytes - connection_pending
      then
        raise Program_Error with "execution output reservation violated";
      end if;

      for index in 1 .. output_count loop
        append_buffered_byte
          (self.slots(slot).response, E.output_byte(item, index));
      end loop;
      sync_slot_output (self, slot);
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
        completion_write_status := finish
          (self.slots(slot).response, E.deferred_application_status(item));
        if completion_write_status /= Write_Complete then
          raise Program_Error with "deferred completion reservation violated";
        end if;
        sync_slot_output (self, slot);
        return;
      end if;

      while offset < total loop
        count := Natural'Min (EI.deferred_output_chunk_bytes, total - offset);
        declare
          buffer : P.Byte_Array (1 .. count);
        begin
          copied := E.copy_deferred_data (item, offset, buffer);
          if copied /= count then
            raise Program_Error with "deferred payload copy invariant violated";
          end if;

          if kind = E.Deferred_Stdout_Output then
            completion_write_status :=
              write_stdout (self.slots(slot).response, buffer);
          else
            completion_write_status :=
              write_stderr (self.slots(slot).response, buffer);
          end if;

          if completion_write_status /= Write_Complete then
            raise Program_Error with "deferred output reservation violated";
          end if;
        end;
        offset := offset + count;
      end loop;
      sync_slot_output (self, slot);
    end apply_deferred_output;
  begin
    if E.is_deferred_output(item) then
      if callback_status /= Clair.Status.OK then
        return Clair.Status.CALLBACK_FAILED;
      end if;

      if not connection_active (self) then
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
        queue_retirement_if_ready (self, Positive(slot_index));
        EI.retire_deferred (self.executor.all, request);
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

    self.input_budget_remaining := INPUT_BYTES_PER_CALLBACK;
    mark_deferred_busy (self);
    if delivery_final then
      self.inflight_jobs := 0;
    end if;

    if not connection_active (self) then
      if delivery_final then
        self.application_paused := False;
      end if;
      return Clair.Status.OK;
    end if;

    slot_index := find_slot (self, request);

    if slot_index /= 0 and then
       self.slots(slot_index).exchange.cancel_reason = Not_Cancelled and then
       not self.slots(slot_index).exchange.complete_flag
    then
      if callback_status /= Clair.Status.OK or else E.output_failed(item) then
        if not delivery_final then
          raise Program_Error with
            "failed completion delivered as partial slice";
        end if;
        EI.retire_deferred (self.executor.all, request);
        self.slots(slot_index).response.deferred := False;
        prepare_writer_budget (self, self.slots(slot_index).all);
        completion_write_status :=
          finish (self.slots(slot_index).response, 1);
        sync_slot_output (self, Positive(slot_index));

        if completion_write_status /= Write_Complete then
          return close_owned (self);
        end if;

        self.slots(slot_index).exchange.active := False;
        self.slots(slot_index).exchange.complete_flag := True;
        queue_retirement_if_ready (self, Positive(slot_index));
      else
        append_output (Positive(slot_index));

        if delivery_final then
          if E.output_finished(item) then
            self.slots(slot_index).response.finished := True;
            self.slots(slot_index).exchange.active := False;
            self.slots(slot_index).exchange.complete_flag := True;
            queue_retirement_if_ready (self, Positive(slot_index));
            EI.retire_deferred (self.executor.all, request);
          elsif EI.deferred_requested(self.executor.all, request) then
            status := EI.activate_deferred
              (self               => self.executor.all,
               request            => request,
               request_pending    =>
                 pending_slot_output(self.slots(slot_index).all),
               request_limit      =>
                 self.slots(slot_index).response.max_output_bytes,
               connection_pending => direct_pending_output_bytes(self),
               connection_limit   => self.max_connection_output_bytes);
            if status /= Clair.Status.OK then
              return close_owned (self);
            end if;
            mark_slot_deferred (self, Positive(slot_index));
          end if;
        end if;
      end if;

      if self.slots(slot_index).exchange.complete_flag and then
         not self.slots(slot_index).exchange.keep_flag
      then
        self.close_requested := True;
      end if;
    elsif delivery_final then
      EI.retire_deferred (self.executor.all, request);
    end if;

    if not delivery_final then
      update_backpressure (self);
      publish_deferred_state (self, True);
      return refresh_watch (self);
    end if;

    self.application_paused := False;
    update_backpressure (self);

    if not self.read_paused and then self.paused_probe_length > 0 then
      status := replay_paused_probe (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        if connection_active (self) then
          publish_deferred_state (self, self.inflight_jobs /= 0);
        end if;
        return status;
      end if;
    end if;

    if not self.read_paused and then self.input_length > 0 then
      status := process_pending_input (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        if connection_active (self) then
          publish_deferred_state (self, self.inflight_jobs /= 0);
        end if;
        return status;
      end if;
    end if;

    if connection_active (self) then
      status := flush_collected_application_batch (self);
      if status /= Clair.Status.OK or else not connection_active (self) then
        if connection_active (self) then
          publish_deferred_state (self, self.inflight_jobs /= 0);
        end if;
        return status;
      end if;

      publish_deferred_state (self, self.inflight_jobs /= 0);
      status := refresh_watch (self);
      return status;
    end if;

    return Clair.Status.OK;
  end handle_completion;

  function on_io
    (self   : in out IO_Adapter;
     io     : Clair.Event_Loop.Source_Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code
  is
  begin
    if self.owner = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return handle_io (self.owner.all, io, fd, events);
  end on_io;

  function on_timer
    (self  : in out Timer_Adapter;
     timer : Clair.Event_Loop.Source_Handle) return Clair.Status.Code
  is
  begin
    if self.owner = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return handle_timer (self.owner.all, timer, self.slot_index);
  end on_timer;

  overriding function on_completion
    (self            : in out Completion_Adapter;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
  begin
    if self.owner = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return handle_completion (self.owner.all, item, callback_status);
  end on_completion;

  overriding function on_capacity_available
    (self : in out Capacity_Adapter) return Clair.Status.Code
  is
  begin
    if self.owner = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return handle_capacity_available (self.owner.all);
  end on_capacity_available;

end Fasyn.Request.Connection;
