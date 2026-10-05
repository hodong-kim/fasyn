-- ============================================================================
-- fasyn-request-execution.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Unchecked_Deallocation;
with Ada.Unchecked_Conversion;
with Clair.Event_Loop.Notification;
with Fasyn.Protocol.Bodies;
with System;

package body Fasyn.Request.Execution is

  package P renames Fasyn.Protocol;
  package B renames Fasyn.Protocol.Bodies;

  use type Clair.Event_Loop.Context_Access;
  use type Clair.Event_Loop.Source_Handle;
  use type Clair.Status.Code;
  use type P.Request_Id;
  use type Fasyn.Protocol.Role;
  use type Interfaces.Unsigned_8;
  use type Interfaces.Unsigned_32;
  use type Interfaces.Unsigned_64;
  use type System.Address;

  type Notification_Adapter_Access is access all Notification_Adapter;
  function address_to_notification_adapter is new Ada.Unchecked_Conversion
    (System.Address, Notification_Adapter_Access);

  function notification_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     context : System.Address) return Clair.Status.Code
  with Convention => C;

  function notification_callback
    (source  : access constant Clair.Event_Loop.Source_Handle;
     context : System.Address) return Clair.Status.Code
  is
    adapter : constant Notification_Adapter_Access :=
      address_to_notification_adapter (context);
  begin
    if adapter = null or else source = null then
      return Clair.Status.INVALID_STATE;
    end if;
    return on_notification (adapter.all, source.all);
  exception
    when others =>
      return Clair.Status.CALLBACK_FAILED;
  end notification_callback;

  MAX_ITEMS_PER_NOTIFICATION : constant Positive := 64;

  subtype Deferred_Writable_Epoch is Interfaces.Unsigned_64;
  INITIAL_WRITABLE_EPOCH : constant Deferred_Writable_Epoch := 1;

  procedure Free_Admission is new Ada.Unchecked_Deallocation
    (Object => Admission_State,
     Name   => Admission_State_Access);

  procedure Free_Work_Item is new Ada.Unchecked_Deallocation
    (Object => Work_Item,
     Name   => Work_Item_Access);

  type Deferred_Entry_State is
    (Deferred_Empty, Deferred_Pending, Deferred_Active, Deferred_Retired);

  type Deferred_Entry is record
    request            : Identity := NULL_IDENTITY;
    state              : Deferred_Entry_State := Deferred_Empty;
    cause              : Cancellation_Cause := Not_Cancelled;
    handler            : Completion_Handler_Access := null;
    request_pending    : Natural := 0;
    request_limit      : Positive := 1;
    connection_index   : Natural := 0;
    handle_present     : Boolean := False;
    command_pending    : Boolean := False;
    terminal_pending   : Boolean := False;
    processing         : Boolean := False;
    command_item       : Work_Item_Access := null;
    encoded_bytes      : Natural := 0;
    command_previous   : Natural := 0;
    command_next       : Natural := 0;
    writable_epoch     : Deferred_Writable_Epoch := INITIAL_WRITABLE_EPOCH;
    blocked_request_epoch    : Deferred_Writable_Epoch := 0;
    blocked_connection_epoch : Deferred_Writable_Epoch := 0;
    blocked_valid      : Boolean := False;
    writable_waiter    : Deferred_Writable_Waiter_Access := null;
    wait_previous      : Natural := 0;
    wait_next          : Natural := 0;
    wait_dispatching   : Boolean := False;
    index_position     : Natural := 0;
    index_parent       : Natural := 0;
    index_left         : Natural := 0;
    index_right        : Natural := 0;
    index_height       : Positive := 1;
    free_next          : Natural := 0;
  end record;

  type Deferred_Connection is record
    connection_id    : Connection_Identity := NO_CONNECTION_IDENTITY;
    member_count     : Natural := 0;
    direct_pending   : Natural := 0;
    connection_limit : Positive := 1;
    staged_bytes     : Natural := 0;
    busy             : Boolean := True;
    writable_epoch   : Deferred_Writable_Epoch := INITIAL_WRITABLE_EPOCH;
    command_head     : Natural := 0;
    command_tail     : Natural := 0;
    ready_previous   : Natural := 0;
    ready_next       : Natural := 0;
    ready_queued     : Boolean := False;
    wait_head        : Natural := 0;
    wait_tail        : Natural := 0;
    wait_ready_previous : Natural := 0;
    wait_ready_next  : Natural := 0;
    wait_ready_queued : Boolean := False;
    index_position   : Natural := 0;
    index_parent     : Natural := 0;
    index_left       : Natural := 0;
    index_right      : Natural := 0;
    index_height     : Positive := 1;
    free_next        : Natural := 0;
    in_use           : Boolean := False;
  end record;

  type Deferred_Command is record
    request : Identity := NULL_IDENTITY;
    item    : Work_Item_Access := null;
  end record;

  type Deferred_Entry_Array is array (Positive range <>) of Deferred_Entry;
  type Deferred_Connection_Array is
    array (Positive range <>) of Deferred_Connection;
  type Deferred_Index_Array is array (Positive range <>) of Natural;

  protected type Deferred_State
    (capacity         : Positive;
     max_output_bytes : Positive)
  is
    procedure retain;
    procedure release_reference (last : out Boolean);
    procedure release_handle
      (request : in Identity;
       last    : out Boolean);
    procedure request_defer
      (request : in Identity;
       result  : out Target_Defer_Result);
    procedure reserve_submit
      (request  : in Identity;
       encoded  : in Natural;
       terminal : in Boolean;
       status   : out Deferred_Write_Status);
    procedure abort_submit (request : in Identity);
    procedure commit_submit
      (request  : in Identity;
       item     : in Work_Item_Access;
       accepted : out Boolean);
    function cancellation_reason
      (request : Identity) return Cancellation_Cause;
    function requested (request : Identity) return Boolean;
    procedure activate
      (request            : in Identity;
       request_pending    : in Natural;
       request_limit      : in Positive;
       connection_pending : in Natural;
       connection_limit   : in Positive;
       success            : out Boolean);
    procedure bind_handler
      (request : in Identity;
       handler : in Completion_Handler_Access);
    procedure retire
      (request   : in Identity;
       cause     : in Cancellation_Cause;
       discarded : out Work_Item_Access);
    procedure shutdown;
    procedure take_retired_command
      (item      : out Work_Item_Access;
       available : out Boolean);
    procedure set_connection_busy
      (connection_id : in Connection_Identity;
       busy          : in Boolean);
    procedure sync_connection
      (connection_id : in Connection_Identity;
       pending       : in Natural);
    procedure sync_request
      (request : in Identity;
       pending : in Natural);
    function pending_for_request
      (request : Identity) return Natural;
    function pending_for_connection
      (connection_id : Connection_Identity) return Natural;
    procedure try_take
      (command : out Deferred_Command;
       success : out Boolean);
    procedure consume_processing_bytes
      (request : in Identity;
       encoded : in Natural);
    procedure finish_processing (request : in Identity);
    procedure wait_writable
      (request : in Identity;
       waiter  : not null Deferred_Writable_Waiter_Access;
       status  : out Deferred_Wait_Status);
    procedure cancel_writable_wait
      (request : in Identity;
       status  : out Deferred_Wait_Cancel_Status);
    procedure try_take_writable_waiter
      (request : out Identity;
       waiter  : out Deferred_Writable_Waiter_Access;
       success : out Boolean);
    procedure finish_writable_waiter (request : in Identity);
    function has_ready_writable_waiter return Boolean;
    function has_writable_waiter return Boolean;
    function has_ready_command return Boolean;
    function indices_consistent return Boolean;
    procedure note_signal_failure (status : in Clair.Status.Code);
    function signal_failure return Clair.Status.Code;
  private
    entries              : Deferred_Entry_Array (1 .. capacity);
    entry_order          : Deferred_Index_Array (1 .. capacity) :=
      [others => 0];
    entry_count          : Natural := 0;
    entry_tree_root      : Natural := 0;
    next_unused_entry    : Natural := 1;
    free_entry_head      : Natural := 0;
    connections          : Deferred_Connection_Array (1 .. capacity);
    connection_order     : Deferred_Index_Array (1 .. capacity) :=
      [others => 0];
    connection_count     : Natural := 0;
    connection_tree_root : Natural := 0;
    next_unused_connection : Natural := 1;
    free_connection_head : Natural := 0;
    ready_connection_head : Natural := 0;
    ready_connection_tail : Natural := 0;
    ready_wait_connection_head : Natural := 0;
    ready_wait_connection_tail : Natural := 0;
    retired_scan_index   : Natural := 1;
    writable_wait_count  : Natural := 0;
    writable_dispatch_count : Natural := 0;
    references           : Natural := 1;
    accepting            : Boolean := True;
    signal_failure_value : Clair.Status.Code := Clair.Status.OK;
  end Deferred_State;

  -- On 2026-10-04, local FreeBSD gcc16-ada 16.2.0 before revision 1 missed
  -- lock finalization for constrained protected subtypes, including this
  -- state's former record component. Retain compatibility with that build.
  -- Deallocate through the unconstrained protected type so the last target
  -- reference releases the lock and tables. See docs/workflows/testing.md
  -- for the toolchain workaround and executor memory regression.
  type Deferred_State_Access is access all Deferred_State;

  procedure Free_Deferred_State is new Ada.Unchecked_Deallocation
    (Object => Deferred_State,
     Name   => Deferred_State_Access);

  type Deferred_Target_Impl is limited new Deferred_Target with record
    state : Deferred_State_Access := null;
    signaler : aliased Clair.Event_Loop.Notification.Signaler;
    signaler_initialized : Boolean := False;
  end record;

  overriding procedure retain (self : in out Deferred_Target_Impl);
  overriding procedure release_reference
    (self : in out Deferred_Target_Impl; last : out Boolean);
  overriding procedure release_handle
    (self : in out Deferred_Target_Impl; request : in Identity;
     last : out Boolean);
  overriding procedure deallocate
    (self   : in out Deferred_Target_Impl;
     target : in out Deferred_Target_Access);
  overriding procedure request_defer
    (self : in out Deferred_Target_Impl; request : in Identity;
     result : out Target_Defer_Result);
  overriding procedure submit_deferred
    (self : in out Deferred_Target_Impl; request : in Identity;
     operation : in Deferred_Command_Kind; data : in P.Byte_Array;
     application_status : in Interfaces.Unsigned_32;
     status : out Deferred_Write_Status);
  overriding procedure cancel_deferred
    (self : in out Deferred_Target_Impl; request : in Identity;
     cause : in Cancellation_Cause);
  overriding procedure wait_deferred_writable
    (self : in out Deferred_Target_Impl; request : in Identity;
     waiter : not null Deferred_Writable_Waiter_Access;
     status : out Deferred_Wait_Status);
  overriding procedure cancel_deferred_writable_wait
    (self : in out Deferred_Target_Impl; request : in Identity;
     status : out Deferred_Wait_Cancel_Status);
  overriding function target_cancellation_reason
    (self : Deferred_Target_Impl; request : Identity)
     return Cancellation_Cause;

  type Deferred_Target_Impl_Access is access all Deferred_Target_Impl;

  procedure Free_Deferred_Target_Impl is new Ada.Unchecked_Deallocation
    (Object => Deferred_Target_Impl,
     Name   => Deferred_Target_Impl_Access);

  function encoded_stream_bytes (length : Natural) return Natural is
    chunks : Natural;
  begin
    if length = 0 then
      return 0;
    end if;

    chunks := length / DEFERRED_OUTPUT_CHUNK_BYTES;
    if length mod DEFERRED_OUTPUT_CHUNK_BYTES /= 0 then
      chunks := chunks + 1;
    end if;

    if chunks > (Natural'Last - length) / P.HEADER_LENGTH then
      return Natural'Last;
    end if;

    return length + chunks * P.HEADER_LENGTH;
  end encoded_stream_bytes;

  function encoded_finish_bytes return Natural is
  begin
    return 3 * P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH;
  end encoded_finish_bytes;

  protected body Deferred_State is

    procedure queue_ready_wait_connection (index : in Positive);

    procedure advance_writable_epoch
      (value : in out Deferred_Writable_Epoch)
    is
    begin
      if value = Deferred_Writable_Epoch'Last then
        value := INITIAL_WRITABLE_EPOCH;
      else
        value := value + 1;
      end if;
    end advance_writable_epoch;

    procedure record_would_block (index : in Positive) is
      connection_index : constant Natural := entries(index).connection_index;
    begin
      if connection_index = 0 or else
         not connections(connection_index).in_use
      then
        raise Program_Error with
          "deferred blocked write lost connection aggregate";
      end if;

      entries(index).blocked_request_epoch := entries(index).writable_epoch;
      entries(index).blocked_connection_epoch :=
        connections(connection_index).writable_epoch;
      entries(index).blocked_valid := True;
    end record_would_block;

    procedure note_request_writable_progress (index : in Positive) is
      connection_index : constant Natural := entries(index).connection_index;
    begin
      advance_writable_epoch (entries(index).writable_epoch);
      if entries(index).writable_waiter /= null and then
         connection_index /= 0 and then
         connections(connection_index).in_use and then
         not connections(connection_index).busy
      then
        queue_ready_wait_connection (Positive(connection_index));
      end if;
    end note_request_writable_progress;

    procedure note_connection_writable_progress (index : in Positive) is
    begin
      advance_writable_epoch (connections(index).writable_epoch);
      if not connections(index).busy then
        queue_ready_wait_connection (index);
      end if;
    end note_connection_writable_progress;

    function identity_less
      (left  : Identity;
       right : Identity) return Boolean
    is
    begin
      if left.connection_id /= right.connection_id then
        return left.connection_id < right.connection_id;
      elsif left.request_id /= right.request_id then
        return left.request_id < right.request_id;
      end if;
      return left.generation < right.generation;
    end identity_less;

    function entry_tree_height (index : Natural) return Natural is
    begin
      if index = 0 then
        return 0;
      end if;
      if index > capacity or else entries(index).state = Deferred_Empty then
        raise Program_Error with "deferred request tree contains empty entry";
      end if;
      return entries(index).index_height;
    end entry_tree_height;

    procedure update_entry_tree_height (index : in Positive) is
      left_height  : constant Natural := entry_tree_height(entries(index).index_left);
      right_height : constant Natural := entry_tree_height(entries(index).index_right);
    begin
      entries(index).index_height :=
        Positive(Natural'Max(left_height, right_height) + 1);
    end update_entry_tree_height;

    function entry_tree_balance (index : Positive) return Integer is
    begin
      return Integer(entry_tree_height(entries(index).index_left)) -
        Integer(entry_tree_height(entries(index).index_right));
    end entry_tree_balance;

    procedure rotate_entry_tree_left
      (index : in Positive; root : out Positive)
    is
      pivot  : constant Natural := entries(index).index_right;
      parent : constant Natural := entries(index).index_parent;
      middle : Natural;
    begin
      if pivot = 0 then
        raise Program_Error with "deferred request tree left rotation lacks child";
      end if;
      middle := entries(pivot).index_left;

      if parent = 0 then
        entry_tree_root := pivot;
      elsif entries(parent).index_left = index then
        entries(parent).index_left := pivot;
      elsif entries(parent).index_right = index then
        entries(parent).index_right := pivot;
      else
        raise Program_Error with "deferred request tree parent link mismatch";
      end if;
      entries(pivot).index_parent := parent;

      entries(pivot).index_left := index;
      entries(index).index_parent := pivot;
      entries(index).index_right := middle;
      if middle /= 0 then
        entries(middle).index_parent := index;
      end if;

      update_entry_tree_height (index);
      update_entry_tree_height (Positive(pivot));
      root := Positive(pivot);
    end rotate_entry_tree_left;

    procedure rotate_entry_tree_right
      (index : in Positive; root : out Positive)
    is
      pivot  : constant Natural := entries(index).index_left;
      parent : constant Natural := entries(index).index_parent;
      middle : Natural;
    begin
      if pivot = 0 then
        raise Program_Error with "deferred request tree right rotation lacks child";
      end if;
      middle := entries(pivot).index_right;

      if parent = 0 then
        entry_tree_root := pivot;
      elsif entries(parent).index_left = index then
        entries(parent).index_left := pivot;
      elsif entries(parent).index_right = index then
        entries(parent).index_right := pivot;
      else
        raise Program_Error with "deferred request tree parent link mismatch";
      end if;
      entries(pivot).index_parent := parent;

      entries(pivot).index_right := index;
      entries(index).index_parent := pivot;
      entries(index).index_left := middle;
      if middle /= 0 then
        entries(middle).index_parent := index;
      end if;

      update_entry_tree_height (index);
      update_entry_tree_height (Positive(pivot));
      root := Positive(pivot);
    end rotate_entry_tree_right;

    procedure rebalance_entry_tree (start : Natural) is
      current    : Natural := start;
      subtree    : Positive := 1;
      child      : Natural;
      adjustment : Integer;
    begin
      while current /= 0 loop
        update_entry_tree_height (Positive(current));
        adjustment := entry_tree_balance (Positive(current));

        if adjustment > 1 then
          child := entries(current).index_left;
          if child = 0 then
            raise Program_Error with "deferred request balance lacks left child";
          end if;
          if entry_tree_balance(Positive(child)) < 0 then
            rotate_entry_tree_left (Positive(child), subtree);
            if entries(current).index_left /= subtree then
              raise Program_Error with
                "deferred request left-child rotation mismatch";
            end if;
          end if;
          rotate_entry_tree_right (Positive(current), subtree);
        elsif adjustment < -1 then
          child := entries(current).index_right;
          if child = 0 then
            raise Program_Error with "deferred request balance lacks right child";
          end if;
          if entry_tree_balance(Positive(child)) > 0 then
            rotate_entry_tree_right (Positive(child), subtree);
            if entries(current).index_right /= subtree then
              raise Program_Error with
                "deferred request right-child rotation mismatch";
            end if;
          end if;
          rotate_entry_tree_left (Positive(current), subtree);
        else
          subtree := Positive(current);
        end if;

        current := entries(subtree).index_parent;
      end loop;
    end rebalance_entry_tree;

    function find_index (request : Identity) return Natural is
      index     : Natural := entry_tree_root;
      candidate : Identity;
    begin
      if is_null(request) then
        return 0;
      end if;

      while index /= 0 loop
        if index > capacity or else entries(index).state = Deferred_Empty then
          raise Program_Error with "deferred request tree index is inconsistent";
        end if;
        candidate := entries(index).request;
        if candidate = request then
          return index;
        elsif identity_less(request, candidate) then
          index := entries(index).index_left;
        else
          index := entries(index).index_right;
        end if;
      end loop;

      return 0;
    end find_index;

    procedure insert_entry_index (index : in Positive) is
      parent    : Natural := 0;
      current   : Natural := entry_tree_root;
      candidate : Identity;
    begin
      if entry_count = capacity or else entries(index).index_position /= 0 or else
         entries(index).index_parent /= 0 or else entries(index).index_left /= 0 or else
         entries(index).index_right /= 0
      then
        raise Program_Error with "invalid deferred request index insertion";
      end if;

      while current /= 0 loop
        parent := current;
        candidate := entries(current).request;
        if candidate = entries(index).request then
          raise Program_Error with "duplicate deferred request index";
        elsif identity_less(entries(index).request, candidate) then
          current := entries(current).index_left;
        else
          current := entries(current).index_right;
        end if;
      end loop;

      entries(index).index_parent := parent;
      entries(index).index_height := 1;
      if parent = 0 then
        entry_tree_root := index;
      elsif identity_less(entries(index).request, entries(parent).request) then
        entries(parent).index_left := index;
      else
        entries(parent).index_right := index;
      end if;

      entry_count := entry_count + 1;
      entry_order(entry_count) := index;
      entries(index).index_position := entry_count;
      rebalance_entry_tree (parent);
    end insert_entry_index;

    procedure replace_entry_tree_node
      (old_index   : in Positive;
       replacement : in Natural)
    is
      parent : constant Natural := entries(old_index).index_parent;
    begin
      if parent = 0 then
        if entry_tree_root /= old_index then
          raise Program_Error with "deferred request tree root mismatch";
        end if;
        entry_tree_root := replacement;
      elsif entries(parent).index_left = old_index then
        entries(parent).index_left := replacement;
      elsif entries(parent).index_right = old_index then
        entries(parent).index_right := replacement;
      else
        raise Program_Error with "deferred request tree replacement mismatch";
      end if;

      if replacement /= 0 then
        entries(replacement).index_parent := parent;
      end if;
    end replace_entry_tree_node;

    procedure remove_entry_index (index : in Positive) is
      left_child       : constant Natural := entries(index).index_left;
      right_child      : constant Natural := entries(index).index_right;
      rebalance_start  : Natural := 0;
      successor        : Natural;
      successor_parent : Natural;
      successor_right  : Natural;
      position          : constant Natural := entries(index).index_position;
      moved             : Natural;
    begin
      if position = 0 or else position > entry_count or else
         entry_order(position) /= index
      then
        raise Program_Error with "deferred request dense index removal mismatch";
      end if;

      if left_child = 0 then
        rebalance_start := entries(index).index_parent;
        replace_entry_tree_node (index, right_child);
      elsif right_child = 0 then
        rebalance_start := entries(index).index_parent;
        replace_entry_tree_node (index, left_child);
      else
        successor := right_child;
        while entries(successor).index_left /= 0 loop
          successor := entries(successor).index_left;
        end loop;

        if entries(successor).index_parent = index then
          replace_entry_tree_node (index, successor);
          entries(successor).index_left := left_child;
          entries(left_child).index_parent := successor;
          update_entry_tree_height (Positive(successor));
          rebalance_start := successor;
        else
          successor_parent := entries(successor).index_parent;
          successor_right := entries(successor).index_right;
          replace_entry_tree_node (Positive(successor), successor_right);
          entries(successor).index_right := right_child;
          entries(right_child).index_parent := successor;
          replace_entry_tree_node (index, successor);
          entries(successor).index_left := left_child;
          entries(left_child).index_parent := successor;
          update_entry_tree_height (Positive(successor));
          rebalance_start := successor_parent;
        end if;
      end if;

      entries(index).index_parent := 0;
      entries(index).index_left := 0;
      entries(index).index_right := 0;
      entries(index).index_height := 1;

      if rebalance_start /= 0 then
        rebalance_entry_tree (rebalance_start);
      end if;

      moved := entry_order(entry_count);
      if position < entry_count then
        entry_order(position) := moved;
        entries(moved).index_position := position;
      end if;
      entry_order(entry_count) := 0;
      entries(index).index_position := 0;
      entry_count := entry_count - 1;
    end remove_entry_index;

    procedure allocate_entry (index : out Natural) is
    begin
      if free_entry_head /= 0 then
        index := free_entry_head;
        free_entry_head := entries(index).free_next;
      elsif next_unused_entry <= capacity then
        index := next_unused_entry;
        next_unused_entry := next_unused_entry + 1;
      else
        index := 0;
        return;
      end if;
      entries(index) := (others => <>);
    end allocate_entry;

    procedure free_unindexed_entry (index : in Positive) is
    begin
      entries(index) := (others => <>);
      entries(index).free_next := free_entry_head;
      free_entry_head := index;
    end free_unindexed_entry;

    function connection_tree_height (index : Natural) return Natural is
    begin
      if index = 0 then
        return 0;
      end if;
      if index > capacity or else not connections(index).in_use then
        raise Program_Error with "deferred connection tree contains unused entry";
      end if;
      return connections(index).index_height;
    end connection_tree_height;

    procedure update_connection_tree_height (index : in Positive) is
      left_height : constant Natural :=
        connection_tree_height(connections(index).index_left);
      right_height : constant Natural :=
        connection_tree_height(connections(index).index_right);
    begin
      connections(index).index_height :=
        Positive(Natural'Max(left_height, right_height) + 1);
    end update_connection_tree_height;

    function connection_tree_balance (index : Positive) return Integer is
    begin
      return Integer(connection_tree_height(connections(index).index_left)) -
        Integer(connection_tree_height(connections(index).index_right));
    end connection_tree_balance;

    procedure rotate_connection_tree_left
      (index : in Positive; root : out Positive)
    is
      pivot  : constant Natural := connections(index).index_right;
      parent : constant Natural := connections(index).index_parent;
      middle : Natural;
    begin
      if pivot = 0 then
        raise Program_Error with "deferred connection left rotation lacks child";
      end if;
      middle := connections(pivot).index_left;

      if parent = 0 then
        connection_tree_root := pivot;
      elsif connections(parent).index_left = index then
        connections(parent).index_left := pivot;
      elsif connections(parent).index_right = index then
        connections(parent).index_right := pivot;
      else
        raise Program_Error with "deferred connection parent link mismatch";
      end if;
      connections(pivot).index_parent := parent;

      connections(pivot).index_left := index;
      connections(index).index_parent := pivot;
      connections(index).index_right := middle;
      if middle /= 0 then
        connections(middle).index_parent := index;
      end if;

      update_connection_tree_height (index);
      update_connection_tree_height (Positive(pivot));
      root := Positive(pivot);
    end rotate_connection_tree_left;

    procedure rotate_connection_tree_right
      (index : in Positive; root : out Positive)
    is
      pivot  : constant Natural := connections(index).index_left;
      parent : constant Natural := connections(index).index_parent;
      middle : Natural;
    begin
      if pivot = 0 then
        raise Program_Error with "deferred connection right rotation lacks child";
      end if;
      middle := connections(pivot).index_right;

      if parent = 0 then
        connection_tree_root := pivot;
      elsif connections(parent).index_left = index then
        connections(parent).index_left := pivot;
      elsif connections(parent).index_right = index then
        connections(parent).index_right := pivot;
      else
        raise Program_Error with "deferred connection parent link mismatch";
      end if;
      connections(pivot).index_parent := parent;

      connections(pivot).index_right := index;
      connections(index).index_parent := pivot;
      connections(index).index_left := middle;
      if middle /= 0 then
        connections(middle).index_parent := index;
      end if;

      update_connection_tree_height (index);
      update_connection_tree_height (Positive(pivot));
      root := Positive(pivot);
    end rotate_connection_tree_right;

    procedure rebalance_connection_tree (start : Natural) is
      current    : Natural := start;
      subtree    : Positive := 1;
      child      : Natural;
      adjustment : Integer;
    begin
      while current /= 0 loop
        update_connection_tree_height (Positive(current));
        adjustment := connection_tree_balance (Positive(current));

        if adjustment > 1 then
          child := connections(current).index_left;
          if child = 0 then
            raise Program_Error with "deferred connection balance lacks left child";
          end if;
          if connection_tree_balance(Positive(child)) < 0 then
            rotate_connection_tree_left (Positive(child), subtree);
            if connections(current).index_left /= subtree then
              raise Program_Error with
                "deferred connection left-child rotation mismatch";
            end if;
          end if;
          rotate_connection_tree_right (Positive(current), subtree);
        elsif adjustment < -1 then
          child := connections(current).index_right;
          if child = 0 then
            raise Program_Error with "deferred connection balance lacks right child";
          end if;
          if connection_tree_balance(Positive(child)) > 0 then
            rotate_connection_tree_right (Positive(child), subtree);
            if connections(current).index_right /= subtree then
              raise Program_Error with
                "deferred connection right-child rotation mismatch";
            end if;
          end if;
          rotate_connection_tree_left (Positive(current), subtree);
        else
          subtree := Positive(current);
        end if;

        current := connections(subtree).index_parent;
      end loop;
    end rebalance_connection_tree;

    function find_connection_index
      (connection_id : Connection_Identity) return Natural
    is
      index     : Natural := connection_tree_root;
      candidate : Connection_Identity;
    begin
      if connection_id = NO_CONNECTION_IDENTITY then
        return 0;
      end if;

      while index /= 0 loop
        if index > capacity or else not connections(index).in_use then
          raise Program_Error with "deferred connection tree index is inconsistent";
        end if;
        candidate := connections(index).connection_id;
        if candidate = connection_id then
          return index;
        elsif connection_id < candidate then
          index := connections(index).index_left;
        else
          index := connections(index).index_right;
        end if;
      end loop;

      return 0;
    end find_connection_index;

    procedure insert_connection_index (index : in Positive) is
      parent    : Natural := 0;
      current   : Natural := connection_tree_root;
      candidate : Connection_Identity;
    begin
      if connection_count = capacity or else
         connections(index).index_position /= 0 or else
         connections(index).index_parent /= 0 or else
         connections(index).index_left /= 0 or else
         connections(index).index_right /= 0
      then
        raise Program_Error with "invalid deferred connection index insertion";
      end if;

      while current /= 0 loop
        parent := current;
        candidate := connections(current).connection_id;
        if candidate = connections(index).connection_id then
          raise Program_Error with "duplicate deferred connection index";
        elsif connections(index).connection_id < candidate then
          current := connections(current).index_left;
        else
          current := connections(current).index_right;
        end if;
      end loop;

      connections(index).index_parent := parent;
      connections(index).index_height := 1;
      if parent = 0 then
        connection_tree_root := index;
      elsif connections(index).connection_id < connections(parent).connection_id then
        connections(parent).index_left := index;
      else
        connections(parent).index_right := index;
      end if;

      connection_count := connection_count + 1;
      connection_order(connection_count) := index;
      connections(index).index_position := connection_count;
      rebalance_connection_tree (parent);
    end insert_connection_index;

    procedure replace_connection_tree_node
      (old_index   : in Positive;
       replacement : in Natural)
    is
      parent : constant Natural := connections(old_index).index_parent;
    begin
      if parent = 0 then
        if connection_tree_root /= old_index then
          raise Program_Error with "deferred connection tree root mismatch";
        end if;
        connection_tree_root := replacement;
      elsif connections(parent).index_left = old_index then
        connections(parent).index_left := replacement;
      elsif connections(parent).index_right = old_index then
        connections(parent).index_right := replacement;
      else
        raise Program_Error with "deferred connection replacement mismatch";
      end if;

      if replacement /= 0 then
        connections(replacement).index_parent := parent;
      end if;
    end replace_connection_tree_node;

    procedure remove_connection_index (index : in Positive) is
      left_child       : constant Natural := connections(index).index_left;
      right_child      : constant Natural := connections(index).index_right;
      rebalance_start  : Natural := 0;
      successor        : Natural;
      successor_parent : Natural;
      successor_right  : Natural;
      position          : constant Natural := connections(index).index_position;
      moved             : Natural;
    begin
      if position = 0 or else position > connection_count or else
         connection_order(position) /= index
      then
        raise Program_Error with "deferred connection dense index removal mismatch";
      end if;

      if left_child = 0 then
        rebalance_start := connections(index).index_parent;
        replace_connection_tree_node (index, right_child);
      elsif right_child = 0 then
        rebalance_start := connections(index).index_parent;
        replace_connection_tree_node (index, left_child);
      else
        successor := right_child;
        while connections(successor).index_left /= 0 loop
          successor := connections(successor).index_left;
        end loop;

        if connections(successor).index_parent = index then
          replace_connection_tree_node (index, successor);
          connections(successor).index_left := left_child;
          connections(left_child).index_parent := successor;
          update_connection_tree_height (Positive(successor));
          rebalance_start := successor;
        else
          successor_parent := connections(successor).index_parent;
          successor_right := connections(successor).index_right;
          replace_connection_tree_node (Positive(successor), successor_right);
          connections(successor).index_right := right_child;
          connections(right_child).index_parent := successor;
          replace_connection_tree_node (index, successor);
          connections(successor).index_left := left_child;
          connections(left_child).index_parent := successor;
          update_connection_tree_height (Positive(successor));
          rebalance_start := successor_parent;
        end if;
      end if;

      connections(index).index_parent := 0;
      connections(index).index_left := 0;
      connections(index).index_right := 0;
      connections(index).index_height := 1;

      if rebalance_start /= 0 then
        rebalance_connection_tree (rebalance_start);
      end if;

      moved := connection_order(connection_count);
      if position < connection_count then
        connection_order(position) := moved;
        connections(moved).index_position := position;
      end if;
      connection_order(connection_count) := 0;
      connections(index).index_position := 0;
      connection_count := connection_count - 1;
    end remove_connection_index;

    procedure allocate_connection
      (connection_id : in Connection_Identity;
       index         : out Natural)
    is
    begin
      if free_connection_head /= 0 then
        index := free_connection_head;
        free_connection_head := connections(index).free_next;
      elsif next_unused_connection <= capacity then
        index := next_unused_connection;
        next_unused_connection := next_unused_connection + 1;
      else
        index := 0;
        return;
      end if;
      connections(index) := (others => <>);
      connections(index).connection_id := connection_id;
      connections(index).in_use := True;
      insert_connection_index (Positive(index));
    end allocate_connection;

    procedure remove_ready_connection (index : in Positive) is
      previous : constant Natural := connections(index).ready_previous;
      next     : constant Natural := connections(index).ready_next;
    begin
      if not connections(index).ready_queued then
        return;
      end if;
      if previous = 0 then
        if ready_connection_head /= index then
          raise Program_Error with "deferred ready head mismatch";
        end if;
        ready_connection_head := next;
      else
        connections(previous).ready_next := next;
      end if;
      if next = 0 then
        if ready_connection_tail /= index then
          raise Program_Error with "deferred ready tail mismatch";
        end if;
        ready_connection_tail := previous;
      else
        connections(next).ready_previous := previous;
      end if;
      connections(index).ready_previous := 0;
      connections(index).ready_next := 0;
      connections(index).ready_queued := False;
    end remove_ready_connection;

    procedure queue_ready_connection (index : in Positive) is
    begin
      if not accepting or else not connections(index).in_use or else
         connections(index).busy or else
         connections(index).command_head = 0 or else
         connections(index).ready_queued
      then
        return;
      end if;
      connections(index).ready_previous := ready_connection_tail;
      connections(index).ready_next := 0;
      connections(index).ready_queued := True;
      if ready_connection_tail = 0 then
        ready_connection_head := index;
      else
        connections(ready_connection_tail).ready_next := index;
      end if;
      ready_connection_tail := index;
    end queue_ready_connection;

    procedure remove_ready_wait_connection (index : in Positive) is
      previous : constant Natural := connections(index).wait_ready_previous;
      next     : constant Natural := connections(index).wait_ready_next;
    begin
      if not connections(index).wait_ready_queued then
        return;
      end if;
      if previous = 0 then
        if ready_wait_connection_head /= index then
          raise Program_Error with "deferred writable-ready head mismatch";
        end if;
        ready_wait_connection_head := next;
      else
        connections(previous).wait_ready_next := next;
      end if;
      if next = 0 then
        if ready_wait_connection_tail /= index then
          raise Program_Error with "deferred writable-ready tail mismatch";
        end if;
        ready_wait_connection_tail := previous;
      else
        connections(next).wait_ready_previous := previous;
      end if;
      connections(index).wait_ready_previous := 0;
      connections(index).wait_ready_next := 0;
      connections(index).wait_ready_queued := False;
    end remove_ready_wait_connection;

    procedure queue_ready_wait_connection (index : in Positive) is
    begin
      if not connections(index).in_use or else
         connections(index).wait_head = 0 or else
         connections(index).wait_ready_queued
      then
        return;
      end if;
      connections(index).wait_ready_previous := ready_wait_connection_tail;
      connections(index).wait_ready_next := 0;
      connections(index).wait_ready_queued := True;
      if ready_wait_connection_tail = 0 then
        ready_wait_connection_head := index;
      else
        connections(ready_wait_connection_tail).wait_ready_next := index;
      end if;
      ready_wait_connection_tail := index;
    end queue_ready_wait_connection;

    procedure append_writable_waiter (index : in Positive) is
      connection_index : constant Natural := entries(index).connection_index;
      tail             : Natural;
    begin
      if connection_index = 0 or else
         not connections(connection_index).in_use or else
         entries(index).writable_waiter = null or else
         entries(index).wait_previous /= 0 or else
         entries(index).wait_next /= 0
      then
        raise Program_Error with "invalid deferred writable waiter enqueue";
      end if;
      tail := connections(connection_index).wait_tail;
      entries(index).wait_previous := tail;
      if tail = 0 then
        connections(connection_index).wait_head := index;
      else
        entries(tail).wait_next := index;
      end if;
      connections(connection_index).wait_tail := index;
    end append_writable_waiter;

    procedure remove_writable_waiter (index : in Positive) is
      connection_index : constant Natural := entries(index).connection_index;
      previous         : constant Natural := entries(index).wait_previous;
      next             : constant Natural := entries(index).wait_next;
    begin
      if connection_index = 0 or else
         not connections(connection_index).in_use
      then
        raise Program_Error with "invalid deferred writable waiter removal";
      end if;
      if previous = 0 then
        if connections(connection_index).wait_head /= index then
          raise Program_Error with "deferred writable waiter head mismatch";
        end if;
        connections(connection_index).wait_head := next;
      else
        entries(previous).wait_next := next;
      end if;
      if next = 0 then
        if connections(connection_index).wait_tail /= index then
          raise Program_Error with "deferred writable waiter tail mismatch";
        end if;
        connections(connection_index).wait_tail := previous;
      else
        entries(next).wait_previous := previous;
      end if;
      entries(index).wait_previous := 0;
      entries(index).wait_next := 0;
      if connections(connection_index).wait_head = 0 then
        remove_ready_wait_connection (Positive(connection_index));
      end if;
    end remove_writable_waiter;

    procedure release_connection_if_unused (index : in Positive) is
    begin
      if connections(index).member_count /= 0 then
        return;
      end if;
      if connections(index).staged_bytes /= 0 or else
         connections(index).command_head /= 0 or else
         connections(index).command_tail /= 0 or else
         connections(index).wait_head /= 0 or else
         connections(index).wait_tail /= 0 or else
         connections(index).wait_ready_queued
      then
        raise Program_Error with "unused deferred connection owns work";
      end if;
      remove_ready_connection (index);
      remove_connection_index (index);
      connections(index) := (others => <>);
      connections(index).free_next := free_connection_head;
      free_connection_head := index;
    end release_connection_if_unused;

    procedure append_command (index : in Positive) is
      connection_index : constant Natural := entries(index).connection_index;
      tail             : Natural;
    begin
      if connection_index = 0 or else
         not connections(connection_index).in_use or else
         entries(index).command_item = null
      then
        raise Program_Error with "invalid deferred command enqueue";
      end if;
      tail := connections(connection_index).command_tail;
      entries(index).command_previous := tail;
      entries(index).command_next := 0;
      if tail = 0 then
        connections(connection_index).command_head := index;
      else
        entries(tail).command_next := index;
      end if;
      connections(connection_index).command_tail := index;
      queue_ready_connection (Positive(connection_index));
    end append_command;

    procedure remove_command (index : in Positive) is
      connection_index : constant Natural := entries(index).connection_index;
      previous         : constant Natural := entries(index).command_previous;
      next             : constant Natural := entries(index).command_next;
    begin
      if connection_index = 0 or else
         not connections(connection_index).in_use
      then
        raise Program_Error with "invalid deferred command removal";
      end if;
      if previous = 0 then
        if connections(connection_index).command_head /= index then
          raise Program_Error with "deferred command head mismatch";
        end if;
        connections(connection_index).command_head := next;
      else
        entries(previous).command_next := next;
      end if;
      if next = 0 then
        if connections(connection_index).command_tail /= index then
          raise Program_Error with "deferred command tail mismatch";
        end if;
        connections(connection_index).command_tail := previous;
      else
        entries(next).command_previous := previous;
      end if;
      entries(index).command_previous := 0;
      entries(index).command_next := 0;
      if connections(connection_index).command_head = 0 then
        remove_ready_connection (Positive(connection_index));
      end if;
    end remove_command;

    procedure remove_staged_bytes (index : in Positive) is
      connection_index : constant Natural := entries(index).connection_index;
    begin
      if entries(index).encoded_bytes = 0 then
        return;
      end if;
      if connection_index = 0 or else
         not connections(connection_index).in_use or else
         entries(index).encoded_bytes >
           connections(connection_index).staged_bytes
      then
        raise Program_Error with "deferred staged-byte accounting mismatch";
      end if;
      connections(connection_index).staged_bytes :=
        connections(connection_index).staged_bytes -
          entries(index).encoded_bytes;
    end remove_staged_bytes;

    function is_live (index : Positive) return Boolean is
    begin
      return entries(index).state = Deferred_Pending or else
        entries(index).state = Deferred_Active;
    end is_live;

    procedure clear_entry (index : Positive) is
      connection_index : constant Natural := entries(index).connection_index;
    begin
      if entries(index).command_item /= null or else
         entries(index).command_pending or else
         entries(index).processing or else
         entries(index).encoded_bytes /= 0 or else
         entries(index).command_previous /= 0 or else
         entries(index).command_next /= 0 or else
         entries(index).writable_waiter /= null or else
         entries(index).wait_previous /= 0 or else
         entries(index).wait_next /= 0 or else
         entries(index).wait_dispatching
      then
        raise Program_Error with "deferred entry cleared while owning work";
      end if;
      remove_entry_index (index);
      entries(index) := (others => <>);
      entries(index).free_next := free_entry_head;
      free_entry_head := index;
      if connection_index /= 0 then
        if not connections(connection_index).in_use or else
           connections(connection_index).member_count = 0
        then
          raise Program_Error with "deferred connection membership underflow";
        end if;
        connections(connection_index).member_count :=
          connections(connection_index).member_count - 1;
        release_connection_if_unused (Positive(connection_index));
      end if;
    end clear_entry;

    procedure retain is
    begin
      if references = Natural'Last then
        raise Program_Error with "deferred target reference overflow";
      end if;
      references := references + 1;
    end retain;

    procedure release_reference (last : out Boolean) is
    begin
      if references = 0 then
        raise Program_Error with "deferred target reference underflow";
      end if;
      references := references - 1;
      last := references = 0;
    end release_reference;

    procedure release_handle
      (request : in Identity;
       last    : out Boolean)
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 then
        if entries(index).writable_waiter /= null then
          remove_writable_waiter (Positive(index));
          entries(index).writable_waiter := null;
          entries(index).blocked_valid := False;
          if writable_wait_count = 0 then
            raise Program_Error with
              "deferred writable waiter count underflow";
          end if;
          writable_wait_count := writable_wait_count - 1;
        end if;
        entries(index).blocked_valid := False;
        entries(index).handle_present := False;
        if accepting and then entries(index).state = Deferred_Retired and then
           not entries(index).processing and then
           entries(index).command_item = null and then
           not entries(index).command_pending and then
           entries(index).writable_waiter = null and then
           not entries(index).wait_dispatching
        then
          clear_entry (Positive(index));
        end if;
      end if;
      release_reference (last);
    end release_handle;

    procedure request_defer
      (request : in Identity;
       result  : out Target_Defer_Result)
    is
      entry_index      : Natural;
      connection_index : Natural;
    begin
      if not accepting or else
         is_null(request) or else
         find_index(request) /= 0
      then
        result := Target_Defer_Not_Ready;
        return;
      end if;

      allocate_entry (entry_index);
      if entry_index = 0 then
        result := Target_Defer_Capacity_Exceeded;
        return;
      end if;

      connection_index := find_connection_index(request.connection_id);
      if connection_index = 0 then
        allocate_connection (request.connection_id, connection_index);
        if connection_index = 0 then
          free_unindexed_entry (Positive(entry_index));
          result := Target_Defer_Capacity_Exceeded;
          return;
        end if;
      end if;

      entries(entry_index).request := request;
      entries(entry_index).state := Deferred_Pending;
      entries(entry_index).handle_present := True;
      entries(entry_index).connection_index := connection_index;
      connections(connection_index).member_count :=
        connections(connection_index).member_count + 1;
      insert_entry_index (Positive(entry_index));
      result := Target_Defer_Complete;
    end request_defer;

    procedure reserve_submit
      (request  : in Identity;
       encoded  : in Natural;
       terminal : in Boolean;
       status   : out Deferred_Write_Status)
    is
      index            : constant Natural := find_index(request);
      connection_index : Natural;
      connection_use   : Natural;
    begin
      if index = 0 or else entries(index).state = Deferred_Retired or else
         entries(index).terminal_pending
      then
        status := Deferred_Closed;
        return;
      end if;

      --  One deferred write attempt supersedes the readiness token left by an
      --  earlier blocked attempt. A new token is recorded only if this attempt
      --  itself returns Deferred_Would_Block.
      entries(index).blocked_valid := False;

      connection_index := entries(index).connection_index;
      if connection_index = 0 or else
         not connections(connection_index).in_use
      then
        raise Program_Error with "deferred request lost connection aggregate";
      end if;
      if entries(index).state /= Deferred_Active or else
         entries(index).handler = null or else
         connections(connection_index).busy or else
         entries(index).command_pending or else entries(index).processing
      then
        record_would_block (Positive(index));
        status := Deferred_Would_Block;
        return;
      end if;
      if encoded > max_output_bytes or else
         encoded > entries(index).request_limit or else
         encoded > connections(connection_index).connection_limit
      then
        status := Deferred_Output_Limit_Exceeded;
        return;
      end if;
      if entries(index).request_pending > entries(index).request_limit then
        status := Deferred_Closed;
        return;
      end if;
      if encoded >
           entries(index).request_limit - entries(index).request_pending
      then
        record_would_block (Positive(index));
        status := Deferred_Would_Block;
        return;
      end if;

      connection_use := connections(connection_index).staged_bytes;
      if connections(connection_index).direct_pending >
           connections(connection_index).connection_limit or else
         connection_use >
           connections(connection_index).connection_limit -
             connections(connection_index).direct_pending or else
         encoded >
           connections(connection_index).connection_limit -
             connections(connection_index).direct_pending - connection_use
      then
        record_would_block (Positive(index));
        status := Deferred_Would_Block;
        return;
      end if;

      entries(index).encoded_bytes := encoded;
      entries(index).command_pending := True;
      entries(index).terminal_pending := terminal;
      connections(connection_index).staged_bytes := connection_use + encoded;
      status := Deferred_Write_Complete;
    end reserve_submit;

    procedure abort_submit (request : in Identity) is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then
         entries(index).command_pending and then
         entries(index).command_item = null and then
         not entries(index).processing
      then
        remove_staged_bytes (Positive(index));
        entries(index).command_pending := False;
        entries(index).terminal_pending := False;
        entries(index).encoded_bytes := 0;
      end if;
    end abort_submit;

    procedure commit_submit
      (request  : in Identity;
       item     : in Work_Item_Access;
       accepted : out Boolean)
    is
      index : constant Natural := find_index(request);
    begin
      accepted := False;
      if index /= 0 and then is_live(Positive(index)) and then
         entries(index).command_pending and then
         entries(index).command_item = null and then
         not entries(index).processing
      then
        item.completion_handler := entries(index).handler;
        entries(index).command_item := item;
        append_command (Positive(index));
        accepted := True;
      end if;
    end commit_submit;

    function cancellation_reason
      (request : Identity) return Cancellation_Cause
    is
      index : constant Natural := find_index(request);
    begin
      if index = 0 then
        return Not_Cancelled;
      end if;
      return entries(index).cause;
    end cancellation_reason;

    function requested (request : Identity) return Boolean is
      index : constant Natural := find_index(request);
    begin
      return index /= 0 and then
        (entries(index).state = Deferred_Pending or else
         entries(index).state = Deferred_Active);
    end requested;

    procedure activate
      (request            : in Identity;
       request_pending    : in Natural;
       request_limit      : in Positive;
       connection_pending : in Natural;
       connection_limit   : in Positive;
       success            : out Boolean)
    is
      index            : constant Natural := find_index(request);
      connection_index : Natural;
    begin
      if not accepting or else index = 0 or else
         entries(index).state /= Deferred_Pending or else
         request_pending > request_limit or else
         connection_pending > connection_limit
      then
        success := False;
        return;
      end if;
      connection_index := entries(index).connection_index;
      if connection_index = 0 or else
         not connections(connection_index).in_use
      then
        raise Program_Error with
          "deferred activation lost connection aggregate";
      end if;

      entries(index).request_pending := request_pending;
      entries(index).request_limit := request_limit;
      connections(connection_index).direct_pending := connection_pending;
      connections(connection_index).connection_limit := connection_limit;
      entries(index).state := Deferred_Active;
      note_request_writable_progress (Positive(index));
      success := True;
    end activate;

    procedure bind_handler
      (request : in Identity;
       handler : in Completion_Handler_Access)
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then entries(index).state = Deferred_Active then
        if entries(index).handler = null and then handler /= null then
          entries(index).handler := handler;
          note_request_writable_progress (Positive(index));
        else
          entries(index).handler := handler;
        end if;
      end if;
    end bind_handler;

    procedure retire
      (request   : in Identity;
       cause     : in Cancellation_Cause;
       discarded : out Work_Item_Access)
    is
      index : constant Natural := find_index(request);
    begin
      discarded := null;
      if index = 0 or else entries(index).state = Deferred_Retired then
        return;
      end if;

      if cause /= Not_Cancelled and then
         entries(index).cause = Not_Cancelled
      then
        entries(index).cause := cause;
      end if;
      entries(index).state := Deferred_Retired;
      entries(index).handler := null;
      entries(index).blocked_valid := False;
      if entries(index).command_pending then
        if entries(index).command_item /= null then
          remove_command (Positive(index));
        end if;
        remove_staged_bytes (Positive(index));
        discarded := entries(index).command_item;
        entries(index).command_item := null;
        entries(index).command_pending := False;
        entries(index).encoded_bytes := 0;
      end if;

      queue_ready_wait_connection
        (Positive(entries(index).connection_index));

      if accepting and then not entries(index).handle_present and then
         not entries(index).processing and then
         entries(index).writable_waiter = null and then
         not entries(index).wait_dispatching
      then
        clear_entry (Positive(index));
      end if;
    end retire;

    procedure shutdown is
      connection_index : Natural;
    begin
      accepting := False;
      ready_connection_head := 0;
      ready_connection_tail := 0;
      ready_wait_connection_head := 0;
      ready_wait_connection_tail := 0;
      retired_scan_index := 1;

      for position in 1 .. connection_count loop
        connection_index := connection_order(position);
        connections(connection_index).ready_previous := 0;
        connections(connection_index).ready_next := 0;
        connections(connection_index).ready_queued := False;
        connections(connection_index).wait_ready_previous := 0;
        connections(connection_index).wait_ready_next := 0;
        connections(connection_index).wait_ready_queued := False;
        connections(connection_index).busy := True;
      end loop;

      for index in entries'range loop
        if entries(index).state /= Deferred_Empty then
          if (entries(index).state = Deferred_Pending or else
              entries(index).state = Deferred_Active) and then
             entries(index).cause = Not_Cancelled
          then
            entries(index).cause := Runtime_Shutdown;
          end if;
          entries(index).state := Deferred_Retired;
          entries(index).handler := null;
          entries(index).blocked_valid := False;
          if entries(index).command_pending then
            if entries(index).command_item /= null then
              remove_command (index);
            end if;
            remove_staged_bytes (index);
            entries(index).command_pending := False;
            entries(index).encoded_bytes := 0;
          end if;
          if entries(index).writable_waiter /= null then
            queue_ready_wait_connection
              (Positive(entries(index).connection_index));
          end if;
        end if;
      end loop;
    end shutdown;

    procedure take_retired_command
      (item      : out Work_Item_Access;
       available : out Boolean)
    is
    begin
      item := null;
      available := False;
      while retired_scan_index <= capacity loop
        declare
          index : constant Positive := Positive(retired_scan_index);
        begin
          retired_scan_index := retired_scan_index + 1;
          if entries(index).state = Deferred_Retired and then
             entries(index).command_item /= null
          then
            item := entries(index).command_item;
            entries(index).command_item := null;
            available := True;
            return;
          end if;
        end;
      end loop;
    end take_retired_command;

    procedure set_connection_busy
      (connection_id : in Connection_Identity;
       busy          : in Boolean)
    is
      index : constant Natural := find_connection_index(connection_id);
    begin
      if index = 0 then
        return;
      end if;
      declare
        was_busy : constant Boolean := connections(index).busy;
      begin
        connections(index).busy := busy;
        if busy then
          remove_ready_connection (Positive(index));
        else
          queue_ready_connection (Positive(index));
          if was_busy then
            note_connection_writable_progress (Positive(index));
          end if;
        end if;
      end;
    end set_connection_busy;

    procedure sync_connection
      (connection_id : in Connection_Identity;
       pending       : in Natural)
    is
      index : constant Natural := find_connection_index(connection_id);
    begin
      if index /= 0 then
        if pending < connections(index).direct_pending then
          connections(index).direct_pending := pending;
          note_connection_writable_progress (Positive(index));
        else
          connections(index).direct_pending := pending;
        end if;
      end if;
    end sync_connection;

    procedure sync_request
      (request : in Identity;
       pending : in Natural)
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then is_live(Positive(index)) then
        if pending < entries(index).request_pending then
          entries(index).request_pending := pending;
          note_request_writable_progress (Positive(index));
        else
          entries(index).request_pending := pending;
        end if;
      end if;
    end sync_request;

    function pending_for_request
      (request : Identity) return Natural
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then
         (entries(index).command_pending or else entries(index).processing)
      then
        return entries(index).encoded_bytes;
      end if;
      return 0;
    end pending_for_request;

    function pending_for_connection
      (connection_id : Connection_Identity) return Natural
    is
      index : constant Natural := find_connection_index(connection_id);
    begin
      if index = 0 then
        return 0;
      end if;
      return connections(index).staged_bytes;
    end pending_for_connection;

    procedure try_take
      (command : out Deferred_Command;
       success : out Boolean)
    is
      connection_index : constant Natural := ready_connection_head;
      index            : Natural;
    begin
      command := (others => <>);
      success := False;
      if connection_index = 0 then
        return;
      end if;
      if not connections(connection_index).in_use or else
         connections(connection_index).busy or else
         connections(connection_index).command_head = 0 or else
         not connections(connection_index).ready_queued
      then
        raise Program_Error with "invalid deferred ready connection";
      end if;

      index := connections(connection_index).command_head;
      if entries(index).state /= Deferred_Active or else
         entries(index).handler = null or else
         not entries(index).command_pending or else
         entries(index).command_item = null or else
         entries(index).processing
      then
        raise Program_Error with "invalid deferred ready command";
      end if;

      remove_ready_connection (Positive(connection_index));
      remove_command (Positive(index));
      connections(connection_index).busy := True;

      command.request := entries(index).request;
      command.item := entries(index).command_item;
      entries(index).command_item := null;
      entries(index).command_pending := False;
      entries(index).processing := True;
      success := True;
    end try_take;

    procedure consume_processing_bytes
      (request : in Identity;
       encoded : in Natural)
    is
      index            : constant Natural := find_index(request);
      connection_index : Natural;
    begin
      if index = 0 or else not entries(index).processing then
        raise Program_Error with "deferred processing reservation is absent";
      end if;
      connection_index := entries(index).connection_index;
      if connection_index = 0 or else
         not connections(connection_index).in_use or else
         encoded > entries(index).encoded_bytes or else
         encoded > connections(connection_index).staged_bytes
      then
        raise Program_Error with "deferred processing reservation underflow";
      end if;

      entries(index).encoded_bytes := entries(index).encoded_bytes - encoded;
      connections(connection_index).staged_bytes :=
        connections(connection_index).staged_bytes - encoded;
    end consume_processing_bytes;

    procedure finish_processing (request : in Identity) is
      index : constant Natural := find_index(request);
    begin
      if index = 0 then
        return;
      end if;

      if entries(index).encoded_bytes /= 0 then
        if entries(index).state /= Deferred_Retired then
          raise Program_Error with
            "live deferred processing finished with reserved bytes";
        end if;
        remove_staged_bytes (Positive(index));
        entries(index).encoded_bytes := 0;
      end if;

      entries(index).processing := False;
      note_request_writable_progress (Positive(index));
      if accepting and then entries(index).state = Deferred_Retired and then
         not entries(index).handle_present and then
         entries(index).writable_waiter = null and then
         not entries(index).wait_dispatching
      then
        clear_entry (Positive(index));
      end if;
    end finish_processing;

    procedure wait_writable
      (request : in Identity;
       waiter  : not null Deferred_Writable_Waiter_Access;
       status  : out Deferred_Wait_Status)
    is
      index : constant Natural := find_index(request);
    begin
      if index = 0 or else entries(index).state = Deferred_Retired then
        status := Deferred_Wait_Closed;
        return;
      end if;
      if entries(index).writable_waiter /= null then
        if entries(index).writable_waiter = waiter then
          status := Deferred_Wait_Registered;
        else
          status := Deferred_Wait_Conflict;
        end if;
        return;
      end if;
      if not entries(index).blocked_valid then
        status := Deferred_Wait_Not_Blocked;
        return;
      end if;

      declare
        connection_index : constant Natural := entries(index).connection_index;
      begin
        if connection_index = 0 or else
           not connections(connection_index).in_use
        then
          raise Program_Error with
            "deferred writable wait lost connection aggregate";
        end if;

        if entries(index).writable_epoch /=
             entries(index).blocked_request_epoch or else
           connections(connection_index).writable_epoch /=
             entries(index).blocked_connection_epoch
        then
          entries(index).blocked_valid := False;
          status := Deferred_Wait_Ready;
          return;
        end if;
      end;

      entries(index).blocked_valid := False;
      entries(index).writable_waiter := waiter;
      append_writable_waiter (Positive(index));
      writable_wait_count := writable_wait_count + 1;
      status := Deferred_Wait_Registered;
    end wait_writable;

    procedure cancel_writable_wait
      (request : in Identity;
       status  : out Deferred_Wait_Cancel_Status)
    is
      index : constant Natural := find_index(request);
    begin
      if index = 0 then
        status := Deferred_Wait_Not_Registered;
        return;
      end if;
      if entries(index).wait_dispatching then
        status := Deferred_Wait_Dispatching;
        return;
      end if;
      if entries(index).writable_waiter = null then
        status := Deferred_Wait_Not_Registered;
        return;
      end if;

      remove_writable_waiter (Positive(index));
      entries(index).writable_waiter := null;
      entries(index).blocked_valid := False;
      if writable_wait_count = 0 then
        raise Program_Error with "deferred writable waiter count underflow";
      end if;
      writable_wait_count := writable_wait_count - 1;
      status := Deferred_Wait_Cancelled;
      if accepting and then entries(index).state = Deferred_Retired and then
         not entries(index).handle_present and then
         not entries(index).processing
      then
        clear_entry (Positive(index));
      end if;
    end cancel_writable_wait;

    procedure try_take_writable_waiter
      (request : out Identity;
       waiter  : out Deferred_Writable_Waiter_Access;
       success : out Boolean)
    is
      connection_index : constant Natural := ready_wait_connection_head;
      index            : Natural;
    begin
      request := NULL_IDENTITY;
      waiter := null;
      success := False;
      if connection_index = 0 then
        return;
      end if;
      if not connections(connection_index).in_use or else
         connections(connection_index).wait_head = 0 or else
         not connections(connection_index).wait_ready_queued
      then
        raise Program_Error with "invalid deferred writable-ready connection";
      end if;

      remove_ready_wait_connection (Positive(connection_index));
      index := connections(connection_index).wait_head;
      if entries(index).writable_waiter = null or else
         entries(index).wait_dispatching
      then
        raise Program_Error with "invalid deferred writable waiter";
      end if;
      waiter := entries(index).writable_waiter;
      request := entries(index).request;
      remove_writable_waiter (Positive(index));
      entries(index).writable_waiter := null;
      if writable_wait_count = 0 then
        raise Program_Error with "deferred writable waiter count underflow";
      end if;
      writable_wait_count := writable_wait_count - 1;
      writable_dispatch_count := writable_dispatch_count + 1;
      entries(index).wait_dispatching := True;
      if connections(connection_index).wait_head /= 0 then
        queue_ready_wait_connection (Positive(connection_index));
      end if;
      success := True;
    end try_take_writable_waiter;

    procedure finish_writable_waiter (request : in Identity) is
      index : constant Natural := find_index(request);
    begin
      if index = 0 then
        raise Program_Error with "deferred writable waiter entry disappeared";
      end if;
      if not entries(index).wait_dispatching then
        raise Program_Error with "deferred writable waiter is not dispatching";
      end if;
      entries(index).wait_dispatching := False;
      if writable_dispatch_count = 0 then
        raise Program_Error with "deferred writable dispatch count underflow";
      end if;
      writable_dispatch_count := writable_dispatch_count - 1;
      if accepting and then entries(index).state = Deferred_Retired and then
         not entries(index).handle_present and then
         not entries(index).processing and then
         entries(index).writable_waiter = null
      then
        clear_entry (Positive(index));
      end if;
    end finish_writable_waiter;

    function has_ready_writable_waiter return Boolean is
    begin
      return ready_wait_connection_head /= 0;
    end has_ready_writable_waiter;

    function has_writable_waiter return Boolean is
    begin
      return writable_wait_count /= 0 or else writable_dispatch_count /= 0;
    end has_writable_waiter;

    function has_ready_command return Boolean is
    begin
      return ready_connection_head /= 0;
    end has_ready_command;

    function indices_consistent return Boolean is
      entry_tree_count      : Natural := 0;
      connection_tree_count : Natural := 0;
      free_entry_count      : Natural := 0;
      free_connection_count : Natural := 0;
      previous_entry        : Identity := NULL_IDENTITY;
      have_previous_entry   : Boolean := False;
      previous_connection   : Connection_Identity := NO_CONNECTION_IDENTITY;
      have_previous_connection : Boolean := False;

      function validate_entry_tree
        (node   : Natural;
         parent : Natural;
         height : out Natural) return Boolean
      is
        left_height  : Natural;
        right_height : Natural;
        expected     : Natural;
      begin
        if node = 0 then
          height := 0;
          return True;
        end if;
        if node > capacity or else entries(node).state = Deferred_Empty or else
           entries(node).index_parent /= parent
        then
          height := 0;
          return False;
        end if;

        if not validate_entry_tree
          (entries(node).index_left, node, left_height)
        then
          height := 0;
          return False;
        end if;

        if have_previous_entry and then
           not identity_less(previous_entry, entries(node).request)
        then
          height := 0;
          return False;
        end if;
        previous_entry := entries(node).request;
        have_previous_entry := True;
        entry_tree_count := entry_tree_count + 1;
        if entry_tree_count > entry_count then
          height := 0;
          return False;
        end if;

        if not validate_entry_tree
          (entries(node).index_right, node, right_height)
        then
          height := 0;
          return False;
        end if;

        expected := Natural'Max(left_height, right_height) + 1;
        if entries(node).index_height /= expected or else
           abs (Integer(left_height) - Integer(right_height)) > 1
        then
          height := 0;
          return False;
        end if;
        height := expected;
        return True;
      end validate_entry_tree;

      function validate_connection_tree
        (node   : Natural;
         parent : Natural;
         height : out Natural) return Boolean
      is
        left_height  : Natural;
        right_height : Natural;
        expected     : Natural;
      begin
        if node = 0 then
          height := 0;
          return True;
        end if;
        if node > capacity or else not connections(node).in_use or else
           connections(node).index_parent /= parent
        then
          height := 0;
          return False;
        end if;

        if not validate_connection_tree
          (connections(node).index_left, node, left_height)
        then
          height := 0;
          return False;
        end if;

        if have_previous_connection and then
           not (previous_connection < connections(node).connection_id)
        then
          height := 0;
          return False;
        end if;
        previous_connection := connections(node).connection_id;
        have_previous_connection := True;
        connection_tree_count := connection_tree_count + 1;
        if connection_tree_count > connection_count then
          height := 0;
          return False;
        end if;

        if not validate_connection_tree
          (connections(node).index_right, node, right_height)
        then
          height := 0;
          return False;
        end if;

        expected := Natural'Max(left_height, right_height) + 1;
        if connections(node).index_height /= expected or else
           abs (Integer(left_height) - Integer(right_height)) > 1
        then
          height := 0;
          return False;
        end if;
        height := expected;
        return True;
      end validate_connection_tree;

      entry_height      : Natural;
      connection_height : Natural;
      index             : Natural;
      members           : Natural;
    begin
      if entry_count > capacity or else connection_count > capacity then
        return False;
      end if;

      for position in 1 .. entry_count loop
        index := entry_order(position);
        if index = 0 or else index > capacity or else
           entries(index).state = Deferred_Empty or else
           entries(index).index_position /= position
        then
          return False;
        end if;
      end loop;

      if not validate_entry_tree(entry_tree_root, 0, entry_height) or else
         entry_tree_count /= entry_count
      then
        return False;
      end if;

      for position in 1 .. connection_count loop
        index := connection_order(position);
        if index = 0 or else index > capacity or else
           not connections(index).in_use or else
           connections(index).index_position /= position
        then
          return False;
        end if;
      end loop;

      if not validate_connection_tree
        (connection_tree_root, 0, connection_height) or else
         connection_tree_count /= connection_count
      then
        return False;
      end if;

      for position in 1 .. entry_count loop
        index := entry_order(position);
        if entries(index).connection_index = 0 or else
           entries(index).connection_index > capacity or else
           not connections(entries(index).connection_index).in_use or else
           connections(entries(index).connection_index).connection_id /=
             entries(index).request.connection_id
        then
          return False;
        end if;
      end loop;

      for position in 1 .. connection_count loop
        index := connection_order(position);
        members := 0;
        for entry_position in 1 .. entry_count loop
          if entries(entry_order(entry_position)).connection_index = index then
            members := members + 1;
          end if;
        end loop;
        if members /= connections(index).member_count then
          return False;
        end if;
      end loop;

      index := free_entry_head;
      while index /= 0 loop
        free_entry_count := free_entry_count + 1;
        if free_entry_count > capacity or else index > capacity or else
           entries(index).state /= Deferred_Empty or else
           entries(index).index_position /= 0 or else
           entries(index).index_parent /= 0 or else
           entries(index).index_left /= 0 or else
           entries(index).index_right /= 0
        then
          return False;
        end if;
        index := entries(index).free_next;
      end loop;
      if entry_count + free_entry_count /= next_unused_entry - 1 then
        return False;
      end if;

      index := free_connection_head;
      while index /= 0 loop
        free_connection_count := free_connection_count + 1;
        if free_connection_count > capacity or else index > capacity or else
           connections(index).in_use or else
           connections(index).index_position /= 0 or else
           connections(index).index_parent /= 0 or else
           connections(index).index_left /= 0 or else
           connections(index).index_right /= 0
        then
          return False;
        end if;
        index := connections(index).free_next;
      end loop;
      if connection_count + free_connection_count /=
           next_unused_connection - 1
      then
        return False;
      end if;

      return True;
    end indices_consistent;

    procedure note_signal_failure (status : in Clair.Status.Code) is
    begin
      if signal_failure_value = Clair.Status.OK and then
         status /= Clair.Status.OK
      then
        signal_failure_value := status;
      end if;
    end note_signal_failure;

    function signal_failure return Clair.Status.Code is
    begin
      return signal_failure_value;
    end signal_failure;

  end Deferred_State;

  procedure retain (self : in out Deferred_Target_Impl) is
  begin
    self.state.all.retain;
  end retain;

  procedure finalize_signaler_if_last
    (self : in out Deferred_Target_Impl;
     last : in Boolean)
  is
    status : Clair.Status.Code;
  begin
    if not last or else not self.signaler_initialized then
      return;
    end if;

    status := Clair.Event_Loop.Notification.finalize (self.signaler);
    if status /= Clair.Status.OK then
      raise Program_Error with "notification signaler finalization failed";
    end if;
    self.signaler_initialized := False;
  end finalize_signaler_if_last;

  procedure release_reference
    (self : in out Deferred_Target_Impl;
     last : out Boolean)
  is
  begin
    self.state.all.release_reference (last);
    finalize_signaler_if_last (self, last);
  end release_reference;

  procedure release_handle
    (self    : in out Deferred_Target_Impl;
     request : in Identity;
     last    : out Boolean)
  is
  begin
    self.state.all.release_handle (request, last);
    finalize_signaler_if_last (self, last);
  end release_handle;

  procedure deallocate
    (self   : in out Deferred_Target_Impl;
     target : in out Deferred_Target_Access)
  is
    concrete : Deferred_Target_Impl_Access :=
      Deferred_Target_Impl_Access (target);
  begin
    pragma Assert (concrete /= null);
    pragma Assert (concrete.all'Address = self'Address);
    pragma Assert (concrete.state /= null);
    Free_Deferred_State (concrete.state);
    Free_Deferred_Target_Impl (concrete);
    target := null;
  end deallocate;

  procedure request_defer
    (self    : in out Deferred_Target_Impl;
     request : in Identity;
     result  : out Target_Defer_Result)
  is
  begin
    self.state.all.request_defer (request, result);
  end request_defer;

  procedure submit_deferred
    (self               : in out Deferred_Target_Impl;
     request            : in Identity;
     operation          : in Deferred_Command_Kind;
     data               : in P.Byte_Array;
     application_status : in Interfaces.Unsigned_32;
     status             : out Deferred_Write_Status)
  is
    encoded  : Natural;
    item     : Work_Item_Access := null;
    accepted : Boolean;
  begin
    if operation = Deferred_Finish then
      encoded := encoded_finish_bytes;
    else
      encoded := encoded_stream_bytes(data'length);
    end if;

    self.state.all.reserve_submit
      (request, encoded, operation = Deferred_Finish, status);
    if status /= Deferred_Write_Complete then
      return;
    end if;

    if encoded = 0 then
      self.state.all.abort_submit (request);
      return;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => Positive'Max (1, data'length),
         output_capacity => 1);
    exception
      when Storage_Error =>
        self.state.all.abort_submit (request);
        status := Deferred_Resource_Failed;
        return;
    end;

    item.request_value := request;
    item.data_length := data'length;
    for index in 1 .. data'length loop
      item.data_bytes(index) := data(data'first + index - 1);
    end loop;

    case operation is
      when Deferred_Stdout =>
        item.deferred_kind := Deferred_Stdout_Output;
      when Deferred_Stderr =>
        item.deferred_kind := Deferred_Stderr_Output;
      when Deferred_Finish =>
        item.deferred_kind := Deferred_Finish_Output;
    end case;
    item.deferred_status := application_status;

    self.state.all.commit_submit (request, item, accepted);
    if not accepted then
      Free_Work_Item (item);
      status := Deferred_Closed;
      return;
    end if;

    declare
      signal_status : constant Clair.Status.Code :=
        Clair.Event_Loop.Notification.signal (self.signaler);
    begin
      if signal_status /= Clair.Status.OK then
        self.state.all.note_signal_failure (signal_status);
      end if;
    end;

    status := Deferred_Write_Complete;
  end submit_deferred;

  procedure signal_deferred_waiters (self : in out Deferred_Target_Impl) is
  begin
    if self.state.all.has_ready_writable_waiter then
      declare
        signal_status : constant Clair.Status.Code :=
          Clair.Event_Loop.Notification.signal (self.signaler);
      begin
        if signal_status /= Clair.Status.OK then
          self.state.all.note_signal_failure (signal_status);
        end if;
      end;
    end if;
  end signal_deferred_waiters;

  procedure cancel_deferred
    (self    : in out Deferred_Target_Impl;
     request : in Identity;
     cause   : in Cancellation_Cause)
  is
    discarded : Work_Item_Access;
  begin
    self.state.all.retire (request, cause, discarded);
    if discarded /= null then
      Free_Work_Item (discarded);
    end if;
    signal_deferred_waiters (self);
  end cancel_deferred;

  procedure wait_deferred_writable
    (self    : in out Deferred_Target_Impl;
     request : in Identity;
     waiter  : not null Deferred_Writable_Waiter_Access;
     status  : out Deferred_Wait_Status)
  is
  begin
    self.state.all.wait_writable (request, waiter, status);
  end wait_deferred_writable;

  procedure cancel_deferred_writable_wait
    (self    : in out Deferred_Target_Impl;
     request : in Identity;
     status  : out Deferred_Wait_Cancel_Status)
  is
  begin
    self.state.all.cancel_writable_wait (request, status);
  end cancel_deferred_writable_wait;

  function target_cancellation_reason
    (self    : Deferred_Target_Impl;
     request : Identity) return Cancellation_Cause
  is
  begin
    return self.state.all.cancellation_reason (request);
  end target_cancellation_reason;

  function deferred_impl (self : Context) return Deferred_Target_Impl_Access is
  begin
    if self.deferred_target = null then
      return null;
    end if;
    return Deferred_Target_Impl_Access(self.deferred_target);
  end deferred_impl;

  function internal_deferred_indices_consistent
    (self : Context) return Boolean
  is
    target : constant Deferred_Target_Impl_Access := deferred_impl(self);
  begin
    return target = null or else target.state.all.indices_consistent;
  end internal_deferred_indices_consistent;

  procedure retire_target_request
    (target  : not null Deferred_Target_Impl_Access;
     request : in Identity;
     cause   : in Cancellation_Cause)
  is
  begin
    cancel_deferred (target.all, request, cause);
  end retire_target_request;

  procedure shutdown_target
    (target : not null Deferred_Target_Impl_Access)
  is
    discarded : Work_Item_Access;
    available : Boolean;
  begin
    target.state.all.shutdown;
    signal_deferred_waiters (target.all);
    loop
      target.state.all.take_retired_command (discarded, available);
      exit when not available;
      Free_Work_Item (discarded);
    end loop;
  end shutdown_target;

  protected body Admission_State is

    function identity_less
      (left  : Identity;
       right : Identity) return Boolean
    is
    begin
      if left.connection_id /= right.connection_id then
        return left.connection_id < right.connection_id;
      elsif left.request_id /= right.request_id then
        return left.request_id < right.request_id;
      end if;
      return left.generation < right.generation;
    end identity_less;

    function tree_height (index : Natural) return Natural is
    begin
      if index = 0 then
        return 0;
      end if;
      if index > capacity or else not entries(index).in_use then
        raise Program_Error with "execution admission tree contains unused entry";
      end if;
      return entries(index).tree_height;
    end tree_height;

    procedure update_tree_height (index : in Positive) is
      left_height  : constant Natural := tree_height(entries(index).tree_left);
      right_height : constant Natural := tree_height(entries(index).tree_right);
    begin
      entries(index).tree_height :=
        Positive(Natural'Max(left_height, right_height) + 1);
    end update_tree_height;

    function tree_balance (index : Positive) return Integer is
    begin
      return Integer(tree_height(entries(index).tree_left)) -
        Integer(tree_height(entries(index).tree_right));
    end tree_balance;

    procedure rotate_tree_left
      (index : in Positive;
       root  : out Positive)
    is
      pivot  : constant Natural := entries(index).tree_right;
      parent : constant Natural := entries(index).tree_parent;
      middle : Natural;
    begin
      if pivot = 0 then
        raise Program_Error with "execution admission left rotation lacks child";
      end if;
      middle := entries(pivot).tree_left;

      if parent = 0 then
        tree_root := pivot;
      elsif entries(parent).tree_left = index then
        entries(parent).tree_left := pivot;
      elsif entries(parent).tree_right = index then
        entries(parent).tree_right := pivot;
      else
        raise Program_Error with "execution admission parent link mismatch";
      end if;
      entries(pivot).tree_parent := parent;

      entries(pivot).tree_left := index;
      entries(index).tree_parent := pivot;
      entries(index).tree_right := middle;
      if middle /= 0 then
        entries(middle).tree_parent := index;
      end if;

      update_tree_height (index);
      update_tree_height (Positive(pivot));
      root := Positive(pivot);
    end rotate_tree_left;

    procedure rotate_tree_right
      (index : in Positive;
       root  : out Positive)
    is
      pivot  : constant Natural := entries(index).tree_left;
      parent : constant Natural := entries(index).tree_parent;
      middle : Natural;
    begin
      if pivot = 0 then
        raise Program_Error with "execution admission right rotation lacks child";
      end if;
      middle := entries(pivot).tree_right;

      if parent = 0 then
        tree_root := pivot;
      elsif entries(parent).tree_left = index then
        entries(parent).tree_left := pivot;
      elsif entries(parent).tree_right = index then
        entries(parent).tree_right := pivot;
      else
        raise Program_Error with "execution admission parent link mismatch";
      end if;
      entries(pivot).tree_parent := parent;

      entries(pivot).tree_right := index;
      entries(index).tree_parent := pivot;
      entries(index).tree_left := middle;
      if middle /= 0 then
        entries(middle).tree_parent := index;
      end if;

      update_tree_height (index);
      update_tree_height (Positive(pivot));
      root := Positive(pivot);
    end rotate_tree_right;

    procedure rebalance_tree (start : Natural) is
      current    : Natural := start;
      subtree    : Positive := 1;
      child      : Natural;
      adjustment : Integer;
    begin
      while current /= 0 loop
        update_tree_height (Positive(current));
        adjustment := tree_balance (Positive(current));

        if adjustment > 1 then
          child := entries(current).tree_left;
          if child = 0 then
            raise Program_Error with "execution admission balance lacks left child";
          end if;
          if tree_balance(Positive(child)) < 0 then
            rotate_tree_left (Positive(child), subtree);
            if entries(current).tree_left /= subtree then
              raise Program_Error with
                "execution admission left-child rotation mismatch";
            end if;
          end if;
          rotate_tree_right (Positive(current), subtree);
        elsif adjustment < -1 then
          child := entries(current).tree_right;
          if child = 0 then
            raise Program_Error with "execution admission balance lacks right child";
          end if;
          if tree_balance(Positive(child)) > 0 then
            rotate_tree_right (Positive(child), subtree);
            if entries(current).tree_right /= subtree then
              raise Program_Error with
                "execution admission right-child rotation mismatch";
            end if;
          end if;
          rotate_tree_left (Positive(current), subtree);
        else
          subtree := Positive(current);
        end if;

        current := entries(subtree).tree_parent;
      end loop;
    end rebalance_tree;

    function find_index (request : Identity) return Natural is
      index     : Natural := tree_root;
      candidate : Identity;
    begin
      if is_null(request) then
        return 0;
      end if;

      while index /= 0 loop
        if index > capacity or else not entries(index).in_use then
          raise Program_Error with "execution admission tree index is inconsistent";
        end if;
        candidate := entries(index).request;
        if candidate = request then
          return index;
        elsif identity_less(request, candidate) then
          index := entries(index).tree_left;
        else
          index := entries(index).tree_right;
        end if;
      end loop;

      return 0;
    end find_index;

    procedure insert_index (index : in Positive) is
      parent    : Natural := 0;
      current   : Natural := tree_root;
      candidate : Identity;
    begin
      if count = capacity or else entries(index).active_position /= 0 or else
         entries(index).tree_parent /= 0 or else entries(index).tree_left /= 0 or else
         entries(index).tree_right /= 0 or else not entries(index).in_use
      then
        raise Program_Error with "invalid execution admission index insertion";
      end if;

      while current /= 0 loop
        parent := current;
        candidate := entries(current).request;
        if candidate = entries(index).request then
          raise Program_Error with "duplicate execution admission index";
        elsif identity_less(entries(index).request, candidate) then
          current := entries(current).tree_left;
        else
          current := entries(current).tree_right;
        end if;
      end loop;

      entries(index).tree_parent := parent;
      entries(index).tree_height := 1;
      if parent = 0 then
        tree_root := index;
      elsif identity_less(entries(index).request, entries(parent).request) then
        entries(parent).tree_left := index;
      else
        entries(parent).tree_right := index;
      end if;

      count := count + 1;
      active_order(count) := index;
      entries(index).active_position := count;
      rebalance_tree (parent);
    end insert_index;

    procedure replace_tree_node
      (old_index   : in Positive;
       replacement : in Natural)
    is
      parent : constant Natural := entries(old_index).tree_parent;
    begin
      if parent = 0 then
        if tree_root /= old_index then
          raise Program_Error with "execution admission tree root mismatch";
        end if;
        tree_root := replacement;
      elsif entries(parent).tree_left = old_index then
        entries(parent).tree_left := replacement;
      elsif entries(parent).tree_right = old_index then
        entries(parent).tree_right := replacement;
      else
        raise Program_Error with "execution admission tree replacement mismatch";
      end if;

      if replacement /= 0 then
        entries(replacement).tree_parent := parent;
      end if;
    end replace_tree_node;

    procedure remove_index (index : in Positive) is
      left_child       : constant Natural := entries(index).tree_left;
      right_child      : constant Natural := entries(index).tree_right;
      rebalance_start  : Natural := 0;
      successor        : Natural;
      successor_parent : Natural;
      successor_right  : Natural;
      position          : constant Natural := entries(index).active_position;
      moved             : Natural;
    begin
      if position = 0 or else position > count or else
         active_order(position) /= index
      then
        raise Program_Error with "execution admission dense index removal mismatch";
      end if;

      if left_child = 0 then
        rebalance_start := entries(index).tree_parent;
        replace_tree_node (index, right_child);
      elsif right_child = 0 then
        rebalance_start := entries(index).tree_parent;
        replace_tree_node (index, left_child);
      else
        successor := right_child;
        while entries(successor).tree_left /= 0 loop
          successor := entries(successor).tree_left;
        end loop;

        if entries(successor).tree_parent = index then
          replace_tree_node (index, successor);
          entries(successor).tree_left := left_child;
          entries(left_child).tree_parent := successor;
          update_tree_height (Positive(successor));
          rebalance_start := successor;
        else
          successor_parent := entries(successor).tree_parent;
          successor_right := entries(successor).tree_right;
          replace_tree_node (Positive(successor), successor_right);
          entries(successor).tree_right := right_child;
          entries(right_child).tree_parent := successor;
          replace_tree_node (index, successor);
          entries(successor).tree_left := left_child;
          entries(left_child).tree_parent := successor;
          update_tree_height (Positive(successor));
          rebalance_start := successor_parent;
        end if;
      end if;

      entries(index).tree_parent := 0;
      entries(index).tree_left := 0;
      entries(index).tree_right := 0;
      entries(index).tree_height := 1;

      if rebalance_start /= 0 then
        rebalance_tree (rebalance_start);
      end if;

      moved := active_order(count);
      if position < count then
        active_order(position) := moved;
        entries(moved).active_position := position;
      end if;
      active_order(count) := 0;
      entries(index).active_position := 0;
      count := count - 1;
    end remove_index;

    procedure allocate_entry (index : out Natural) is
    begin
      if free_head /= 0 then
        index := free_head;
        free_head := entries(index).free_next;
      elsif next_unused <= capacity then
        index := next_unused;
        next_unused := next_unused + 1;
      else
        index := 0;
        return;
      end if;
      entries(index) := (others => <>);
      entries(index).in_use := True;
    end allocate_entry;

    procedure free_entry (index : in Positive) is
    begin
      entries(index) := (others => <>);
      entries(index).free_next := free_head;
      free_head := index;
    end free_entry;

    procedure reserve
      (request : in Identity;
       result  : out Reservation_Result)
    is
      index : Natural;
    begin
      if not accepting then
        result := Reservation_Not_Accepting;
        return;
      end if;

      if find_index(request) /= 0 then
        result := Reservation_Duplicate;
        return;
      end if;

      if count = capacity then
        result := Reservation_Full;
        return;
      end if;

      allocate_entry (index);
      if index = 0 then
        raise Program_Error with "execution admission free capacity is inconsistent";
      end if;
      entries(index).request := request;
      insert_index (Positive(index));
      result := Reservation_Accepted;
    end reserve;

    procedure stop_accepting is
    begin
      accepting := False;
    end stop_accepting;

    procedure prepare_shutdown_entry
      (index   : in Positive;
       cause   : in Cancellation_Cause;
       request : out Identity;
       context : out Callback_Context_Access)
    is
      entry_index : Natural;
    begin
      request := NULL_IDENTITY;
      context := null;
      if index > count then
        return;
      end if;

      entry_index := active_order(index);
      if entry_index = 0 or else entry_index > capacity or else
         not entries(entry_index).in_use
      then
        raise Program_Error with "execution admission shutdown index is inconsistent";
      end if;

      request := entries(entry_index).request;
      if entries(entry_index).cause = Not_Cancelled then
        entries(entry_index).cause := cause;
      end if;
      context := entries(entry_index).context;
    end prepare_shutdown_entry;

    procedure bind_context
      (request : in Identity;
       context : in Callback_Context_Access;
       cause   : out Cancellation_Cause)
    is
      index : constant Natural := find_index(request);
    begin
      cause := Not_Cancelled;
      if index = 0 then
        raise Program_Error with "execution admission identity not reserved";
      end if;
      if entries(index).context /= null then
        raise Program_Error with "execution admission context rebound";
      end if;
      entries(index).context := context;
      cause := entries(index).cause;
    end bind_context;

    procedure note_cancellation
      (request : in Identity;
       cause   : in Cancellation_Cause;
       context : out Callback_Context_Access)
    is
      index : constant Natural := find_index(request);
    begin
      context := null;
      if index = 0 then
        return;
      end if;
      if entries(index).cause = Not_Cancelled then
        entries(index).cause := cause;
      end if;
      context := entries(index).context;
    end note_cancellation;

    procedure release (request : in Identity) is
      index : constant Natural := find_index(request);
    begin
      if index = 0 then
        raise Program_Error with "execution admission identity not reserved";
      end if;
      remove_index (Positive(index));
      free_entry (Positive(index));
    end release;

    function reserved_count return Natural is
    begin
      return count;
    end reserved_count;

    function has_capacity return Boolean is
    begin
      return accepting and then count < capacity;
    end has_capacity;

    function is_accepting return Boolean is
    begin
      return accepting;
    end is_accepting;

    function is_empty return Boolean is
    begin
      return count = 0;
    end is_empty;

    function indices_consistent return Boolean is
      tree_count    : Natural := 0;
      free_count    : Natural := 0;
      previous      : Identity := NULL_IDENTITY;
      have_previous : Boolean := False;

      function validate_tree
        (node   : Natural;
         parent : Natural;
         height : out Natural) return Boolean
      is
        left_height  : Natural;
        right_height : Natural;
        expected     : Natural;
      begin
        if node = 0 then
          height := 0;
          return True;
        end if;
        if node > capacity or else not entries(node).in_use or else
           entries(node).tree_parent /= parent
        then
          height := 0;
          return False;
        end if;

        if not validate_tree(entries(node).tree_left, node, left_height) then
          height := 0;
          return False;
        end if;
        if have_previous and then not identity_less(previous, entries(node).request) then
          height := 0;
          return False;
        end if;
        previous := entries(node).request;
        have_previous := True;
        tree_count := tree_count + 1;
        if tree_count > count then
          height := 0;
          return False;
        end if;
        if not validate_tree(entries(node).tree_right, node, right_height) then
          height := 0;
          return False;
        end if;

        expected := Natural'Max(left_height, right_height) + 1;
        if entries(node).tree_height /= expected or else
           abs (Integer(left_height) - Integer(right_height)) > 1
        then
          height := 0;
          return False;
        end if;
        height := expected;
        return True;
      end validate_tree;

      height : Natural;
      index  : Natural;
    begin
      if count > capacity or else next_unused = 0 or else
         next_unused > capacity + 1
      then
        return False;
      end if;

      for position in 1 .. count loop
        index := active_order(position);
        if index = 0 or else index > capacity or else
           not entries(index).in_use or else
           entries(index).active_position /= position or else
           entries(index).free_next /= 0
        then
          return False;
        end if;
      end loop;

      if not validate_tree(tree_root, 0, height) or else tree_count /= count then
        return False;
      end if;

      index := free_head;
      while index /= 0 loop
        free_count := free_count + 1;
        if free_count > capacity or else index > capacity or else
           entries(index).in_use or else entries(index).active_position /= 0 or else
           entries(index).tree_parent /= 0 or else entries(index).tree_left /= 0 or else
           entries(index).tree_right /= 0
        then
          return False;
        end if;
        index := entries(index).free_next;
      end loop;

      return count + free_count = next_unused - 1;
    end indices_consistent;

  end Admission_State;

  procedure copy_bytes
    (source : in Fasyn.Protocol.Byte_Array;
     target : in out Fasyn.Protocol.Byte_Array;
     length : out Natural)
  is
    position : Positive := target'first;
  begin
    length := source'length;

    for index in source'range loop
      target(position) := source(index);
      position := position + 1;
    end loop;
  end copy_bytes;

  function batch_remaining
    (limit    : Natural;
     position : Natural) return Natural
  is
  begin
    if position > limit then
      return 0;
    end if;
    return limit - position + 1;
  end batch_remaining;

  function decode_batch_length
    (data     : P.Byte_Array;
     limit    : Natural;
     position : in out Natural;
     value    : out Natural) return Boolean
  is
    encoded : Interfaces.Unsigned_32;
    first   : P.Byte;
  begin
    value := 0;
    if position > limit then
      return False;
    end if;

    first := data(position);
    if (first and 16#80#) = 0 then
      value := Natural(first);
      position := position + 1;
      return True;
    end if;

    if limit - position < 3 then
      return False;
    end if;

    encoded := Interfaces.Shift_Left
      (Interfaces.Unsigned_32(first and 16#7f#), 24);
    encoded := encoded or Interfaces.Shift_Left
      (Interfaces.Unsigned_32(data(position + 1)), 16);
    encoded := encoded or Interfaces.Shift_Left
      (Interfaces.Unsigned_32(data(position + 2)), 8);
    encoded := encoded or Interfaces.Unsigned_32(data(position + 3));
    if encoded < 128 then
      return False;
    end if;
    value := Natural(encoded);
    position := position + 4;
    return True;
  end decode_batch_length;

  procedure execute_parameter_batch
    (job    : in out Work_Item;
     finish : Boolean)
  is
    position     : Natural := 1;
    name_length  : Natural;
    value_length : Natural;
    name_first   : Natural;
    name_last    : Natural;
    value_first  : Natural;
    value_last   : Natural;
    pair_count   : Natural := 0;
    saved_defer  : constant Boolean := job.callback_context.defer_allowed;
  begin
    if job.data_length = 0 then
      raise Program_Error with "empty parameter batch";
    end if;

    job.callback_context.defer_allowed := False;
    begin
      while position <= job.data_length loop
        pair_count := pair_count + 1;
        if pair_count > MAX_PARAMETER_PAIRS_PER_BATCH or else
           not decode_batch_length
             (job.data_bytes, job.data_length, position, name_length) or else
           not decode_batch_length
             (job.data_bytes, job.data_length, position, value_length)
        then
          raise Program_Error with "invalid parameter batch";
        end if;

        if name_length > batch_remaining(job.data_length, position) then
          raise Program_Error with "invalid parameter batch name";
        end if;
        name_first := position;
        name_last :=
          (if name_length = 0 then position - 1
           else position + name_length - 1);
        position := position + name_length;

        if value_length > batch_remaining(job.data_length, position) then
          raise Program_Error with "invalid parameter batch value";
        end if;
        value_first := position;
        value_last :=
          (if value_length = 0 then position - 1
           else position + value_length - 1);
        position := position + value_length;

        on_parameter
          (job.application.all,
           job.callback_context,
           job.data_bytes(name_first .. name_last),
           job.data_bytes(value_first .. value_last));
      end loop;
    exception
      when others =>
        job.callback_context.defer_allowed := saved_defer;
        raise;
    end;
    job.callback_context.defer_allowed := saved_defer;

    if finish then
      declare
        saved_limit : constant Natural := job.response.limit;
      begin
        begin
          if job.callback_context.role_value = P.Filter then
            job.response.limit := job.response.length;
          end if;
          on_params_end
            (job.application.all, job.callback_context, job.response);
        exception
          when others =>
            job.response.limit := saved_limit;
            raise;
        end;
        job.response.limit := saved_limit;
      end;
    end if;
  end execute_parameter_batch;

  procedure execute_stdin_batch
    (job    : in out Work_Item;
     finish : Boolean)
  is
    saved_limit : constant Natural := job.response.limit;
    saved_defer : constant Boolean := job.callback_context.defer_allowed;
  begin
    job.callback_context.defer_allowed := False;
    begin
      if finish and then job.callback_context.role_value = P.Filter then
        job.response.limit := job.response.length;
      end if;

      on_stdin
        (job.application.all, job.callback_context,
         job.data_bytes(1 .. job.data_length), job.response);
    exception
      when others =>
        job.response.limit := saved_limit;
        job.callback_context.defer_allowed := saved_defer;
        raise;
    end;
    job.response.limit := saved_limit;
    job.callback_context.defer_allowed := saved_defer;

    if finish then
      on_stdin_end
        (job.application.all, job.callback_context, job.response);
    end if;
  end execute_stdin_batch;

  procedure execute_data_batch
    (job    : in out Work_Item;
     finish : Boolean)
  is
    saved_defer : constant Boolean := job.callback_context.defer_allowed;
  begin
    job.callback_context.defer_allowed := False;
    begin
      on_data
        (job.application.all,
         job.callback_context,
         job.data_bytes(1 .. job.data_length),
         job.response);
    exception
      when others =>
        job.callback_context.defer_allowed := saved_defer;
        raise;
    end;
    job.callback_context.defer_allowed := saved_defer;

    if finish then
      on_data_end
        (job.application.all, job.callback_context, job.response);
    end if;
  end execute_data_batch;

  procedure execute_job (job : in out Work_Item_Access) is
  begin
    case job.operation_value is
      when Deliver_Parameter =>
        on_parameter
          (job.application.all,
           job.callback_context,
           job.name_bytes(1 .. job.name_length),
           job.value_bytes(1 .. job.value_length));

      when Deliver_Parameter_Batch =>
        execute_parameter_batch (job.all, False);

      when Deliver_Parameter_Batch_And_Finish =>
        execute_parameter_batch (job.all, True);

      when Finish_Params =>
        on_params_end
          (job.application.all, job.callback_context, job.response);

      when Deliver_Stdin =>
        on_stdin
          (job.application.all,
           job.callback_context,
           job.data_bytes(1 .. job.data_length),
           job.response);

      when Deliver_Stdin_And_Finish =>
        execute_stdin_batch (job.all, True);

      when Finish_Stdin =>
        on_stdin_end
          (job.application.all, job.callback_context, job.response);

      when Deliver_Data =>
        on_data
          (job.application.all,
           job.callback_context,
           job.data_bytes(1 .. job.data_length),
           job.response);

      when Deliver_Data_And_Finish =>
        execute_data_batch (job.all, True);

      when Finish_Data =>
        on_data_end
          (job.application.all, job.callback_context, job.response);
    end case;
  end execute_job;

  function submission_status
    (self         : Context;
     request      : Identity;
     output_limit : Natural) return Clair.Status.Code
  is
  begin
    if not self.initialized or else
       not self.admission.is_accepting or else
       not Pool.is_accepting(self.workers)
    then
      return Clair.Status.INVALID_STATE;
    elsif is_null(request) then
      return Clair.Status.INVALID_ARGUMENT;
    elsif output_limit > self.max_output_bytes then
      return Clair.Status.RANGE_ERROR;
    end if;

    return Clair.Status.OK;
  end submission_status;

  function valid_parameter_batch
    (self : Context;
     data : P.Byte_Array) return Boolean
  is
    position     : Natural := data'first;
    limit        : constant Natural := data'last;
    name_length  : Natural;
    value_length : Natural;
    pair_count   : Natural := 0;
  begin
    if data'length = 0 or else
       data'length > self.max_batch_input_bytes
    then
      return False;
    end if;

    while position <= limit loop
      pair_count := pair_count + 1;
      if pair_count > MAX_PARAMETER_PAIRS_PER_BATCH or else
         not decode_batch_length (data, limit, position, name_length) or else
         not decode_batch_length (data, limit, position, value_length)
      then
        return False;
      end if;

      if name_length > self.max_input_bytes or else
         value_length > self.max_input_bytes - name_length or else
         name_length > batch_remaining(limit, position)
      then
        return False;
      end if;
      position := position + name_length;

      if value_length > batch_remaining(limit, position) then
        return False;
      end if;
      position := position + value_length;
    end loop;

    return pair_count > 0;
  end valid_parameter_batch;

  function callback_deferred_target
    (self : Context) return Deferred_Target_Access
  is
  begin
    if self.deferred_enabled then
      return self.deferred_target;
    end if;
    return null;
  end callback_deferred_target;

  procedure prepare_item
    (item               : in out Work_Item;
     request            : Identity;
     role               : Fasyn.Protocol.Role;
     operation          : Operation_Kind;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     output_limit       : Natural;
     deferred_target    : Deferred_Target_Access)
  is
    allow_defer : constant Boolean :=
      ((operation = Finish_Params or else
        operation = Deliver_Parameter_Batch_And_Finish) and then
       role = P.Authorizer) or else
      ((operation = Finish_Stdin or else
        operation = Deliver_Stdin_And_Finish) and then
       role = P.Responder) or else
      ((operation = Finish_Data or else
        operation = Deliver_Data_And_Finish) and then role = P.Filter);
  begin
    item.request_value := request;
    initialize_callback_context
      (item.callback_context, request, role, deferred_target, allow_defer);
    item.operation_value := operation;
    item.application := application;
    item.completion_handler := completion_handler;
    item.response.first := 1;
    item.response.length := 0;
    item.response.limit := output_limit;
    item.response.request_id := request.request_id;
    item.response.initialized := True;
    item.response.finished := False;
    item.response.failed := False;
  end prepare_item;

  function reserve_submission
    (self    : in out Context;
     request : Identity) return Reservation_Result
  is
    result : Reservation_Result;
  begin
    if self.capacity_wait_head /= null and then
       not self.capacity_wait_dispatching
    then
      return Reservation_Full;
    end if;

    self.admission.reserve (request, result);
    return result;
  end reserve_submission;

  function reservation_status
    (result : Reservation_Result) return Clair.Status.Code
  is
  begin
    case result is
      when Reservation_Accepted | Reservation_Full =>
        return Clair.Status.OK;
      when Reservation_Not_Accepting | Reservation_Duplicate =>
        return Clair.Status.INVALID_STATE;
    end case;
  end reservation_status;

  function submit_item
    (self     : in out Context;
     item     : in out Work_Item_Access;
     accepted : out Boolean) return Clair.Status.Code
  is
    request : constant Identity := item.request_value;
    cause   : Cancellation_Cause;
    status  : Clair.Status.Code;
  begin
    self.admission.bind_context
      (request, item.callback_context'Unchecked_Access, cause);
    if cause /= Not_Cancelled then
      Fasyn.Request.signal_cancellation (item.callback_context, cause);
    end if;

    status := Pool.submit (self.workers, item, accepted);

    if status /= Clair.Status.OK or else not accepted then
      self.admission.release (request);
      Free_Work_Item (item);
      if status = Clair.Status.OK and then
         not Pool.is_accepting(self.workers)
      then
        return Clair.Status.INVALID_STATE;
      end if;
    end if;

    return status;
  end submit_item;

  procedure finalize_unstarted_pool
    (self : in out Context)
  is
    status : Clair.Status.Code;
  begin
    status := Pool.begin_shutdown (self.workers);
    if status /= Clair.Status.OK then
      raise Program_Error with "worker pool setup cleanup failed";
    end if;

    status := Pool.finalize (self.workers);
    if status /= Clair.Status.OK then
      raise Program_Error with "worker pool setup finalization failed";
    end if;

    self.pool_initialized := False;
  end finalize_unstarted_pool;

  function initialize
    (self             : aliased in out Context;
     event_loop       : not null Clair.Event_Loop.Context_Access;
     worker_count     : Positive;
     pending_capacity : Positive;
     max_input_bytes  : Positive;
     max_output_bytes : Positive;
     deferred_capacity : Natural := DEFAULT_DEFERRED_CAPACITY)
     return Clair.Status.Code
  is
    admission_capacity  : Positive;
    batch_input_capacity : Positive;
    target_capacity      : Positive;
    status : Clair.Status.Code;
    target : Deferred_Target_Impl_Access;
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    begin
      admission_capacity := worker_count + pending_capacity;
      if max_input_bytes > (Positive'Last - 8) / 2 then
        return Clair.Status.RANGE_ERROR;
      end if;
      batch_input_capacity := 2 * max_input_bytes + 8;
      target_capacity := Positive'Max (1, deferred_capacity);
    exception
      when Constraint_Error =>
        return Clair.Status.RANGE_ERROR;
    end;

    begin
      self.admission := new Admission_State
        (capacity => admission_capacity);
    exception
      when Storage_Error =>
        return Clair.Status.OUT_OF_MEMORY;
    end;

    begin
      target := new Deferred_Target_Impl;
      target.state := new Deferred_State
        (capacity         => target_capacity,
         max_output_bytes => max_output_bytes);
      self.deferred_target := Deferred_Target_Access (target);
    exception
      when Storage_Error =>
        if target /= null then
          if target.state /= null then
            Free_Deferred_State (target.state);
          end if;
          Free_Deferred_Target_Impl (target);
        end if;
        Free_Admission (self.admission);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    status := Pool.initialize
      (self                  => self.workers,
       worker_count          => worker_count,
       pending_capacity      => pending_capacity,
       completion_signaler   => target.signaler'Unchecked_Access);

    if status /= Clair.Status.OK then
      Free_Admission (self.admission);
      release_target (self.deferred_target);
      return status;
    end if;
    self.pool_initialized := True;

    self.notification_handler.owner := self'Unchecked_Access;
    status := Clair.Event_Loop.Notification.add
      (self    => event_loop.all,
       target           => target.signaler,
       callback         => notification_callback'Access,
       callback_context => self.notification_handler'Address,
       source           => self.notification_source);

    if status /= Clair.Status.OK then
      finalize_unstarted_pool (self);
      Free_Admission (self.admission);
      release_target (self.deferred_target);
      self.notification_handler.owner := null;
      return status;
    end if;

    target.signaler_initialized := True;
    self.event_loop := event_loop;
    self.max_input_bytes := max_input_bytes;
    self.max_batch_input_bytes := batch_input_capacity;
    self.max_output_bytes := max_output_bytes;
    self.deferred_enabled := deferred_capacity /= 0;
    self.capacity_wait_dispatching := False;
    self.capacity_wake_pending := False;
    self.delivery_job := null;
    self.delivery_status := Clair.Status.OK;
    self.delivery_offset := 0;
    self.deferred_delivery_job := null;
    self.deferred_delivery_offset := 0;
    self.notification_active := True;
    self.initialized := True;
    return Clair.Status.OK;
  end initialize;

  function uses_event_loop
    (self       : Context;
     event_loop : not null Clair.Event_Loop.Context_Access) return Boolean
  is
  begin
    return self.initialized and then self.event_loop = event_loop;
  end uses_event_loop;

  function issue_connection_identity
    (self     : in out Context;
     identity : out Connection_Identity) return Clair.Status.Code
  is
  begin
    identity := NO_CONNECTION_IDENTITY;

    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.connection_identity_exhausted then
      return Clair.Status.RANGE_ERROR;
    end if;

    identity := self.next_connection_identity;
    if self.next_connection_identity = Connection_Identity'Last then
      self.connection_identity_exhausted := True;
    else
      self.next_connection_identity := self.next_connection_identity + 1;
    end if;

    return Clair.Status.OK;
  end issue_connection_identity;

  function supports_work_limits
    (self                  : Context;
     required_input_bytes  : Positive;
     required_output_bytes : Positive) return Boolean
  is
  begin
    return self.initialized and then
      required_input_bytes <= self.max_input_bytes and then
      required_output_bytes <= self.max_output_bytes;
  end supports_work_limits;

  function supports_batch_input_bytes
    (self           : Context;
     required_bytes : Positive) return Boolean
  is
  begin
    return self.initialized and then
      required_bytes <= self.max_batch_input_bytes;
  end supports_batch_input_bytes;

  function wait_for_capacity
    (self   : aliased in out Context;
     node   : aliased in out Capacity_Wait_Node;
     waiter : not null Capacity_Waiter_Access) return Clair.Status.Code
  is
    node_access : constant Capacity_Wait_Node_Access := node'Unchecked_Access;
  begin
    if not self.initialized or else not is_accepting(self) then
      return Clair.Status.INVALID_STATE;
    end if;

    if node.registered then
      if node.owner = self'Unchecked_Access and then node.waiter = waiter then
        return Clair.Status.OK;
      end if;
      return Clair.Status.INVALID_STATE;
    end if;

    node.owner := self'Unchecked_Access;
    node.waiter := waiter;
    node.previous := self.capacity_wait_tail;
    node.next := null;
    node.registered := True;

    if self.capacity_wait_tail = null then
      self.capacity_wait_head := node_access;
    else
      self.capacity_wait_tail.next := node_access;
    end if;
    self.capacity_wait_tail := node_access;
    return Clair.Status.OK;
  end wait_for_capacity;

  function cancel_capacity_wait
    (self : aliased in out Context;
     node : aliased in out Capacity_Wait_Node) return Clair.Status.Code
  is
  begin
    if not node.registered then
      return Clair.Status.OK;
    end if;

    if not self.initialized or else node.owner /= self'Unchecked_Access then
      return Clair.Status.INVALID_STATE;
    end if;

    if node.previous = null then
      if self.capacity_wait_head /= node'Unchecked_Access then
        return Clair.Status.CONTRACT_VIOLATION;
      end if;
      self.capacity_wait_head := node.next;
    else
      node.previous.next := node.next;
    end if;

    if node.next = null then
      if self.capacity_wait_tail /= node'Unchecked_Access then
        return Clair.Status.CONTRACT_VIOLATION;
      end if;
      self.capacity_wait_tail := node.previous;
    else
      node.next.previous := node.previous;
    end if;

    node.owner := null;
    node.waiter := null;
    node.previous := null;
    node.next := null;
    node.registered := False;
    if self.capacity_wait_head = null then
      self.capacity_wake_pending := False;
    end if;
    return Clair.Status.OK;
  end cancel_capacity_wait;

  function wake_capacity_waiter
    (self          : aliased in out Context;
     re_registered : out Boolean) return Clair.Status.Code
  is
    node   : constant Capacity_Wait_Node_Access := self.capacity_wait_head;
    waiter : Capacity_Waiter_Access;
    status : Clair.Status.Code;
  begin
    re_registered := False;
    if node = null then
      return Clair.Status.OK;
    end if;

    if not node.registered or else
       node.owner /= self'Unchecked_Access or else
       node.waiter = null
    then
      re_registered := True;
      return Clair.Status.CONTRACT_VIOLATION;
    end if;

    waiter := node.waiter;
    self.capacity_wait_head := node.next;
    if self.capacity_wait_head = null then
      self.capacity_wait_tail := null;
    else
      self.capacity_wait_head.previous := null;
    end if;

    node.owner := null;
    node.waiter := null;
    node.previous := null;
    node.next := null;
    node.registered := False;

    self.capacity_wait_dispatching := True;
    begin
      status := on_capacity_available (waiter.all);
    exception
      when others =>
        status := Clair.Status.CALLBACK_FAILED;
    end;
    self.capacity_wait_dispatching := False;
    re_registered := node.registered;
    return status;
  end wake_capacity_waiter;

  function begin_shutdown
    (self : in out Context) return Clair.Status.Code
  is
    request : Identity;
    context : Callback_Context_Access;
    count   : Natural;
  begin
    if not self.initialized or else
       self.capacity_wait_head /= null or else
       self.capacity_wait_tail /= null or else
       self.capacity_wait_dispatching
    then
      return Clair.Status.INVALID_STATE;
    end if;

    self.admission.stop_accepting;
    count := self.admission.reserved_count;
    for index in 1 .. count loop
      self.admission.prepare_shutdown_entry
        (index, Runtime_Shutdown, request, context);
      if not is_null(request) and then context /= null then
        Fasyn.Request.signal_cancellation (context.all, Runtime_Shutdown);
      end if;
    end loop;

    if deferred_impl(self) /= null then
      shutdown_target (deferred_impl(self));
    end if;

    return Pool.begin_shutdown (self.workers);
  end begin_shutdown;

  function signal_cancellation
    (self    : in out Context;
     request : Identity;
     cause   : Cancellation_Cause) return Clair.Status.Code
  is
    context : Callback_Context_Access;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if is_null(request) or else cause = Not_Cancelled then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    self.admission.note_cancellation (request, cause, context);
    if context /= null then
      Fasyn.Request.signal_cancellation (context.all, cause);
    end if;

    if deferred_impl(self) /= null then
      retire_target_request (deferred_impl(self), request, cause);
    end if;

    return Clair.Status.OK;
  end signal_cancellation;

  function finalize
    (self : in out Context) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if Pool.is_accepting(self.workers) or else
       not Pool.is_idle(self.workers) or else
       Pool.completed_count(self.workers) /= 0 or else
       not self.admission.is_empty or else
       self.capacity_wait_head /= null or else
       self.capacity_wait_tail /= null or else
       self.capacity_wait_dispatching or else
       self.capacity_wake_pending or else
       self.delivery_job /= null or else
       self.deferred_delivery_job /= null or else
       (deferred_impl(self) /= null and then
        deferred_impl(self).state.all.has_writable_waiter)
    then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.notification_active then
      status := Clair.Event_Loop.remove
        (self.event_loop.all, self.notification_source);
      if status /= Clair.Status.OK then
        return status;
      end if;
      self.notification_active := False;
    end if;

    status := Pool.finalize (self.workers);
    if status /= Clair.Status.OK then
      return status;
    end if;

    Free_Admission (self.admission);
    release_target (self.deferred_target);
    self.deferred_enabled := False;
    self.pool_initialized := False;
    self.capacity_wait_dispatching := False;
    self.capacity_wake_pending := False;
    self.delivery_job := null;
    self.delivery_status := Clair.Status.OK;
    self.delivery_offset := 0;
    self.deferred_delivery_job := null;
    self.deferred_delivery_offset := 0;
    self.event_loop := null;
    self.initialized := False;
    self.notification_handler.owner := null;
    return Clair.Status.OK;
  end finalize;

  function submit_parameter
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     name               : Fasyn.Protocol.Byte_Array;
     value              : Fasyn.Protocol.Byte_Array;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    validation := submission_status (self, request, 0);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    if name'length > self.max_input_bytes or else
       value'length > self.max_input_bytes - name'length
    then
      return Clair.Status.RANGE_ERROR;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => Positive'Max (1, name'length),
         value_capacity  => Positive'Max (1, value'length),
         data_capacity   => 1,
         output_capacity => 1);
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       role,
       Deliver_Parameter,
       application,
       completion_handler,
       0,
       callback_deferred_target(self));
    copy_bytes (name, item.name_bytes, item.name_length);
    copy_bytes (value, item.value_bytes, item.value_length);
    return submit_item (self, item, accepted);
  end submit_parameter;

  function submit_parameter_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     encoded            : P.Byte_Array;
     finish_params      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : P.Role := P.Responder) return Clair.Status.Code
  is
    item      : Work_Item_Access;
    operation : constant Operation_Kind :=
      (if finish_params then Deliver_Parameter_Batch_And_Finish
       else Deliver_Parameter_Batch);
    storage_capacity : constant Positive :=
      Positive'Max
        (1, (if finish_params then output_limit else 0));
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    elsif not valid_parameter_batch(self, encoded) then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => encoded'length,
         output_capacity => storage_capacity);
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all, request, role, operation, application, completion_handler,
       (if finish_params then output_limit else 0),
       callback_deferred_target(self));
    copy_bytes (encoded, item.data_bytes, item.data_length);
    return submit_item (self, item, accepted);
  end submit_parameter_batch;

  function submit_params_end
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => 1,
         output_capacity => Positive'Max (1, output_limit));
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       role,
       Finish_Params,
       application,
       completion_handler,
       output_limit,
       callback_deferred_target(self));
    return submit_item (self, item, accepted);
  end submit_params_end;

  function submit_stdin
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    if role = P.Authorizer then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    if data'length = 0 or else data'length > self.max_input_bytes then
      return Clair.Status.RANGE_ERROR;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => data'length,
         output_capacity => Positive'Max (1, output_limit));
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       role,
       Deliver_Stdin,
       application,
       completion_handler,
       output_limit,
       callback_deferred_target(self));
    copy_bytes (data, item.data_bytes, item.data_length);
    return submit_item (self, item, accepted);
  end submit_stdin;

  function submit_stdin_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : P.Byte_Array;
     finish_stream      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : P.Role := P.Responder) return Clair.Status.Code
  is
    item      : Work_Item_Access;
    operation : constant Operation_Kind :=
      (if finish_stream then Deliver_Stdin_And_Finish else Deliver_Stdin);
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    if role = P.Authorizer then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    if data'length = 0 or else data'length > self.max_batch_input_bytes then
      return Clair.Status.RANGE_ERROR;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => data'length,
         output_capacity => Positive'Max (1, output_limit));
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all, request, role, operation, application, completion_handler,
       output_limit, callback_deferred_target(self));
    copy_bytes (data, item.data_bytes, item.data_length);
    return submit_item (self, item, accepted);
  end submit_stdin_batch;

  function submit_stdin_end
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    if role = P.Authorizer then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => 1,
         output_capacity => Positive'Max (1, output_limit));
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       role,
       Finish_Stdin,
       application,
       completion_handler,
       output_limit,
       callback_deferred_target(self));
    return submit_item (self, item, accepted);
  end submit_stdin_end;

  function submit_data
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code
  is
    item : Work_Item_Access;
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    if data'length = 0 or else data'length > self.max_input_bytes then
      return Clair.Status.RANGE_ERROR;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => data'length,
         output_capacity => Positive'Max (1, output_limit));
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       P.Filter,
       Deliver_Data,
       application,
       completion_handler,
       output_limit,
       callback_deferred_target(self));
    copy_bytes (data, item.data_bytes, item.data_length);
    return submit_item (self, item, accepted);
  end submit_data;

  function submit_data_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : P.Byte_Array;
     finish_stream      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code
  is
    item      : Work_Item_Access;
    operation : constant Operation_Kind :=
      (if finish_stream then Deliver_Data_And_Finish else Deliver_Data);
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    if data'length = 0 or else data'length > self.max_batch_input_bytes then
      return Clair.Status.RANGE_ERROR;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => data'length,
         output_capacity => Positive'Max (1, output_limit));
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all, request, P.Filter, operation, application, completion_handler,
       output_limit, callback_deferred_target(self));
    copy_bytes (data, item.data_bytes, item.data_length);
    return submit_item (self, item, accepted);
  end submit_data_batch;

  function submit_data_end
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code
  is
    item : Work_Item_Access;
    validation  : Clair.Status.Code;
    reservation : Reservation_Result;
  begin
    accepted := False;

    validation := submission_status (self, request, output_limit);
    if validation /= Clair.Status.OK then
      return validation;
    end if;

    reservation := reserve_submission (self, request);
    validation := reservation_status (reservation);
    if validation /= Clair.Status.OK then
      return validation;
    elsif reservation = Reservation_Full then
      return Clair.Status.OK;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => 1,
         output_capacity => Positive'Max (1, output_limit));
    exception
      when Storage_Error =>
        self.admission.release (request);
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       P.Filter,
       Finish_Data,
       application,
       completion_handler,
       output_limit,
       callback_deferred_target(self));
    return submit_item (self, item, accepted);
  end submit_data_end;

  function completion_request (item : Completion) return Identity is
  begin
    return item.item.request_value;
  end completion_request;

  function output_length (item : Completion) return Natural is
  begin
    return item.delivery_length;
  end output_length;

  function output_byte
    (item  : Completion;
     index : Positive) return Fasyn.Protocol.Byte
  is
  begin
    if index > item.delivery_length then
      raise Constraint_Error with "completion output byte index out of range";
    end if;
    return buffered_byte
      (item.item.response, item.delivery_offset + index);
  end output_byte;

  function output_finished (item : Completion) return Boolean is
  begin
    return item.delivery_is_final and then item.item.response.finished;
  end output_finished;

  function output_failed (item : Completion) return Boolean is
  begin
    return item.item.response.failed;
  end output_failed;

  function delivery_complete (item : Completion) return Boolean is
  begin
    return item.delivery_is_final;
  end delivery_complete;

  function is_deferred_output (item : Completion) return Boolean is
  begin
    return item.deferred_output;
  end is_deferred_output;

  function deferred_kind (item : Completion) return Deferred_Output_Kind is
  begin
    if not item.deferred_output or else item.item = null then
      raise Program_Error with "completion is not deferred output";
    end if;
    return item.item.deferred_kind;
  end deferred_kind;

  function deferred_data_length (item : Completion) return Natural is
  begin
    if not item.deferred_output or else item.item = null then
      raise Program_Error with "completion is not deferred output";
    end if;
    return item.delivery_length;
  end deferred_data_length;

  function copy_deferred_data
    (item   : in Completion;
     offset : in Natural;
     target : out P.Byte_Array) return Natural
  is
    count : Natural;
  begin
    if not item.deferred_output or else item.item = null then
      raise Program_Error with "completion is not deferred output";
    end if;
    if offset >= item.delivery_length or else target'length = 0 then
      return 0;
    end if;
    count := Natural'Min (target'length, item.delivery_length - offset);
    for index in 0 .. count - 1 loop
      target(target'first + index) :=
        item.item.data_bytes(item.delivery_offset + offset + index + 1);
    end loop;
    return count;
  end copy_deferred_data;

  function deferred_application_status
    (item : Completion) return Interfaces.Unsigned_32
  is
  begin
    if not item.deferred_output or else item.item = null then
      raise Program_Error with "completion is not deferred output";
    end if;
    return item.item.deferred_status;
  end deferred_application_status;

  function deferred_requested
    (self    : Context;
     request : Identity) return Boolean
  is
  begin
    return self.initialized and then deferred_impl(self) /= null and then
      deferred_impl(self).state.all.requested(request);
  end deferred_requested;

  function activate_deferred
    (self               : in out Context;
     request            : Identity;
     request_pending    : Natural;
     request_limit      : Positive;
     connection_pending : Natural;
     connection_limit   : Positive) return Clair.Status.Code
  is
    success : Boolean;
  begin
    if not self.initialized or else deferred_impl(self) = null or else
       is_null(request)
    then
      return Clair.Status.INVALID_STATE;
    end if;

    deferred_impl(self).state.all.activate
      (request, request_pending, request_limit,
       connection_pending, connection_limit, success);
    if not success then
      return Clair.Status.INVALID_STATE;
    end if;
    return Clair.Status.OK;
  end activate_deferred;

  procedure retire_deferred
    (self    : in out Context;
     request : Identity;
     cause   : Cancellation_Cause := Not_Cancelled)
  is
  begin
    if self.initialized and then deferred_impl(self) /= null and then
       not is_null(request)
    then
      retire_target_request (deferred_impl(self), request, cause);
    end if;
  end retire_deferred;

  procedure set_deferred_connection_busy
    (self          : in out Context;
     connection_id : Connection_Identity;
     busy          : Boolean)
  is
  begin
    if self.initialized and then deferred_impl(self) /= null and then
       connection_id /= NO_CONNECTION_IDENTITY
    then
      deferred_impl(self).state.all.set_connection_busy (connection_id, busy);
      signal_deferred_waiters (deferred_impl(self).all);
    end if;
  end set_deferred_connection_busy;

  procedure sync_deferred_connection
    (self          : in out Context;
     connection_id : Connection_Identity;
     pending       : Natural)
  is
  begin
    if self.initialized and then deferred_impl(self) /= null and then
       connection_id /= NO_CONNECTION_IDENTITY
    then
      deferred_impl(self).state.all.sync_connection (connection_id, pending);
      signal_deferred_waiters (deferred_impl(self).all);
    end if;
  end sync_deferred_connection;

  procedure sync_deferred_request
    (self    : in out Context;
     request : Identity;
     pending : Natural)
  is
  begin
    if self.initialized and then deferred_impl(self) /= null and then
       not is_null(request)
    then
      deferred_impl(self).state.all.sync_request (request, pending);
      signal_deferred_waiters (deferred_impl(self).all);
    end if;
  end sync_deferred_request;

  function deferred_pending_bytes
    (self    : Context;
     request : Identity) return Natural
  is
  begin
    if not self.initialized or else deferred_impl(self) = null then
      return 0;
    end if;
    return deferred_impl(self).state.all.pending_for_request (request);
  end deferred_pending_bytes;

  function deferred_connection_pending_bytes
    (self          : Context;
     connection_id : Connection_Identity) return Natural
  is
  begin
    if not self.initialized or else deferred_impl(self) = null then
      return 0;
    end if;
    return deferred_impl(self).state.all.pending_for_connection (connection_id);
  end deferred_connection_pending_bytes;

  function is_initialized (self : Context) return Boolean is
  begin
    return self.initialized;
  end is_initialized;

  function is_accepting (self : Context) return Boolean is
  begin
    return self.initialized and then
      self.admission.is_accepting and then
      Pool.is_accepting(self.workers);
  end is_accepting;

  function is_idle (self : Context) return Boolean is
  begin
    return self.initialized and then
      Pool.is_idle(self.workers) and then
      self.delivery_job = null and then
      self.deferred_delivery_job = null and then
      (deferred_impl(self) = null or else
       not deferred_impl(self).state.all.has_writable_waiter);
  end is_idle;

  function pending_count (self : Context) return Natural is
  begin
    return Pool.pending_count (self.workers);
  end pending_count;

  function active_count (self : Context) return Natural is
  begin
    return Pool.active_count (self.workers);
  end active_count;

  function completed_count (self : Context) return Natural is
  begin
    return Pool.completed_count (self.workers) +
      (if self.delivery_job = null then 0 else 1) +
      (if self.deferred_delivery_job = null then 0 else 1);
  end completed_count;

  function handle_notification
    (self   : aliased in out Context;
     source : Clair.Event_Loop.Source_Handle) return Clair.Status.Code
  is
    job              : Work_Item_Access;
    callback_status  : Clair.Status.Code;
    handler_status   : Clair.Status.Code;
    capacity_status  : Clair.Status.Code;
    status           : Clair.Status.Code;
    available        : Boolean;
    completion_value  : Completion (executor_owned => True);
    command           : Deferred_Command;
    target            : Deferred_Target_Impl_Access;
    capacity_attempts   : Natural := 0;
    completion_attempts : Natural := 0;
    deferred_attempts   : Natural := 0;
    writable_attempts   : Natural := 0;
    writable_request    : Identity := NULL_IDENTITY;
    writable_waiter     : Deferred_Writable_Waiter_Access := null;
    delivery_budget     : Natural := COMPLETION_BYTES_PER_NOTIFICATION;

    function ordinary_record_length
      (work   : not null Work_Item_Access;
       offset : Natural) return Natural
    is
      available      : Natural;
      content_length : Natural;
      record_length  : Natural;
    begin
      if offset > work.response.length then
        raise Program_Error with "completion delivery offset exceeds output";
      end if;
      available := work.response.length - offset;
      if available < P.HEADER_LENGTH then
        raise Program_Error with "completion output ends inside FastCGI header";
      end if;

      content_length :=
        Natural(buffered_byte(work.response, offset + 5)) * 256 +
        Natural(buffered_byte(work.response, offset + 6));
      record_length := P.HEADER_LENGTH + content_length +
        Natural(buffered_byte(work.response, offset + 7));
      if record_length > available then
        raise Program_Error with "completion output ends inside FastCGI record";
      end if;
      return record_length;
    end ordinary_record_length;

    procedure prepare_ordinary_slice
      (budget : in Natural;
       value  : in out Completion;
       ready  : out Boolean)
    is
      work   : constant Work_Item_Access := self.delivery_job;
      total  : Natural;
      cursor : Natural;
      length : Natural := 0;
      record_length : Natural;
    begin
      ready := False;
      value.item := null;
      value.deferred_output := False;
      value.delivery_offset := 0;
      value.delivery_length := 0;
      value.delivery_is_final := True;
      if work = null then
        return;
      end if;

      value.item := work;
      value.deferred_output := False;

      if self.delivery_status /= Clair.Status.OK or else
         work.response.failed
      then
        value.delivery_offset := 0;
        value.delivery_length := 0;
        value.delivery_is_final := True;
        ready := True;
        return;
      end if;

      total := work.response.length;
      if self.delivery_offset = total then
        value.delivery_offset := self.delivery_offset;
        value.delivery_length := 0;
        value.delivery_is_final := True;
        ready := True;
        return;
      elsif self.delivery_offset > total or else budget = 0 then
        return;
      end if;

      cursor := self.delivery_offset;
      while cursor < total loop
        record_length := ordinary_record_length (work, cursor);
        if record_length > budget - length then
          exit;
        end if;
        length := length + record_length;
        cursor := cursor + record_length;
      end loop;

      if length = 0 then
        return;
      end if;

      value.delivery_offset := self.delivery_offset;
      value.delivery_length := length;
      value.delivery_is_final := self.delivery_offset + length = total;
      ready := True;
    end prepare_ordinary_slice;

    procedure prepare_deferred_slice
      (budget       : in Natural;
       value        : in out Completion;
       encoded_cost : out Natural;
       ready        : out Boolean)
    is
      work          : constant Work_Item_Access := self.deferred_delivery_job;
      total         : Natural;
      cursor        : Natural;
      raw_length    : Natural := 0;
      chunk_length  : Natural;
      chunk_encoded : Natural;
    begin
      encoded_cost := 0;
      ready := False;
      value.item := null;
      value.deferred_output := True;
      value.delivery_offset := 0;
      value.delivery_length := 0;
      value.delivery_is_final := True;
      if work = null then
        return;
      end if;

      value.item := work;
      value.deferred_output := True;

      if work.deferred_kind = Deferred_Finish_Output then
        encoded_cost := encoded_finish_bytes;
        if encoded_cost > budget then
          encoded_cost := 0;
          return;
        end if;
        value.delivery_offset := 0;
        value.delivery_length := 0;
        value.delivery_is_final := True;
        ready := True;
        return;
      end if;

      total := work.data_length;
      if self.deferred_delivery_offset >= total or else budget = 0 then
        if self.deferred_delivery_offset > total then
          raise Program_Error with
            "deferred delivery offset exceeds staged payload";
        end if;
        return;
      end if;

      cursor := self.deferred_delivery_offset;
      while cursor < total loop
        chunk_length := Natural'Min
          (DEFERRED_OUTPUT_CHUNK_BYTES, total - cursor);
        chunk_encoded := chunk_length + P.HEADER_LENGTH;
        if chunk_encoded > budget - encoded_cost then
          exit;
        end if;
        raw_length := raw_length + chunk_length;
        encoded_cost := encoded_cost + chunk_encoded;
        cursor := cursor + chunk_length;
      end loop;

      if raw_length = 0 then
        encoded_cost := 0;
        return;
      end if;

      value.delivery_offset := self.deferred_delivery_offset;
      value.delivery_length := raw_length;
      value.delivery_is_final :=
        self.deferred_delivery_offset + raw_length = total;
      ready := True;
    end prepare_deferred_slice;

    function finish_notification
      (primary_status : Clair.Status.Code) return Clair.Status.Code
    is
      result         : Clair.Status.Code := primary_status;
      finish_status  : Clair.Status.Code;
      finish_target  : Deferred_Target_Impl_Access;
    begin
      finish_status := Pool.completion_signal_status (self.workers);
      if result = Clair.Status.OK and then finish_status /= Clair.Status.OK then
        result := finish_status;
      end if;

      finish_target := deferred_impl(self);
      if finish_target = null then
        if result = Clair.Status.OK then
          result := Clair.Status.INVALID_STATE;
        end if;
        return result;
      end if;

      finish_status := finish_target.state.all.signal_failure;
      if result = Clair.Status.OK and then finish_status /= Clair.Status.OK then
        result := finish_status;
      end if;

      if self.delivery_job /= null or else
         self.deferred_delivery_job /= null or else
         Pool.completed_count(self.workers) > 0 or else
         finish_target.state.all.has_ready_command or else
         finish_target.state.all.has_ready_writable_waiter or else
         self.capacity_wake_pending
      then
        finish_status := Clair.Event_Loop.Notification.signal
          (finish_target.signaler);
        if finish_status /= Clair.Status.OK then
          finish_target.state.all.note_signal_failure (finish_status);
          if result = Clair.Status.OK then
            result := finish_status;
          end if;
        end if;
      end if;

      return result;
    end finish_notification;

    function drain_capacity_waiters return Clair.Status.Code is
      first_status  : Clair.Status.Code := Clair.Status.OK;
      drain_status  : Clair.Status.Code;
      re_registered : Boolean := False;
    begin
      self.capacity_wake_pending := False;

      while capacity_attempts < MAX_ITEMS_PER_NOTIFICATION and then
            self.capacity_wait_head /= null and then
            self.admission.has_capacity
      loop
        capacity_attempts := capacity_attempts + 1;
        drain_status := wake_capacity_waiter (self, re_registered);
        if first_status = Clair.Status.OK and then
           drain_status /= Clair.Status.OK
        then
          first_status := drain_status;
        end if;

        exit when re_registered;
      end loop;

      if capacity_attempts = MAX_ITEMS_PER_NOTIFICATION and then
         not re_registered and then
         self.capacity_wait_head /= null and then
         self.admission.has_capacity
      then
        self.capacity_wake_pending := True;
      end if;

      return first_status;
    end drain_capacity_waiters;
  begin
    if not self.initialized or else
       source /= self.notification_source
    then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.capacity_wake_pending then
      capacity_status := drain_capacity_waiters;
      if capacity_status /= Clair.Status.OK then
        return finish_notification (capacity_status);
      end if;
    end if;

    while completion_attempts < MAX_ITEMS_PER_NOTIFICATION loop
      capacity_status := Clair.Status.OK;

      if self.delivery_job = null then
        status := Pool.try_take_completed
          (self            => self.workers,
           job             => job,
           callback_status => callback_status,
           available       => available);

        if status /= Clair.Status.OK then
          return finish_notification (status);
        end if;
        exit when not available;

        self.admission.release (job.request_value);
        capacity_status := drain_capacity_waiters;
        self.delivery_job := job;
        self.delivery_status := callback_status;
        self.delivery_offset := 0;
      end if;

      declare
        slice_ready : Boolean;
        slice_final : Boolean;
      begin
        prepare_ordinary_slice
          (delivery_budget, completion_value, slice_ready);
        exit when not slice_ready;
        slice_final := completion_value.delivery_is_final;

        begin
          handler_status := self.delivery_job.completion_handler.on_completion
            (completion_value, self.delivery_status);
        exception
          when others =>
            handler_status := Clair.Status.CALLBACK_FAILED;
        end;

        if handler_status = Clair.Status.OK then
          self.delivery_offset :=
            self.delivery_offset + completion_value.delivery_length;
        end if;

        if handler_status /= Clair.Status.OK or else slice_final then
          target := deferred_impl(self);
          if target /= null then
            if handler_status = Clair.Status.OK then
              target.state.all.bind_handler
                (self.delivery_job.request_value,
                 self.delivery_job.completion_handler);
            else
              retire_target_request
                (target, self.delivery_job.request_value, Not_Cancelled);
            end if;
          end if;

          Free_Work_Item (self.delivery_job);
          self.delivery_job := null;
          self.delivery_status := Clair.Status.OK;
          self.delivery_offset := 0;
          completion_attempts := completion_attempts + 1;
        end if;

        if completion_value.delivery_length > delivery_budget then
          raise Program_Error with "completion delivery budget underflow";
        end if;
        delivery_budget :=
          delivery_budget - completion_value.delivery_length;
        completion_value.item := null;
        completion_value.deferred_output := False;
        completion_value.delivery_offset := 0;
        completion_value.delivery_length := 0;
        completion_value.delivery_is_final := True;

        if capacity_status /= Clair.Status.OK then
          return finish_notification (capacity_status);
        elsif handler_status /= Clair.Status.OK then
          return finish_notification (handler_status);
        end if;

        exit when self.delivery_job /= null or else delivery_budget = 0;
      end;
    end loop;

    target := deferred_impl(self);
    if target /= null then
      while deferred_attempts < MAX_ITEMS_PER_NOTIFICATION loop
        if self.deferred_delivery_job = null then
          target.state.all.try_take (command, available);
          exit when not available;

          job := command.item;
          if job = null then
            target.state.all.finish_processing (command.request);
            target.state.all.set_connection_busy
              (command.request.connection_id, False);
            raise Program_Error with "missing staged deferred output";
          end if;

          self.deferred_delivery_job := job;
          self.deferred_delivery_offset := 0;
        end if;

        if not target.state.all.requested
          (self.deferred_delivery_job.request_value)
        then
          declare
            request : constant Identity :=
              self.deferred_delivery_job.request_value;
          begin
            Free_Work_Item (self.deferred_delivery_job);
            self.deferred_delivery_job := null;
            self.deferred_delivery_offset := 0;
            target.state.all.finish_processing (request);
            target.state.all.set_connection_busy (request.connection_id, False);
            deferred_attempts := deferred_attempts + 1;
          end;
        else
          declare
            slice_ready  : Boolean;
            slice_final  : Boolean;
            encoded_cost : Natural;
            request      : constant Identity :=
              self.deferred_delivery_job.request_value;
          begin
            prepare_deferred_slice
              (delivery_budget, completion_value, encoded_cost, slice_ready);
            exit when not slice_ready;
            slice_final := completion_value.delivery_is_final;

            target.state.all.consume_processing_bytes (request, encoded_cost);

            begin
              handler_status :=
                self.deferred_delivery_job.completion_handler.on_completion
                  (completion_value, Clair.Status.OK);
            exception
              when others =>
                handler_status := Clair.Status.CALLBACK_FAILED;
            end;

            if handler_status = Clair.Status.OK then
              self.deferred_delivery_offset :=
                self.deferred_delivery_offset +
                  completion_value.delivery_length;
            end if;

            if encoded_cost > delivery_budget then
              raise Program_Error with
                "deferred delivery budget underflow";
            end if;
            delivery_budget := delivery_budget - encoded_cost;

            if handler_status /= Clair.Status.OK then
              retire_target_request (target, request, Not_Cancelled);
              Free_Work_Item (self.deferred_delivery_job);
              self.deferred_delivery_job := null;
              self.deferred_delivery_offset := 0;
              target.state.all.finish_processing (request);
              target.state.all.set_connection_busy
                (request.connection_id, False);
              completion_value.item := null;
              return finish_notification (handler_status);
            elsif slice_final then
              Free_Work_Item (self.deferred_delivery_job);
              self.deferred_delivery_job := null;
              self.deferred_delivery_offset := 0;
              target.state.all.finish_processing (request);
              target.state.all.set_connection_busy
                (request.connection_id, False);
              deferred_attempts := deferred_attempts + 1;
            end if;

            completion_value.item := null;
            completion_value.deferred_output := False;
            completion_value.delivery_offset := 0;
            completion_value.delivery_length := 0;
            completion_value.delivery_is_final := True;

            exit when self.deferred_delivery_job /= null or else
              delivery_budget = 0;
          end;
        end if;
      end loop;
    end if;

    target := deferred_impl(self);
    if target /= null then
      while writable_attempts < MAX_ITEMS_PER_NOTIFICATION loop
        target.state.all.try_take_writable_waiter
          (writable_request, writable_waiter, available);
        exit when not available;
        writable_attempts := writable_attempts + 1;

        begin
          on_deferred_writable (writable_waiter.all, writable_request);
          handler_status := Clair.Status.OK;
        exception
          when others =>
            handler_status := Clair.Status.CALLBACK_FAILED;
        end;

        target.state.all.finish_writable_waiter (writable_request);
        writable_waiter := null;
        writable_request := NULL_IDENTITY;

        if handler_status /= Clair.Status.OK then
          return finish_notification (handler_status);
        end if;
      end loop;
    end if;

    return finish_notification (Clair.Status.OK);
  end handle_notification;

  function on_notification
    (self   : in out Notification_Adapter;
     source : Clair.Event_Loop.Source_Handle) return Clair.Status.Code
  is
  begin
    if self.owner = null then
      return Clair.Status.INVALID_STATE;
    end if;

    return handle_notification (self.owner.all, source);
  end on_notification;

end Fasyn.Request.Execution;
