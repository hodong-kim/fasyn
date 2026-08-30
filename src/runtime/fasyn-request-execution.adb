-- ============================================================================
-- fasyn-request-execution.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Unchecked_Deallocation;
with Fasyn.Protocol.Messages;

package body Fasyn.Request.Execution is

  package P renames Fasyn.Protocol;
  package M renames Fasyn.Protocol.Messages;

  use type Clair.Event_Loop.Context_Access;
  use type Clair.Event_Loop.Handle;
  use type Clair.Event_Loop.Milliseconds;
  use type Clair.Status.Code;
  use type Fasyn.Protocol.Role;

  MAX_COMPLETIONS_PER_TICK : constant Positive := 64;

  procedure Free_Admission is new Ada.Unchecked_Deallocation
    (Object => Admission_State,
     Name   => Admission_State_Access);

  procedure Free_Work_Item is new Ada.Unchecked_Deallocation
    (Object => Work_Item,
     Name   => Work_Item_Access);

  type Deferred_Entry_State is
    (Deferred_Empty, Deferred_Pending, Deferred_Active, Deferred_Retired);

  type Deferred_Entry is record
    request            : Request_Identity := NULL_REQUEST_IDENTITY;
    state              : Deferred_Entry_State := Deferred_Empty;
    cause              : Cancellation_Cause := Not_Cancelled;
    handler            : Completion_Handler_Access := null;
    request_pending    : Natural := 0;
    request_limit      : Positive := 1;
    connection_pending : Natural := 0;
    connection_limit   : Positive := 1;
    connection_busy    : Boolean := True;
    handle_present     : Boolean := False;
    command_pending    : Boolean := False;
    terminal_pending   : Boolean := False;
    processing         : Boolean := False;
    command_item       : Work_Item_Access := null;
    encoded_bytes      : Natural := 0;
  end record;

  type Deferred_Command is record
    request : Request_Identity := NULL_REQUEST_IDENTITY;
    item    : Work_Item_Access := null;
  end record;

  type Deferred_Entry_Array is array (Positive range <>) of Deferred_Entry;

  protected type Deferred_State
    (capacity         : Positive;
     max_output_bytes : Positive)
  is
    procedure retain;
    procedure release_reference (last : out Boolean);
    procedure release_handle
      (request : in Request_Identity;
       last    : out Boolean);
    procedure request_defer
      (request : in Request_Identity;
       result  : out Target_Defer_Result);
    procedure reserve_submit
      (request  : in Request_Identity;
       encoded  : in Natural;
       terminal : in Boolean;
       status   : out Deferred_Write_Status);
    procedure abort_submit (request : in Request_Identity);
    procedure commit_submit
      (request  : in Request_Identity;
       item     : in Work_Item_Access;
       accepted : out Boolean);
    function cancellation_reason
      (request : Request_Identity) return Cancellation_Cause;
    function requested (request : Request_Identity) return Boolean;
    procedure activate
      (request            : in Request_Identity;
       request_pending    : in Natural;
       request_limit      : in Positive;
       connection_pending : in Natural;
       connection_limit   : in Positive;
       success            : out Boolean);
    procedure bind_handler
      (request : in Request_Identity;
       handler : in Completion_Handler_Access);
    procedure retire
      (request   : in Request_Identity;
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
      (request : in Request_Identity;
       pending : in Natural);
    function pending_for_request
      (request : Request_Identity) return Natural;
    function pending_for_connection
      (connection_id : Connection_Identity) return Natural;
    procedure try_take
      (command : out Deferred_Command;
       success : out Boolean);
    procedure finish_processing (request : in Request_Identity);
  private
    entries            : Deferred_Entry_Array (1 .. capacity);
    references         : Natural := 1;
    accepting          : Boolean := True;
    next_command_index : Positive := 1;
  end Deferred_State;

  type Deferred_Target_Impl
    (capacity         : Positive;
     max_output_bytes : Positive)
  is limited new Deferred_Target with record
    state : Deferred_State
      (capacity => capacity, max_output_bytes => max_output_bytes);
  end record;

  overriding procedure retain (self : in out Deferred_Target_Impl);
  overriding procedure release_reference
    (self : in out Deferred_Target_Impl; last : out Boolean);
  overriding procedure release_handle
    (self : in out Deferred_Target_Impl; request : in Request_Identity;
     last : out Boolean);
  overriding procedure request_defer
    (self : in out Deferred_Target_Impl; request : in Request_Identity;
     result : out Target_Defer_Result);
  overriding procedure submit_deferred
    (self : in out Deferred_Target_Impl; request : in Request_Identity;
     operation : in Deferred_Command_Kind; data : in P.Byte_Array;
     application_status : in Interfaces.Unsigned_32;
     status : out Deferred_Write_Status);
  overriding procedure cancel_deferred
    (self : in out Deferred_Target_Impl; request : in Request_Identity;
     cause : in Cancellation_Cause);
  overriding function target_cancellation_reason
    (self : Deferred_Target_Impl; request : Request_Identity)
     return Cancellation_Cause;

  type Deferred_Target_Impl_Access is access all Deferred_Target_Impl;

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
    return 3 * P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH;
  end encoded_finish_bytes;

  protected body Deferred_State is

    function is_live (index : Positive) return Boolean is
    begin
      return entries(index).state = Deferred_Pending or else
        entries(index).state = Deferred_Active;
    end is_live;

    function find_index (request : Request_Identity) return Natural is
    begin
      for index in entries'range loop
        if entries(index).state /= Deferred_Empty and then
           entries(index).request = request
        then
          return index;
        end if;
      end loop;
      return 0;
    end find_index;

    procedure clear_entry (index : Positive) is
    begin
      if entries(index).command_item /= null then
        raise Program_Error with "deferred entry cleared while owning output";
      end if;
      entries(index) := (others => <>);
    end clear_entry;

    function staged_for_connection
      (connection_id : Connection_Identity) return Natural
    is
      total : Natural := 0;
    begin
      for index in entries'range loop
        if entries(index).state /= Deferred_Empty and then
           entries(index).request.connection_id = connection_id and then
           entries(index).command_pending
        then
          if entries(index).encoded_bytes > Natural'Last - total then
            return Natural'Last;
          end if;
          total := total + entries(index).encoded_bytes;
        end if;
      end loop;
      return total;
    end staged_for_connection;

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
      (request : in Request_Identity;
       last    : out Boolean)
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 then
        entries(index).handle_present := False;
        if entries(index).state = Deferred_Retired and then
           not entries(index).processing and then
           entries(index).command_item = null
        then
          clear_entry (Positive(index));
        end if;
      end if;
      release_reference (last);
    end release_handle;

    procedure request_defer
      (request : in Request_Identity;
       result  : out Target_Defer_Result)
    is
      free_index : Natural := 0;
    begin
      if not accepting or else
         is_null(request) or else
         find_index(request) /= 0
      then
        result := Target_Defer_Not_Ready;
        return;
      end if;

      for index in entries'range loop
        if entries(index).state = Deferred_Empty then
          free_index := index;
          exit;
        end if;
      end loop;

      if free_index = 0 then
        result := Target_Defer_Capacity_Exceeded;
        return;
      end if;

      entries(free_index).request := request;
      entries(free_index).state := Deferred_Pending;
      entries(free_index).handle_present := True;
      entries(free_index).connection_busy := True;
      result := Target_Defer_Complete;
    end request_defer;

    procedure reserve_submit
      (request  : in Request_Identity;
       encoded  : in Natural;
       terminal : in Boolean;
       status   : out Deferred_Write_Status)
    is
      index : constant Natural := find_index(request);
      connection_use : Natural;
    begin
      if index = 0 or else entries(index).state = Deferred_Retired or else
         entries(index).terminal_pending
      then
        status := Deferred_Closed; return;
      end if;
      if entries(index).state /= Deferred_Active or else
         entries(index).handler = null or else
         entries(index).connection_busy or else
         entries(index).command_pending or else
         entries(index).processing
      then
        status := Deferred_Would_Block; return;
      end if;
      if encoded > max_output_bytes or else
         encoded > entries(index).request_limit or else
         encoded > entries(index).connection_limit
      then
        status := Deferred_Output_Limit_Exceeded; return;
      end if;
      if entries(index).request_pending > entries(index).request_limit then
        status := Deferred_Closed; return;
      end if;
      if encoded >
           entries(index).request_limit -
             entries(index).request_pending
      then
        status := Deferred_Would_Block; return;
      end if;
      connection_use := staged_for_connection(request.connection_id);
      if entries(index).connection_pending >
           entries(index).connection_limit or else
         connection_use >
           entries(index).connection_limit -
             entries(index).connection_pending or else
         encoded >
           entries(index).connection_limit -
             entries(index).connection_pending -
             connection_use
      then
        status := Deferred_Would_Block; return;
      end if;
      entries(index).encoded_bytes := encoded;
      entries(index).command_pending := True;
      entries(index).terminal_pending := terminal;
      status := Deferred_Write_Complete;
    end reserve_submit;

    procedure abort_submit (request : in Request_Identity) is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then
         entries(index).command_pending and then
         entries(index).command_item = null and then
         not entries(index).processing
      then
        entries(index).command_pending := False;
        entries(index).terminal_pending := False;
        entries(index).encoded_bytes := 0;
      end if;
    end abort_submit;

    procedure commit_submit
      (request  : in Request_Identity;
       item     : in Work_Item_Access;
       accepted : out Boolean)
    is
      index : constant Natural := find_index(request);
    begin
      accepted := False;
      if index /= 0 and then
         is_live(Positive(index)) and then
         entries(index).command_pending and then
         entries(index).command_item = null and then
         not entries(index).processing
      then
        item.completion_handler := entries(index).handler;
        entries(index).command_item := item;
        accepted := True;
      end if;
    end commit_submit;

    function cancellation_reason
      (request : Request_Identity) return Cancellation_Cause
    is
      index : constant Natural := find_index(request);
    begin
      if index = 0 then
        return Not_Cancelled;
      end if;
      return entries(index).cause;
    end cancellation_reason;

    function requested (request : Request_Identity) return Boolean is
      index : constant Natural := find_index(request);
    begin
      return index /= 0 and then
        (entries(index).state = Deferred_Pending or else
         entries(index).state = Deferred_Active);
    end requested;

    procedure activate
      (request            : in Request_Identity;
       request_pending    : in Natural;
       request_limit      : in Positive;
       connection_pending : in Natural;
       connection_limit   : in Positive;
       success            : out Boolean)
    is
      index : constant Natural := find_index(request);
    begin
      if not accepting or else index = 0 or else
         entries(index).state /= Deferred_Pending or else
         request_pending > request_limit or else
         connection_pending > connection_limit
      then
        success := False;
        return;
      end if;

      entries(index).request_pending := request_pending;
      entries(index).request_limit := request_limit;
      entries(index).connection_pending := connection_pending;
      entries(index).connection_limit := connection_limit;
      entries(index).state := Deferred_Active;
      success := True;
    end activate;

    procedure bind_handler
      (request : in Request_Identity;
       handler : in Completion_Handler_Access)
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then entries(index).state = Deferred_Active then
        entries(index).handler := handler;
      end if;
    end bind_handler;

    procedure retire
      (request   : in Request_Identity;
       cause     : in Cancellation_Cause;
       discarded : out Work_Item_Access)
    is
      index : constant Natural := find_index(request);
    begin
      discarded := null;
      if index = 0 then
        return;
      end if;

      if entries(index).state = Deferred_Retired then
        return;
      end if;

      if cause /= Not_Cancelled and then
         entries(index).cause = Not_Cancelled
      then
        entries(index).cause := cause;
      end if;
      entries(index).state := Deferred_Retired;
      entries(index).handler := null;
      if entries(index).command_pending then
        discarded := entries(index).command_item;
        entries(index).command_item := null;
        entries(index).command_pending := False;
        entries(index).encoded_bytes := 0;
      end if;

      if not entries(index).handle_present and then
         not entries(index).processing and then discarded = null
      then
        clear_entry (Positive(index));
      end if;
    end retire;

    procedure shutdown is
    begin
      accepting := False;
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
          if entries(index).command_pending then
            entries(index).command_pending := False;
            entries(index).encoded_bytes := 0;
          end if;
          if not entries(index).handle_present and then
             not entries(index).processing and then
             entries(index).command_item = null
          then
            clear_entry (index);
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
      for index in entries'range loop
        if entries(index).state = Deferred_Retired and then
           entries(index).command_item /= null
        then
          item := entries(index).command_item;
          entries(index).command_item := null;
          if not entries(index).handle_present and then
             not entries(index).processing
          then
            clear_entry (index);
          end if;
          available := True;
          return;
        end if;
      end loop;
    end take_retired_command;

    procedure set_connection_busy
      (connection_id : in Connection_Identity;
       busy          : in Boolean)
    is
    begin
      for index in entries'range loop
        if is_live(index) and then
           entries(index).request.connection_id = connection_id
        then
          entries(index).connection_busy := busy;
        end if;
      end loop;
    end set_connection_busy;

    procedure sync_connection
      (connection_id : in Connection_Identity;
       pending       : in Natural)
    is
    begin
      for index in entries'range loop
        if is_live(index) and then
           entries(index).request.connection_id = connection_id
        then
          entries(index).connection_pending := pending;
        end if;
      end loop;
    end sync_connection;

    procedure sync_request
      (request : in Request_Identity;
       pending : in Natural)
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then is_live(Positive(index)) then
        entries(index).request_pending := pending;
      end if;
    end sync_request;

    function pending_for_request
      (request : Request_Identity) return Natural
    is
      index : constant Natural := find_index(request);
    begin
      if index /= 0 and then entries(index).command_pending then
        return entries(index).encoded_bytes;
      end if;
      return 0;
    end pending_for_request;

    function pending_for_connection
      (connection_id : Connection_Identity) return Natural
    is
    begin
      return staged_for_connection (connection_id);
    end pending_for_connection;

    procedure try_take
      (command : out Deferred_Command;
       success : out Boolean)
    is
      index : Positive := next_command_index;
    begin
      command := (others => <>);
      success := False;

      for attempt in 1 .. capacity loop
        pragma Unreferenced (attempt);
        if entries(index).state = Deferred_Active and then
           entries(index).handler /= null and then
           not entries(index).connection_busy and then
           entries(index).command_pending and then
           entries(index).command_item /= null and then
           not entries(index).processing
        then
          for sibling in entries'range loop
            if entries(sibling).state /= Deferred_Empty and then
               entries(sibling).request.connection_id =
                 entries(index).request.connection_id
            then
              entries(sibling).connection_busy := True;
            end if;
          end loop;

          command.request := entries(index).request;
          command.item := entries(index).command_item;

          entries(index).command_item := null;
          entries(index).command_pending := False;
          entries(index).processing := True;
          entries(index).encoded_bytes := 0;
          if index = capacity then
            next_command_index := 1;
          else
            next_command_index := index + 1;
          end if;
          success := True;
          return;
        end if;

        if index = capacity then
          index := 1;
        else
          index := index + 1;
        end if;
      end loop;
    end try_take;

    procedure finish_processing (request : in Request_Identity) is
      index : constant Natural := find_index(request);
    begin
      if index = 0 then
        return;
      end if;
      entries(index).processing := False;
      if entries(index).state = Deferred_Retired and then
         not entries(index).handle_present
      then
        clear_entry (Positive(index));
      end if;
    end finish_processing;

  end Deferred_State;

  procedure retain (self : in out Deferred_Target_Impl) is
  begin
    self.state.retain;
  end retain;

  procedure release_reference
    (self : in out Deferred_Target_Impl;
     last : out Boolean)
  is
  begin
    self.state.release_reference (last);
  end release_reference;

  procedure release_handle
    (self    : in out Deferred_Target_Impl;
     request : in Request_Identity;
     last    : out Boolean)
  is
  begin
    self.state.release_handle (request, last);
  end release_handle;

  procedure request_defer
    (self    : in out Deferred_Target_Impl;
     request : in Request_Identity;
     result  : out Target_Defer_Result)
  is
  begin
    self.state.request_defer (request, result);
  end request_defer;

  procedure submit_deferred
    (self               : in out Deferred_Target_Impl;
     request            : in Request_Identity;
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

    self.state.reserve_submit
      (request, encoded, operation = Deferred_Finish, status);
    if status /= Deferred_Write_Complete then
      return;
    end if;

    if encoded = 0 then
      self.state.abort_submit (request);
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
        self.state.abort_submit (request);
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

    self.state.commit_submit (request, item, accepted);
    if not accepted then
      Free_Work_Item (item);
      status := Deferred_Closed;
      return;
    end if;

    status := Deferred_Write_Complete;
  end submit_deferred;

  procedure cancel_deferred
    (self    : in out Deferred_Target_Impl;
     request : in Request_Identity;
     cause   : in Cancellation_Cause)
  is
    discarded : Work_Item_Access;
  begin
    self.state.retire (request, cause, discarded);
    if discarded /= null then
      Free_Work_Item (discarded);
    end if;
  end cancel_deferred;

  function target_cancellation_reason
    (self    : Deferred_Target_Impl;
     request : Request_Identity) return Cancellation_Cause
  is
  begin
    return self.state.cancellation_reason (request);
  end target_cancellation_reason;

  function deferred_impl (self : Context) return Deferred_Target_Impl_Access is
  begin
    if self.deferred_target = null then
      return null;
    end if;
    return Deferred_Target_Impl_Access(self.deferred_target);
  end deferred_impl;

  procedure retire_target_request
    (target  : not null Deferred_Target_Impl_Access;
     request : in Request_Identity;
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
    target.state.shutdown;
    loop
      target.state.take_retired_command (discarded, available);
      exit when not available;
      Free_Work_Item (discarded);
    end loop;
  end shutdown_target;

  protected body Admission_State is

    procedure reserve
      (request  : in Request_Identity;
       context  : in Request_Context_Access;
       accepted : out Boolean)
    is
    begin
      for index in 1 .. count loop
        if identities(index) = request then
          accepted := False;
          return;
        end if;
      end loop;

      if count = capacity then
        accepted := False;
        return;
      end if;

      count := count + 1;
      identities(count) := request;
      contexts(count) := context;
      accepted := True;
    end reserve;

    procedure release (request : in Request_Identity) is
    begin
      for index in 1 .. count loop
        if identities(index) = request then
          identities(index) := identities(count);
          contexts(index) := contexts(count);
          identities(count) := NULL_REQUEST_IDENTITY;
          contexts(count) := null;
          count := count - 1;
          return;
        end if;
      end loop;

      raise Program_Error with "execution admission identity not reserved";
    end release;

    function context_for
      (request : Request_Identity) return Request_Context_Access
    is
    begin
      for index in 1 .. count loop
        if identities(index) = request then
          return contexts(index);
        end if;
      end loop;

      return null;
    end context_for;

    function reserved_count return Natural is
    begin
      return count;
    end reserved_count;

    function context_at (index : Positive) return Request_Context_Access is
    begin
      if index <= count then
        return contexts(index);
      end if;

      return null;
    end context_at;

    function is_empty return Boolean is
    begin
      return count = 0;
    end is_empty;

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

  procedure execute_job (job : in out Work_Item_Access) is
  begin
    case job.operation_value is
      when Deliver_Parameter =>
        on_parameter
          (job.application.all,
           job.callback_context,
           job.name_bytes(1 .. job.name_length),
           job.value_bytes(1 .. job.value_length));

      when Finish_Params =>
        on_params_end
          (job.application.all, job.callback_context, job.response);

      when Deliver_Stdin =>
        on_stdin
          (job.application.all,
           job.callback_context,
           job.data_bytes(1 .. job.data_length),
           job.response);

      when Finish_Stdin =>
        on_stdin_end
          (job.application.all, job.callback_context, job.response);

      when Deliver_Data =>
        on_data
          (job.application.all,
           job.callback_context,
           job.data_bytes(1 .. job.data_length),
           job.response);

      when Finish_Data =>
        on_data_end
          (job.application.all, job.callback_context, job.response);
    end case;
  end execute_job;

  function valid_submission
    (self               : Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural) return Boolean
  is
  begin
    return self.initialized and then
      not is_null(request) and then
      application /= null and then
      completion_handler /= null and then
      output_limit <= self.max_output_bytes;
  end valid_submission;

  procedure prepare_item
    (item               : in out Work_Item;
     request            : Request_Identity;
     role               : Fasyn.Protocol.Role;
     operation          : Operation_Kind;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural;
     deferred_target    : Deferred_Target_Access)
  is
    allow_defer : constant Boolean :=
      (operation = Finish_Params and then role = P.Authorizer) or else
      (operation = Finish_Stdin and then role = P.Responder) or else
      (operation = Finish_Data and then role = P.Filter);
  begin
    item.request_value := request;
    initialize_request_context
      (item.callback_context, request, role, deferred_target, allow_defer);
    item.operation_value := operation;
    item.application := application;
    item.completion_handler := completion_handler;
    item.response.length := 0;
    item.response.limit := output_limit;
    item.response.request_id := request.request_id;
    item.response.initialized := True;
    item.response.finished := False;
    item.response.failed := False;
  end prepare_item;

  function submit_item
    (self     : in out Context;
     item     : in out Work_Item_Access;
     accepted : out Boolean) return Clair.Status.Code
  is
    request  : constant Request_Identity := item.request_value;
    reserved : Boolean;
    status   : Clair.Status.Code;
  begin
    self.admission.reserve
      (request,
       item.callback_context'Unchecked_Access,
       reserved);

    if not reserved then
      accepted := False;
      Free_Work_Item (item);
      return Clair.Status.OK;
    end if;

    status := Pool.submit (self.workers, item, accepted);

    if status /= Clair.Status.OK or else not accepted then
      self.admission.release (request);
      Free_Work_Item (item);
    end if;

    return status;
  end submit_item;

  function initialize
    (self             : in out Context;
     event_loop       : Clair.Event_Loop.Context_Access;
     worker_count     : Positive;
     pending_capacity : Positive;
     max_input_bytes  : Positive;
     max_output_bytes  : Positive;
     poll_interval     : Clair.Event_Loop.Milliseconds := 1;
     deferred_capacity : Positive := DEFAULT_DEFERRED_CAPACITY)
     return Clair.Status.Code
  is
    admission_capacity : Positive;
    status             : Clair.Status.Code;
    cleanup_status     : Clair.Status.Code;
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if event_loop = null or else poll_interval <= 0 then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    begin
      admission_capacity := worker_count + pending_capacity;
    exception
      when Constraint_Error =>
        return Clair.Status.RANGE_ERROR;
    end;

    status := Pool.initialize
      (self             => self.workers,
       worker_count     => worker_count,
       pending_capacity => pending_capacity);

    if status /= Clair.Status.OK then
      return status;
    end if;

    self.pool_initialized := True;

    begin
      self.admission := new Admission_State
        (capacity => admission_capacity);
    exception
      when Storage_Error =>
        cleanup_status := Pool.begin_shutdown (self.workers);
        if cleanup_status = Clair.Status.OK then
          cleanup_status := Pool.finalize (self.workers);
        end if;
        self.pool_initialized := False;
        return Clair.Status.OUT_OF_MEMORY;
    end;

    begin
      self.deferred_target := new Deferred_Target_Impl
        (capacity         => deferred_capacity,
         max_output_bytes => max_output_bytes);
    exception
      when Storage_Error =>
        cleanup_status := Pool.begin_shutdown (self.workers);
        if cleanup_status = Clair.Status.OK then
          cleanup_status := Pool.finalize (self.workers);
        end if;
        Free_Admission (self.admission);
        self.pool_initialized := False;
        return Clair.Status.OUT_OF_MEMORY;
    end;

    status := Clair.Event_Loop.add_timer
      (self     => event_loop.all,
       interval => poll_interval,
       handler  => self'Unchecked_Access,
       one_shot => False,
       source   => self.timer);

    if status /= Clair.Status.OK then
      cleanup_status := Pool.begin_shutdown (self.workers);
      if cleanup_status = Clair.Status.OK then
        cleanup_status := Pool.finalize (self.workers);
      end if;
      Free_Admission (self.admission);
      release_target (self.deferred_target);
      self.pool_initialized := False;
      return status;
    end if;

    self.event_loop := event_loop;
    self.max_input_bytes := max_input_bytes;
    self.max_output_bytes := max_output_bytes;
    self.timer_active := True;
    self.initialized := True;
    return Clair.Status.OK;
  end initialize;

  function begin_shutdown
    (self : in out Context) return Clair.Status.Code
  is
    context : Request_Context_Access;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.admission.reserved_count > 0 then
      for index in 1 .. self.admission.reserved_count loop
        context := self.admission.context_at(index);
        if context /= null then
          signal_cancellation (context.all, Runtime_Shutdown);
        end if;
      end loop;
    end if;

    if deferred_impl(self) /= null then
      shutdown_target (deferred_impl(self));
    end if;

    return Pool.begin_shutdown (self.workers);
  end begin_shutdown;

  function signal_cancellation
    (self    : in out Context;
     request : Request_Identity;
     cause   : Cancellation_Cause) return Clair.Status.Code
  is
    context : Request_Context_Access;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if is_null(request) or else cause = Not_Cancelled then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    context := self.admission.context_for(request);
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
       not self.admission.is_empty
    then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.timer_active then
      status := Clair.Event_Loop.remove (self.event_loop.all, self.timer);
      if status /= Clair.Status.OK then
        return status;
      end if;
      self.timer_active := False;
    end if;

    status := Pool.finalize (self.workers);
    if status /= Clair.Status.OK then
      return status;
    end if;

    Free_Admission (self.admission);
    release_target (self.deferred_target);
    self.pool_initialized := False;
    self.event_loop := null;
    self.initialized := False;
    return Clair.Status.OK;
  end finalize;

  function submit_parameter
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     name               : Fasyn.Protocol.Byte_Array;
     value              : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
  begin
    accepted := False;

    if not valid_submission
      (self, request, application, completion_handler, output_limit)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if name'length > self.max_input_bytes or else
       value'length > self.max_input_bytes - name'length
    then
      return Clair.Status.RANGE_ERROR;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => Positive'Max (1, name'length),
         value_capacity  => Positive'Max (1, value'length),
         data_capacity   => 1,
         output_capacity => self.max_output_bytes);
    exception
      when Storage_Error =>
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       role,
       Deliver_Parameter,
       application,
       completion_handler,
       output_limit,
       self.deferred_target);
    copy_bytes (name, item.name_bytes, item.name_length);
    copy_bytes (value, item.value_bytes, item.value_length);
    return submit_item (self, item, accepted);
  end submit_parameter;

  function submit_params_end
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
  begin
    accepted := False;

    if not valid_submission
      (self, request, application, completion_handler, output_limit)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => 1,
         output_capacity => self.max_output_bytes);
    exception
      when Storage_Error =>
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
       self.deferred_target);
    return submit_item (self, item, accepted);
  end submit_params_end;

  function submit_stdin
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
  begin
    accepted := False;

    if not valid_submission
      (self, request, application, completion_handler, output_limit)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if data'length = 0 or else data'length > self.max_input_bytes then
      return Clair.Status.RANGE_ERROR;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => data'length,
         output_capacity => self.max_output_bytes);
    exception
      when Storage_Error =>
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
       self.deferred_target);
    copy_bytes (data, item.data_bytes, item.data_length);
    return submit_item (self, item, accepted);
  end submit_stdin;

  function submit_stdin_end
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
  begin
    accepted := False;

    if not valid_submission
      (self, request, application, completion_handler, output_limit)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => 1,
         output_capacity => self.max_output_bytes);
    exception
      when Storage_Error =>
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
       self.deferred_target);
    return submit_item (self, item, accepted);
  end submit_stdin_end;

  function submit_data
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Filter)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
  begin
    accepted := False;

    if role /= Fasyn.Protocol.Filter or else
       not valid_submission
         (self, request, application, completion_handler, output_limit)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    if data'length = 0 or else data'length > self.max_input_bytes then
      return Clair.Status.RANGE_ERROR;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => data'length,
         output_capacity => self.max_output_bytes);
    exception
      when Storage_Error =>
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       role,
       Deliver_Data,
       application,
       completion_handler,
       output_limit,
       self.deferred_target);
    copy_bytes (data, item.data_bytes, item.data_length);
    return submit_item (self, item, accepted);
  end submit_data;

  function submit_data_end
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Filter)
     return Clair.Status.Code
  is
    item : Work_Item_Access;
  begin
    accepted := False;

    if role /= Fasyn.Protocol.Filter or else
       not valid_submission
         (self, request, application, completion_handler, output_limit)
    then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    begin
      item := new Work_Item
        (name_capacity   => 1,
         value_capacity  => 1,
         data_capacity   => 1,
         output_capacity => self.max_output_bytes);
    exception
      when Storage_Error =>
        return Clair.Status.OUT_OF_MEMORY;
    end;

    prepare_item
      (item.all,
       request,
       role,
       Finish_Data,
       application,
       completion_handler,
       output_limit,
       self.deferred_target);
    return submit_item (self, item, accepted);
  end submit_data_end;

  function completion_request (item : Completion) return Request_Identity is
  begin
    return item.item.request_value;
  end completion_request;

  function operation (item : Completion) return Operation_Kind is
  begin
    return item.item.operation_value;
  end operation;

  function output_length (item : Completion) return Natural is
  begin
    return item.item.response.length;
  end output_length;

  function output_byte
    (item  : Completion;
     index : Positive) return Fasyn.Protocol.Byte
  is
  begin
    return item.item.response.bytes(index);
  end output_byte;

  function output_finished (item : Completion) return Boolean is
  begin
    return item.item.response.finished;
  end output_finished;

  function output_failed (item : Completion) return Boolean is
  begin
    return item.item.response.failed;
  end output_failed;

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
    return item.item.data_length;
  end deferred_data_length;

  procedure copy_deferred_data
    (item   : in Completion;
     offset : in Natural;
     target : out P.Byte_Array;
     copied : out Natural)
  is
    count : Natural;
  begin
    copied := 0;
    if not item.deferred_output or else item.item = null then
      raise Program_Error with "completion is not deferred output";
    end if;
    if offset >= item.item.data_length or else target'length = 0 then
      return;
    end if;
    count := Natural'Min (target'length, item.item.data_length - offset);
    for index in 0 .. count - 1 loop
      target(target'first + index) := item.item.data_bytes(offset + index + 1);
    end loop;
    copied := count;
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
     request : Request_Identity) return Boolean
  is
  begin
    return self.initialized and then deferred_impl(self) /= null and then
      deferred_impl(self).state.requested(request);
  end deferred_requested;

  function activate_deferred
    (self               : in out Context;
     request            : Request_Identity;
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

    deferred_impl(self).state.activate
      (request, request_pending, request_limit,
       connection_pending, connection_limit, success);
    if not success then
      return Clair.Status.INVALID_STATE;
    end if;
    return Clair.Status.OK;
  end activate_deferred;

  procedure retire_deferred
    (self    : in out Context;
     request : Request_Identity;
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
      deferred_impl(self).state.set_connection_busy (connection_id, busy);
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
      deferred_impl(self).state.sync_connection (connection_id, pending);
    end if;
  end sync_deferred_connection;

  procedure sync_deferred_request
    (self    : in out Context;
     request : Request_Identity;
     pending : Natural)
  is
  begin
    if self.initialized and then deferred_impl(self) /= null and then
       not is_null(request)
    then
      deferred_impl(self).state.sync_request (request, pending);
    end if;
  end sync_deferred_request;

  function deferred_pending_bytes
    (self    : Context;
     request : Request_Identity) return Natural
  is
  begin
    if not self.initialized or else deferred_impl(self) = null then
      return 0;
    end if;
    return deferred_impl(self).state.pending_for_request (request);
  end deferred_pending_bytes;

  function deferred_connection_pending_bytes
    (self          : Context;
     connection_id : Connection_Identity) return Natural
  is
  begin
    if not self.initialized or else deferred_impl(self) = null then
      return 0;
    end if;
    return deferred_impl(self).state.pending_for_connection (connection_id);
  end deferred_connection_pending_bytes;

  function is_accepting (self : Context) return Boolean is
  begin
    return self.initialized and then Pool.is_accepting(self.workers);
  end is_accepting;

  function is_idle (self : Context) return Boolean is
  begin
    return self.initialized and then Pool.is_idle(self.workers);
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
    return Pool.completed_count (self.workers);
  end completed_count;

  overriding function on_timer
    (self  : in out Context;
     timer : Clair.Event_Loop.Handle) return Clair.Status.Code
  is
    job              : Work_Item_Access;
    callback_status  : Clair.Status.Code;
    handler_status   : Clair.Status.Code;
    status           : Clair.Status.Code;
    available        : Boolean;
    completion_value : Completion;
    command          : Deferred_Command;
    target           : Deferred_Target_Impl_Access;
  begin
    if not self.initialized or else timer /= self.timer then
      return Clair.Status.INVALID_STATE;
    end if;

    for attempt in 1 .. MAX_COMPLETIONS_PER_TICK loop
      pragma Unreferenced (attempt);

      status := Pool.try_take_completed
        (self            => self.workers,
         job             => job,
         callback_status => callback_status,
         available       => available);

      if status /= Clair.Status.OK then
        return status;
      end if;

      exit when not available;

      self.admission.release (job.request_value);
      completion_value.item := job;
      completion_value.deferred_output := False;
      begin
        handler_status := job.completion_handler.on_completion
          (completion_value, callback_status);
      exception
        when others =>
          handler_status := Clair.Status.CALLBACK_FAILED;
      end;

      target := deferred_impl(self);
      if target /= null then
        if handler_status = Clair.Status.OK then
          target.state.bind_handler
            (job.request_value, job.completion_handler);
        else
          retire_target_request (target, job.request_value, Not_Cancelled);
        end if;
      end if;

      Free_Work_Item (job);
      completion_value.item := null;

      if handler_status /= Clair.Status.OK then
        return handler_status;
      end if;
    end loop;

    target := deferred_impl(self);
    if target = null then
      return Clair.Status.OK;
    end if;

    for attempt in 1 .. MAX_COMPLETIONS_PER_TICK loop
      pragma Unreferenced (attempt);
      target.state.try_take (command, available);
      exit when not available;

      job := command.item;
      if job = null then
        target.state.finish_processing (command.request);
        target.state.set_connection_busy
          (command.request.connection_id, False);
        raise Program_Error with "missing staged deferred output";
      end if;

      completion_value.item := job;
      completion_value.deferred_output := True;
      begin
        handler_status := job.completion_handler.on_completion
          (completion_value, Clair.Status.OK);
      exception
        when others =>
          handler_status := Clair.Status.CALLBACK_FAILED;
      end;

      Free_Work_Item (job);
      command.item := null;
      completion_value.item := null;
      target.state.finish_processing (command.request);
      target.state.set_connection_busy
        (command.request.connection_id, False);

      if handler_status /= Clair.Status.OK then
        retire_target_request (target, command.request, Not_Cancelled);
        return handler_status;
      end if;
    end loop;

    return Clair.Status.OK;
  end on_timer;


end Fasyn.Request.Execution;
