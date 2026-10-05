-- ============================================================================
-- fasyn-request-connection-testing.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================

package body Fasyn.Request.Connection.Testing is

  function initialize_without_shared_admission
    (self            : aliased in out Context;
     event_loop      : not null Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     application     : not null Application_Access;
     executor        : not null Fasyn.Request.Execution.Context_Access;
     request_lifetime_timeout : Clair.Event_Loop.Milliseconds;
     idle_connection_timeout : Clair.Event_Loop.Milliseconds :=
       DEFAULT_IDLE_CONNECTION_TIMEOUT;
     diagnostics     : Fasyn.Diagnostics.Reporter_Access := null;
     input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS)
  return Clair.Status.Code
  is
    outcome : Initialization_Outcome;
  begin
    return Fasyn.Request.Connection.initialize_without_shared_admission
      (self, event_loop, fd, application, executor, request_lifetime_timeout,
       idle_connection_timeout, outcome, diagnostics, input_limits);
  end initialize_without_shared_admission;

  package P renames Fasyn.Protocol;
  use type Clair.Event_Loop.Source_Handle;
  use type P.Request_Id;

  function current_identity
    (self       : Context;
     request_id : P.Request_Id) return Identity
  is
  begin
    if request_id = 0 then
      return NULL_IDENTITY;
    end if;

    for index in 1 .. self.slot_capacity loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).identity_value.request_id = request_id
      then
        return self.slots(index).identity_value;
      end if;
    end loop;

    return NULL_IDENTITY;
  end current_identity;

  function current_cancellation_reason
    (self       : Context;
     request_id : P.Request_Id) return Cancellation_Cause
  is
  begin
    if request_id = 0 then
      return Not_Cancelled;
    end if;

    for index in 1 .. self.slot_capacity loop
      if self.slots(index) /= null and then
         self.slots(index).in_use and then
         self.slots(index).identity_value.request_id = request_id
      then
        return cancellation_reason (self.slots(index).exchange);
      end if;
    end loop;

    return Not_Cancelled;
  end current_cancellation_reason;

  function slot_index_consistent (self : Context) return Boolean is
    active_count   : Natural := 0;
    tree_count     : Natural := 0;
    free_count     : Natural := 0;
    deferred_count   : Natural := 0;
    retirement_count : Natural := 0;
    ready_count      : Natural := 0;
    index            : Natural;
    previous       : Natural := 0;
    tree_height    : Natural := 0;

    function validate_tree
      (node            : Natural;
       parent          : Natural;
       lower_exclusive : Integer;
       upper_exclusive : Integer;
       count           : in out Natural;
       height          : out Natural) return Boolean
    is
      request_value : Integer;
      left_height   : Natural;
      right_height  : Natural;
      expected      : Natural;
    begin
      if node = 0 then
        height := 0;
        return True;
      end if;

      if node > self.slot_capacity or else self.slots(node) = null or else
         not self.slots(node).in_use or else
         self.slots(node).tree_parent /= parent
      then
        height := 0;
        return False;
      end if;

      request_value :=
        Integer(self.slots(node).identity_value.request_id);
      if request_value <= lower_exclusive or else
         request_value >= upper_exclusive
      then
        height := 0;
        return False;
      end if;

      count := count + 1;
      if count > self.slot_order_count then
        height := 0;
        return False;
      end if;

      if not validate_tree
        (self.slots(node).tree_left, node, lower_exclusive, request_value,
         count, left_height)
      then
        height := 0;
        return False;
      end if;

      if not validate_tree
        (self.slots(node).tree_right, node, request_value, upper_exclusive,
         count, right_height)
      then
        height := 0;
        return False;
      end if;

      expected := Natural'Max(left_height, right_height) + 1;
      if self.slots(node).tree_height /= expected or else
         abs (Integer(left_height) - Integer(right_height)) > 1
      then
        height := 0;
        return False;
      end if;

      height := expected;
      return True;
    end validate_tree;
  begin
    if self.slot_capacity = 0 then
      return self.slots = null and then self.slot_order = null and then
        self.slot_order_count = 0 and then self.slot_tree_root = 0 and then
        self.active_requests = 0 and then self.next_unused_slot = 1 and then
        self.free_slot_head = 0 and then self.deferred_slot_head = 0 and then
        self.retirement_head = 0;
    end if;

    if self.slots = null or else self.slot_order = null or else
       self.slot_order_count /= self.active_requests
    then
      return False;
    end if;

    for position in 1 .. self.slot_order_count loop
      index := self.slot_order(position);
      if index = 0 or else index > self.slot_capacity or else
         self.slots(index) = null or else not self.slots(index).in_use or else
         self.slots(index).active_position /= position
      then
        return False;
      end if;
    end loop;

    for slot in 1 .. self.slot_capacity loop
      if self.slots(slot) /= null then
        if self.slots(slot).in_use then
          active_count := active_count + 1;
          if self.slots(slot).active_position = 0 or else
             self.slots(slot).active_position > self.slot_order_count or else
             self.slot_order(self.slots(slot).active_position) /= slot
          then
            return False;
          end if;

          if self.slots(slot).retirement_ready then
            ready_count := ready_count + 1;
            if not self.slots(slot).exchange.complete_flag or else
               self.slots(slot).response.length /= 0
            then
              return False;
            end if;
          elsif self.slots(slot).retirement_next /= 0 or else
                (self.slots(slot).exchange.complete_flag and then
                 self.slots(slot).response.length = 0)
          then
            return False;
          end if;
        elsif self.slots(slot).active_position /= 0 or else
              self.slots(slot).tree_parent /= 0 or else
              self.slots(slot).tree_left /= 0 or else
              self.slots(slot).tree_right /= 0 or else
              self.slots(slot).tree_height /= 1 or else
              self.slots(slot).retirement_ready or else
              self.slots(slot).retirement_next /= 0
        then
          return False;
        end if;
      end if;
    end loop;
    if active_count /= self.slot_order_count then
      return False;
    end if;

    if self.slot_tree_root = 0 then
      if active_count /= 0 then
        return False;
      end if;
    elsif not validate_tree
      (self.slot_tree_root, 0, -1, 65_536, tree_count, tree_height)
    then
      return False;
    end if;
    if tree_count /= active_count then
      return False;
    end if;

    index := self.free_slot_head;
    while index /= 0 loop
      free_count := free_count + 1;
      if free_count > self.slot_capacity or else
         index > self.slot_capacity or else
         self.slots(index) = null or else self.slots(index).in_use
      then
        return False;
      end if;
      index := self.slots(index).free_next;
    end loop;
    if active_count + free_count /= self.next_unused_slot - 1 then
      return False;
    end if;

    index := self.deferred_slot_head;
    while index /= 0 loop
      deferred_count := deferred_count + 1;
      if deferred_count > active_count or else
         index > self.slot_capacity or else
         self.slots(index) = null or else not self.slots(index).in_use or else
         not self.slots(index).application_deferred or else
         self.slots(index).deferred_previous /= previous
      then
        return False;
      end if;
      previous := index;
      index := self.slots(index).deferred_next;
    end loop;

    index := self.retirement_head;
    while index /= 0 loop
      retirement_count := retirement_count + 1;
      if retirement_count > ready_count or else
         index > self.slot_capacity or else
         self.slots(index) = null or else not self.slots(index).in_use or else
         not self.slots(index).retirement_ready or else
         not self.slots(index).exchange.complete_flag or else
         self.slots(index).response.length /= 0
      then
        return False;
      end if;
      index := self.slots(index).retirement_next;
    end loop;

    return retirement_count = ready_count;
  end slot_index_consistent;

  function output_accounting_consistent (self : Context) return Boolean is
    total : Natural := 0;
  begin
    for index in 1 .. self.slot_capacity loop
      if self.slots(index) /= null then
        if self.slots(index).response.length /=
             self.slots(index).accounted_output_bytes
        then
          return False;
        end if;

        if not self.slots(index).in_use and then
           self.slots(index).response.length /= 0
        then
          return False;
        end if;

        if self.slots(index).response.length > Natural'Last - total then
          return False;
        end if;
        total := total + self.slots(index).response.length;
      end if;
    end loop;

    return total = self.request_output_bytes;
  end output_accounting_consistent;

  function allocated_slot_count (self : Context) return Natural is
  begin
    return self.next_unused_slot - 1;
  end allocated_slot_count;

  function slot_storage_capacity (self : Context) return Natural is
  begin
    return self.slot_capacity;
  end slot_storage_capacity;

  function input_dispatch_bytes (self : Context) return Natural is
  begin
    return INPUT_BYTES_PER_CALLBACK - self.input_budget_remaining;
  end input_dispatch_bytes;

  function output_dispatch_bytes (self : Context) return Natural is
  begin
    return OUTPUT_BYTES_PER_CALLBACK - self.output_budget_remaining;
  end output_dispatch_bytes;

  function input_dispatch_budget return Positive is
  begin
    return INPUT_BYTES_PER_CALLBACK;
  end input_dispatch_budget;

  function output_dispatch_budget return Positive is
  begin
    return OUTPUT_BYTES_PER_CALLBACK;
  end output_dispatch_budget;

  function request_timer_count (self : Context) return Natural is
    count : Natural := 0;
  begin
    for index in 1 .. self.slot_capacity loop
      if self.slots(index) /= null and then
         self.slots(index).timeout_timer /= Clair.Event_Loop.NULL_SOURCE
      then
        count := count + 1;
      end if;
    end loop;
    return count;
  end request_timer_count;

  function idle_timer_active (self : Context) return Boolean is
  begin
    return self.idle_timer /= Clair.Event_Loop.NULL_SOURCE;
  end idle_timer_active;

  function finalization_required (self : Context) return Boolean is
  begin
    return self.lifecycle = Finalization_Required_State;
  end finalization_required;

  procedure seed_next_generation
    (self : in out Context; value : Generation)
  is
  begin
    if value = NO_GENERATION then
      raise Program_Error with "test request generation must be nonzero";
    end if;
    self.next_generation := value;
    self.generation_exhausted := False;
  end seed_next_generation;

  procedure seed_pending_input
    (self : in out Context; data : Fasyn.Protocol.Byte_Array)
  is
  begin
    if self.input_bytes = null or else data'length > self.read_buffer_bytes then
      raise Program_Error with "test input exceeds connection buffer";
    end if;
    self.input_first := 1;
    self.input_length := data'length;
    for index in 1 .. data'length loop
      self.input_bytes(index) := data(data'first + index - 1);
    end loop;
  end seed_pending_input;

  function dispatch_io
    (self   : in out Context;
     io     : Clair.Event_Loop.Source_Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code
  is
  begin
    return on_io (self.io_handler, io, fd, events);
  end dispatch_io;

end Fasyn.Request.Connection.Testing;
