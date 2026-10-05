-- ============================================================================
-- tests-execution.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Unchecked_Deallocation;
with Clair.Event_Loop;
with Clair.Status;
with Clair.Test.Assertions;
with Fasyn.Protocol;
with Fasyn.Request;
with Fasyn.Request.Execution;
with Fasyn.Request.Execution.Internal;
with Fasyn.Request.Execution.Testing;

package body Tests.Execution is

  package A renames Clair.Test.Assertions;
  package E renames Fasyn.Request.Execution;
  package EI renames Fasyn.Request.Execution.Internal;
  package ET renames Fasyn.Request.Execution.Testing;
  package P renames Fasyn.Protocol;
  package R renames Fasyn.Request;

  use type Clair.Status.Code;
  use type E.Context_Access;
  use type R.Cancellation_Cause;
  use type R.Connection_Identity;
  use type R.Defer_Status;
  use type R.Deferred_Wait_Cancel_Status;
  use type R.Deferred_Wait_Status;
  use type R.Deferred_Write_Status;
  use type R.Identity;
  use type R.Write_Status;

  protected type Test_Gate is
    procedure mark_started;
    entry wait_started;
    entry wait_release;
    procedure release;
  private
    has_started : Boolean := False;
    is_released : Boolean := False;
  end Test_Gate;

  protected body Test_Gate is
    procedure mark_started is
    begin
      has_started := True;
    end mark_started;

    entry wait_started when has_started is
    begin
      null;
    end wait_started;

    entry wait_release when is_released is
    begin
      null;
    end wait_release;

    procedure release is
    begin
      is_released := True;
    end release;
  end Test_Gate;

  type Gate_Access is access all Test_Gate;

  protected type Concurrency_Gate is
    procedure mark_started;
    function started_count return Natural;
    entry wait_release;
    procedure release;
  private
    started     : Natural := 0;
    is_released : Boolean := False;
  end Concurrency_Gate;

  protected body Concurrency_Gate is
    procedure mark_started is
    begin
      started := started + 1;
    end mark_started;

    function started_count return Natural is
    begin
      return started;
    end started_count;

    entry wait_release when is_released is
    begin
      null;
    end wait_release;

    procedure release is
    begin
      is_released := True;
    end release;
  end Concurrency_Gate;

  type Concurrency_Gate_Access is access all Concurrency_Gate;

  type Test_Application is new R.Application with record
    gate : Gate_Access := null;
  end record;

  overriding procedure on_parameter
    (self    : in out Test_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Test_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (self, context, name, value);
  begin
    null;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
  begin
    if self.gate /= null then
      self.gate.mark_started;
      self.gate.wait_release;
    end if;

    if R.write_stdout (response, data) /= R.Write_Complete then
      raise Program_Error with "test application output failed";
    end if;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_stdin_end;

  type Concurrent_Application is new Test_Application with record
    concurrency_gate : Concurrency_Gate_Access := null;
  end record;

  overriding procedure on_stdin
    (self     : in out Concurrent_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, data, response);
  begin
    if self.concurrency_gate /= null then
      self.concurrency_gate.mark_started;
      self.concurrency_gate.wait_release;
    end if;
  end on_stdin;

  type Large_Completion_Application is new Test_Application with record
    write_ok : Boolean := False;
  end record;

  overriding procedure on_stdin_end
    (self     : in out Large_Completion_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    data   : constant P.Byte_Array (1 .. 16_384) := [others => 16#5A#];
    status : R.Write_Status := R.Write_Complete;
  begin
    for chunk in 1 .. 13 loop
      pragma Unreferenced (chunk);
      status := R.write_stdout (response, data);
      exit when status /= R.Write_Complete;
    end loop;
    self.write_ok := status = R.Write_Complete;
  end on_stdin_end;

  type Slice_Length_Array is array (Positive range 1 .. 4) of Natural;
  type Slice_Final_Array is array (Positive range 1 .. 4) of Boolean;

  type Slice_Completion_Handler is new E.Completion_Handler with record
    count      : Natural := 0;
    bytes_seen : Natural := 0;
    lengths    : Slice_Length_Array := [others => 0];
    finals     : Slice_Final_Array := [others => False];
    records_ok : Boolean := True;
  end record;

  overriding function on_completion
    (handler         : in out Slice_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
    length        : constant Natural := E.output_length(item);
    cursor        : Natural := 1;
    content       : Natural;
    record_length : Natural;
  begin
    if callback_status /= Clair.Status.OK then
      return callback_status;
    end if;

    handler.count := handler.count + 1;
    handler.bytes_seen := handler.bytes_seen + length;
    if handler.count <= handler.lengths'last then
      handler.lengths(handler.count) := length;
      handler.finals(handler.count) := E.delivery_complete(item);
    end if;

    while cursor <= length loop
      if length - cursor + 1 < P.HEADER_LENGTH then
        handler.records_ok := False;
        exit;
      end if;
      content :=
        Natural(E.output_byte(item, cursor + 4)) * 256 +
        Natural(E.output_byte(item, cursor + 5));
      record_length := P.HEADER_LENGTH + content +
        Natural(E.output_byte(item, cursor + 6));
      if record_length > length - cursor + 1 then
        handler.records_ok := False;
        exit;
      end if;
      cursor := cursor + record_length;
    end loop;
    return Clair.Status.OK;
  end on_completion;

  type Batch_Application is new R.Application with record
    parameter_count : Natural := 0;
    params_end_seen : Boolean := False;
    stdin_bytes     : Natural := 0;
    stdin_end_seen  : Boolean := False;
    data_bytes      : Natural := 0;
    data_end_seen   : Boolean := False;
  end record;

  overriding procedure on_parameter
    (self    : in out Batch_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Batch_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Batch_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Batch_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_data
    (self     : in out Batch_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_data_end
    (self     : in out Batch_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Batch_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Batch_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.params_end_seen := True;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Batch_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.stdin_bytes := self.stdin_bytes + data'length;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Batch_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.stdin_end_seen := True;
  end on_stdin_end;

  overriding procedure on_data
    (self     : in out Batch_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.data_bytes := self.data_bytes + data'length;
  end on_data;

  overriding procedure on_data_end
    (self     : in out Batch_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.data_end_seen := True;
  end on_data_end;

  type Role_Defer_Application is limited new R.Application with record
    responder_handle  : R.Deferred_Handle;
    authorizer_handle : R.Deferred_Handle;
    filter_handle     : R.Deferred_Handle;
    responder_status  : R.Defer_Status := R.Defer_Not_Ready;
    authorizer_status : R.Defer_Status := R.Defer_Not_Ready;
    filter_status     : R.Defer_Status := R.Defer_Not_Ready;
  end record;

  overriding procedure on_parameter
    (self    : in out Role_Defer_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_data_end
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Role_Defer_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array) is null;

  overriding procedure on_params_end
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
  begin
    self.authorizer_status := R.defer_response
      (context, response, self.authorizer_handle);
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer) is null;

  overriding procedure on_stdin_end
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
  begin
    self.responder_status := R.defer_response
      (context, response, self.responder_handle);
  end on_stdin_end;

  overriding procedure on_data_end
    (self     : in out Role_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
  begin
    self.filter_status := R.defer_response
      (context, response, self.filter_handle);
  end on_data_end;

  type Role_Defer_Application_Access is access Role_Defer_Application;
  procedure Free_Role_Defer_Application is new Ada.Unchecked_Deallocation
    (Object => Role_Defer_Application,
     Name   => Role_Defer_Application_Access);

  type Deferred_Handle_Array is
    array (Positive range 1 .. 5) of R.Deferred_Handle;

  type Multi_Defer_Application is limited new R.Application with record
    handles     : Deferred_Handle_Array;
    defer_count : Natural := 0;
    defer_ok    : Boolean := True;
  end record;

  overriding procedure on_parameter
    (self    : in out Multi_Defer_Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array) is null;

  overriding procedure on_params_end
    (self     : in out Multi_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer) is null;

  overriding procedure on_stdin
    (self     : in out Multi_Defer_Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer) is null;

  overriding procedure on_stdin_end
    (self     : in out Multi_Defer_Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    request : constant R.Identity := R.current_identity(context);
    index   : constant Positive := Positive(request.request_id);
    status  : R.Defer_Status;
  begin
    status := R.defer_response (context, response, self.handles(index));
    self.defer_ok := self.defer_ok and then status = R.Defer_Complete;
    if status = R.Defer_Complete then
      self.defer_count := self.defer_count + 1;
    end if;
  end on_stdin_end;

  type Identity_Array is array (Positive range 1 .. 5) of R.Identity;
  type Capacity_Array is array (Positive range 1 .. 5) of Positive;

  type Test_Completion_Handler is new E.Completion_Handler with record
    count      : Natural := 0;
    identities : Identity_Array := [others => R.NULL_IDENTITY];
    capacities : Capacity_Array := [others => 1];
    bytes_seen : Natural := 0;
  end record;

  overriding function on_completion
    (handler         : in out Test_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code;

  overriding function on_completion
    (handler         : in out Test_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
  begin
    if callback_status /= Clair.Status.OK then
      return callback_status;
    end if;

    handler.count := handler.count + 1;
    if handler.count <= handler.identities'last then
      handler.identities(handler.count) := E.completion_request(item);
      handler.capacities(handler.count) := ET.output_capacity(item);
    end if;

    handler.bytes_seen := handler.bytes_seen + E.output_length(item);
    return Clair.Status.OK;
  end on_completion;

  type Activating_Completion_Handler is new E.Completion_Handler with record
    executor      : E.Context_Access := null;
    count         : Natural := 0;
    activation_ok : Boolean := True;
  end record;

  overriding function on_completion
    (handler         : in out Activating_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code;

  overriding function on_completion
    (handler         : in out Activating_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if callback_status /= Clair.Status.OK then
      return callback_status;
    end if;
    handler.count := handler.count + 1;
    if E.is_deferred_output(item) then
      return Clair.Status.OK;
    end if;
    if handler.executor = null then
      handler.activation_ok := False;
      return Clair.Status.INVALID_STATE;
    end if;
    status := EI.activate_deferred
      (handler.executor.all, E.completion_request(item), 0, 64, 0, 128);
    handler.activation_ok :=
      handler.activation_ok and then status = Clair.Status.OK;
    return status;
  end on_completion;

  type Deferred_Slice_Completion_Handler is new E.Completion_Handler with record
    executor       : E.Context_Access := null;
    ordinary_count : Natural := 0;
    deferred_count : Natural := 0;
    activation_ok  : Boolean := True;
    copy_ok        : Boolean := True;
    bytes_seen     : Natural := 0;
    lengths        : Slice_Length_Array := [others => 0];
    finals         : Slice_Final_Array := [others => False];
  end record;

  overriding function on_completion
    (handler         : in out Deferred_Slice_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
    status : Clair.Status.Code;
    length : Natural;
  begin
    if callback_status /= Clair.Status.OK then
      return callback_status;
    end if;

    if E.is_deferred_output(item) then
      handler.deferred_count := handler.deferred_count + 1;
      length := E.deferred_data_length(item);
      declare
        target : P.Byte_Array (1 .. length);
        copied : constant Natural := E.copy_deferred_data (item, 0, target);
      begin
        handler.copy_ok := handler.copy_ok and then copied = length;
      end;
      handler.bytes_seen := handler.bytes_seen + length;
      if handler.deferred_count <= handler.lengths'last then
        handler.lengths(handler.deferred_count) := length;
        handler.finals(handler.deferred_count) := E.delivery_complete(item);
      end if;
      return Clair.Status.OK;
    end if;

    handler.ordinary_count := handler.ordinary_count + 1;
    if handler.executor = null then
      handler.activation_ok := False;
      return Clair.Status.INVALID_STATE;
    end if;

    status := EI.activate_deferred
      (handler.executor.all, E.completion_request(item),
       0, 262_144, 0, 262_144);
    handler.activation_ok :=
      handler.activation_ok and then status = Clair.Status.OK;
    return status;
  end on_completion;

  type Followup_Completion_Handler is new E.Completion_Handler with record
    executor          : E.Context_Access := null;
    application       : R.Application_Access := null;
    count             : Natural := 0;
    followup_status   : Clair.Status.Code := Clair.Status.OK;
    followup_accepted : Boolean := True;
  end record;

  overriding function on_completion
    (handler         : in out Followup_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
    pragma Unreferenced (item);
    data : constant P.Byte_Array := [16#42#];
    followup : constant R.Identity :=
      (connection_id => 8, request_id => 3, generation => 1);
  begin
    if callback_status /= Clair.Status.OK then
      return callback_status;
    end if;

    handler.count := handler.count + 1;
    if handler.count = 1 then
      handler.followup_status := E.submit_stdin
        (handler.executor.all, followup, handler.application,
         handler'Unchecked_Access, data, 64, handler.followup_accepted);
    end if;
    return Clair.Status.OK;
  end on_completion;

  type Test_Completion_Handler_Access is access all Test_Completion_Handler;

  type Deferred_Writable_Recorder is new R.Deferred_Writable_Waiter with record
    count        : Natural := 0;
    last_request : R.Identity := R.NULL_IDENTITY;
    fail_once    : Boolean := False;
  end record;

  overriding procedure on_deferred_writable
    (waiter  : in out Deferred_Writable_Recorder;
     request : in R.Identity)
  is
  begin
    waiter.count := waiter.count + 1;
    waiter.last_request := request;
    if waiter.fail_once then
      waiter.fail_once := False;
      raise Program_Error with "deferred writable waiter failure probe";
    end if;
  end on_deferred_writable;

  type Capacity_Recorder is new E.Capacity_Waiter with record
    count                     : Natural := 0;
    fail_once                 : Boolean := False;
    completion_handler        : Test_Completion_Handler_Access := null;
    observed_completion_count : Natural := 0;
  end record;

  overriding function on_capacity_available
    (waiter : in out Capacity_Recorder) return Clair.Status.Code;

  overriding function on_capacity_available
    (waiter : in out Capacity_Recorder) return Clair.Status.Code
  is
  begin
    waiter.count := waiter.count + 1;
    if waiter.completion_handler /= null then
      waiter.observed_completion_count := waiter.completion_handler.count;
    end if;
    if waiter.fail_once then
      waiter.fail_once := False;
      return Clair.Status.CALLBACK_FAILED;
    end if;
    return Clair.Status.OK;
  end on_capacity_available;

  type Capacity_Recorder_Array is
    array (Positive range <>) of aliased Capacity_Recorder;
  type Capacity_Wait_Node_Array is
    array (Positive range <>) of aliased E.Capacity_Wait_Node;

  type Capacity_Wait_Node_Access is access all E.Capacity_Wait_Node;

  type Requeueing_Capacity_Waiter is new E.Capacity_Waiter with record
    executor : E.Context_Access := null;
    node     : Capacity_Wait_Node_Access := null;
    count    : Natural := 0;
    status   : Clair.Status.Code := Clair.Status.OK;
  end record;

  overriding function on_capacity_available
    (waiter : in out Requeueing_Capacity_Waiter) return Clair.Status.Code;

  overriding function on_capacity_available
    (waiter : in out Requeueing_Capacity_Waiter) return Clair.Status.Code
  is
  begin
    waiter.count := waiter.count + 1;
    waiter.status := E.wait_for_capacity
      (waiter.executor.all, waiter.node.all, waiter'Unchecked_Access);
    return waiter.status;
  end on_capacity_available;

  type Fail_Once_Completion_Handler is new E.Completion_Handler with record
    count : Natural := 0;
  end record;

  overriding function on_completion
    (handler         : in out Fail_Once_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code;

  overriding function on_completion
    (handler         : in out Fail_Once_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
    pragma Unreferenced (item);
  begin
    if callback_status /= Clair.Status.OK then
      return callback_status;
    end if;

    handler.count := handler.count + 1;
    if handler.count = 1 then
      return Clair.Status.CALLBACK_FAILED;
    end if;

    return Clair.Status.OK;
  end on_completion;

  procedure idle_executor_has_no_periodic_dispatch
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    dispatched : Boolean := True;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle notification loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 64,
       max_output_bytes => 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle notification executor initializes");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 20, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then not dispatched,
       "idle executor has no periodic event-loop dispatch");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "idle notification loop finalizes");
  end idle_executor_has_no_periodic_dispatch;

  procedure connection_identity_exhaustion
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    identity   : R.Connection_Identity;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "identity-exhaustion loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 128, 256);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "identity-exhaustion executor initializes");

    ET.seed_next_connection_identity
      (executor, R.Connection_Identity'Last);
    status := EI.issue_connection_identity (executor, identity);
    A.assert_true
      (reporter, status = Clair.Status.OK and then
       identity = R.Connection_Identity'Last,
       "last connection identity is issued exactly once");
    status := EI.issue_connection_identity (executor, identity);
    A.assert_true
      (reporter, status = Clair.Status.RANGE_ERROR and then
       identity = R.NO_CONNECTION_IDENTITY,
       "connection identity exhaustion fails closed without reuse");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "identity-exhaustion executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "identity-exhaustion executor finalizes");

    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 128, 256);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "identity-exhaustion executor reinitializes");
    status := EI.issue_connection_identity (executor, identity);
    A.assert_true
      (reporter, status = Clair.Status.RANGE_ERROR and then
       identity = R.NO_CONNECTION_IDENTITY,
       "executor reinitialization does not reopen exhausted identity space");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reinitialized identity-exhaustion executor stops");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reinitialized identity-exhaustion executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "identity-exhaustion loop finalizes");
  end connection_identity_exhaustion;

  procedure executor_runtime_coordination
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    first      : R.Connection_Identity;
    second     : R.Connection_Identity;
    third      : R.Connection_Identity;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "coordination loop initializes");

    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 128, 256);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "coordination executor initializes");

    status := EI.issue_connection_identity (executor, first);
    A.assert_true
      (reporter, status = Clair.Status.OK and then
       first /= R.NO_CONNECTION_IDENTITY,
       "executor issues a nonzero connection identity");
    status := EI.issue_connection_identity (executor, second);
    A.assert_true
      (reporter, status = Clair.Status.OK and then second /= first,
       "executor does not reuse active connection identities");

    A.assert_true
      (reporter, EI.supports_work_limits(executor, 128, 256),
       "executor reports matching work limits");
    A.assert_false
      (reporter, EI.supports_work_limits(executor, 129, 256),
       "executor rejects an oversized input requirement");
    A.assert_false
      (reporter, EI.supports_work_limits(executor, 128, 257),
       "executor rejects an oversized output requirement");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "coordination executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "coordination executor finalizes");

    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 128, 256);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "coordination executor reinitializes");
    status := EI.issue_connection_identity (executor, third);
    A.assert_true
      (reporter, status = Clair.Status.OK and then third /= first and then
       third /= second,
       "executor does not reuse identities after reinitialization");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reinitialized coordination executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "reinitialized coordination executor finalizes");

    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "coordination loop finalizes");
  end executor_runtime_coordination;

  procedure capacity_waiter_lifecycle
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    gate       : aliased Test_Gate;
    app        : aliased Test_Application;
    handler    : aliased Test_Completion_Handler;
    waiter     : aliased Capacity_Recorder;
    node       : aliased E.Capacity_Wait_Node;
    first      : constant R.Identity :=
      (connection_id => 6, request_id => 1, generation => 1);
    second     : constant R.Identity :=
      (connection_id => 6, request_id => 2, generation => 1);
    data       : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    app.gate := gate'Unchecked_Access;

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-wait loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-wait executor initializes");

    status := E.submit_stdin
      (executor, first, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-wait active job is accepted");
    gate.wait_started;
    status := E.submit_stdin
      (executor, second, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-wait pending job is accepted");

    status := E.wait_for_capacity
      (executor, node, waiter'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity waiter registers after admission saturation");
    status := E.wait_for_capacity
      (executor, node, waiter'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity waiter duplicate registration is idempotent");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_STATE,
       "executor shutdown rejects a live capacity waiter");

    status := E.cancel_capacity_wait (executor, node);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity waiter unregisters");
    status := E.cancel_capacity_wait (executor, node);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity waiter duplicate unregister is harmless");

    gate.release;
    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2 and then E.completed_count(executor) = 0;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "capacity-wait completion drain succeeds");
    end loop;
    A.assert_equal_natural
      (reporter, handler.count, 2,
       "capacity-wait jobs drain before shutdown");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-wait executor shutdown begins after unregister");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-wait executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-wait loop finalizes");
  end capacity_waiter_lifecycle;

  procedure capacity_waiter_failure_preserves_progress
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    gate       : aliased Test_Gate;
    app        : aliased Test_Application;
    handler    : aliased Test_Completion_Handler;
    first_waiter  : aliased Capacity_Recorder :=
      (count                     => 0,
       fail_once                 => True,
       completion_handler        => handler'Unchecked_Access,
       observed_completion_count => 0);
    second_waiter : aliased Capacity_Recorder;
    first_node    : aliased E.Capacity_Wait_Node;
    second_node   : aliased E.Capacity_Wait_Node;
    first : constant R.Identity :=
      (connection_id => 7, request_id => 1, generation => 1);
    second : constant R.Identity :=
      (connection_id => 7, request_id => 2, generation => 1);
    data       : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    app.gate := gate'Unchecked_Access;

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-failure loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-failure executor initializes");

    status := E.submit_stdin
      (executor, first, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-failure active job is accepted");
    gate.wait_started;
    status := E.submit_stdin
      (executor, second, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-failure pending job is accepted");

    status := E.wait_for_capacity
      (executor, first_node, first_waiter'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "first capacity-failure waiter registers");
    status := E.wait_for_capacity
      (executor, second_node, second_waiter'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "second capacity-failure waiter registers");

    gate.release;
    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 100, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.CALLBACK_FAILED,
       "first capacity waiter failure propagates");
    A.assert_equal_natural
      (reporter, first_waiter.count, 1,
       "failing capacity waiter runs once");
    A.assert_equal_natural
      (reporter, first_waiter.observed_completion_count, 0,
       "capacity waiter runs before the releasing completion handler");
    A.assert_equal_natural
      (reporter, second_waiter.count, 1,
       "unused capacity progresses the next waiter despite first failure");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2 and then E.completed_count(executor) = 0;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "capacity-failure completion drain succeeds");
    end loop;
    A.assert_equal_natural
      (reporter, handler.count, 2,
       "capacity-failure jobs drain before shutdown");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-failure executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-failure executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-failure loop finalizes");
  end capacity_waiter_failure_preserves_progress;

  procedure capacity_wait_budget_rearms
    (reporter : in out Clair.Test.Reporter.Context)
  is
    WAITER_COUNT : constant Positive := 65;
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    gate       : aliased Test_Gate;
    app        : aliased Test_Application;
    handler    : aliased Followup_Completion_Handler;
    waiters    : Capacity_Recorder_Array (1 .. WAITER_COUNT);
    nodes      : Capacity_Wait_Node_Array (1 .. WAITER_COUNT);
    first : constant R.Identity :=
      (connection_id => 8, request_id => 1, generation => 1);
    second : constant R.Identity :=
      (connection_id => 8, request_id => 2, generation => 1);
    data       : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
    called     : Natural := 0;
  begin
    app.gate := gate'Unchecked_Access;
    handler.executor := executor'Unchecked_Access;
    handler.application := app'Unchecked_Access;

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-budget loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-budget executor initializes");

    status := E.submit_stdin
      (executor, first, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-budget active job is accepted");
    gate.wait_started;
    status := E.submit_stdin
      (executor, second, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-budget pending job is accepted");

    for index in nodes'range loop
      status := E.wait_for_capacity
        (executor, nodes(index), waiters(index)'Unchecked_Access);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "capacity-budget waiter registers");
    end loop;

    gate.release;
    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 100, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "first capacity-budget dispatch succeeds");

    called := 0;
    for index in waiters'range loop
      called := called + waiters(index).count;
    end loop;
    A.assert_equal_natural
      (reporter, called, 64,
       "one notification honors the 64-waiter capacity budget");
    A.assert_true
      (reporter, handler.followup_status = Clair.Status.OK and then
       not handler.followup_accepted,
       "releasing completion cannot leapfrog an older capacity waiter");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 100, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-budget rearm dispatch succeeds");

    called := 0;
    for index in waiters'range loop
      called := called + waiters(index).count;
    end loop;
    A.assert_equal_natural
      (reporter, called, WAITER_COUNT,
       "capacity-budget rearm progresses the remaining waiter");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2 and then E.completed_count(executor) = 0;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "capacity-budget completion drain succeeds");
    end loop;

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-budget executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-budget executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-budget loop finalizes");
  end capacity_wait_budget_rearms;

  procedure capacity_requeue_waits_for_completion
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    first_gate  : aliased Test_Gate;
    second_gate : aliased Test_Gate;
    first_app   : aliased Test_Application;
    second_app  : aliased Test_Application;
    handler     : aliased Test_Completion_Handler;
    waiters     : Capacity_Recorder_Array (1 .. 64);
    nodes       : Capacity_Wait_Node_Array (1 .. 64);
    requeue_node : aliased E.Capacity_Wait_Node;
    requeue_waiter : aliased Requeueing_Capacity_Waiter;
    first : constant R.Identity :=
      (connection_id => 9, request_id => 1, generation => 1);
    second : constant R.Identity :=
      (connection_id => 9, request_id => 2, generation => 1);
    data       : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    first_app.gate := first_gate'Unchecked_Access;
    second_app.gate := second_gate'Unchecked_Access;
    requeue_waiter.executor := executor'Unchecked_Access;
    requeue_waiter.node := requeue_node'Unchecked_Access;

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue executor initializes");

    status := E.submit_stdin
      (executor, first, first_app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-requeue first job is accepted");
    first_gate.wait_started;
    status := E.submit_stdin
      (executor, second, second_app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "capacity-requeue second job is accepted");

    for index in 1 .. 63 loop
      status := E.wait_for_capacity
        (executor, nodes(index), waiters(index)'Unchecked_Access);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "capacity-requeue prefix waiter registers");
    end loop;
    status := E.wait_for_capacity
      (executor, requeue_node, requeue_waiter'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue retrying waiter registers");
    status := E.wait_for_capacity
      (executor, nodes(64), waiters(64)'Unchecked_Access);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue trailing waiter registers");

    first_gate.release;
    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 100, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue first completion dispatch succeeds");
    second_gate.wait_started;
    A.assert_equal_natural
      (reporter, requeue_waiter.count, 1,
       "64th capacity waiter retries exactly once");
    A.assert_equal_natural
      (reporter, waiters(64).count, 0,
       "trailing waiter remains queued behind the requeue boundary");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 20, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then not dispatched,
       "requeued waiter does not self-poll without a new completion");

    second_gate.release;
    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      exit when status /= Clair.Status.OK or else
        (waiters(64).count = 1 and then requeue_waiter.count = 2 and then
         handler.count = 2);
    end loop;
    A.assert_true
      (reporter, status = Clair.Status.OK and then
       waiters(64).count = 1 and then requeue_waiter.count = 2 and then
       handler.count = 2,
       "new completion resumes FIFO progress after requeue");

    status := E.cancel_capacity_wait (executor, requeue_node);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue waiter unregisters before shutdown");
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "capacity-requeue loop finalizes");
  end capacity_requeue_waits_for_completion;

  procedure notification_rearms_after_handler_failure
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Test_Application;
    handler    : aliased Fail_Once_Completion_Handler;
    data       : constant P.Byte_Array := [16#41#];
    first      : constant R.Identity :=
      (connection_id => 5, request_id => 1, generation => 1);
    second     : constant R.Identity :=
      (connection_id => 5, request_id => 2, generation => 1);
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "failure-rearm loop initializes");

    status := E.initialize
      (executor, event_loop'Unchecked_Access, 2, 2, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "failure-rearm executor initializes");

    status := E.submit_stdin
      (executor, first, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "first failure-rearm job is accepted");
    status := E.submit_stdin
      (executor, second, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "second failure-rearm job is accepted");

    for attempt in 1 .. 1_000 loop
      pragma Unreferenced (attempt);
      exit when E.completed_count(executor) = 2;
      delay 0.001;
    end loop;
    A.assert_equal_natural
      (reporter, E.completed_count(executor), 2,
       "both completions publish before failure dispatch");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 50, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.CALLBACK_FAILED,
       "first completion handler failure propagates");
    A.assert_equal_natural
      (reporter, handler.count, 1,
       "failure stops the current completion drain");
    A.assert_equal_natural
      (reporter, E.completed_count(executor), 1,
       "later completion remains queued after failure");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 50, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "remaining completion receives a rearmed notification");
    A.assert_equal_natural
      (reporter, handler.count, 2,
       "remaining completion is delivered after handler failure");
    A.assert_equal_natural
      (reporter, E.completed_count(executor), 0,
       "failure rearm drains the remaining completion");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "failure-rearm executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "failure-rearm executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "failure-rearm loop finalizes");
  end notification_rearms_after_handler_failure;

  procedure batch_submission_semantics
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Batch_Application;
    handler    : aliased Test_Completion_Handler;
    request    : constant R.Identity :=
      (connection_id => 9, request_id => 1, generation => 1);
    data       : constant P.Byte_Array :=
      [16#41#, 16#42#, 16#43#, 16#44#, 16#45#, 16#46#];
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "batch semantics loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "batch semantics executor initializes");

    status := EI.submit_stdin_batch
      (executor, request, app'Unchecked_Access, handler'Unchecked_Access,
       data, finish_stream => True, output_limit => 64, accepted => accepted,
       role => P.Filter);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "Filter STDIN batch is accepted");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 1;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      exit when status /= Clair.Status.OK;
    end loop;

    A.assert_true
      (reporter, status = Clair.Status.OK and then handler.count = 1,
       "Filter STDIN batch completion dispatches");
    A.assert_equal_natural
      (reporter, app.stdin_bytes, data'length,
       "Filter STDIN batch preserves payload");
    A.assert_true
      (reporter, app.stdin_end_seen,
       "Filter STDIN batch preserves terminal callback");
    A.assert_equal_natural
      (reporter, handler.capacities(1), 64,
       "terminal batch allocates only its usable output capacity");

    declare
      second : constant R.Identity :=
        (connection_id => 9, request_id => 2, generation => 1);
      before : constant Natural := app.stdin_bytes;
    begin
      status := EI.submit_stdin_batch
        (executor, second, app'Unchecked_Access, handler'Unchecked_Access,
         data, finish_stream => False, output_limit => 0, accepted => accepted,
         role => P.Filter);
      A.assert_true
        (reporter, status = Clair.Status.OK and then accepted,
         "nonterminal Filter STDIN batch is accepted");
      for attempt in 1 .. 100 loop
        pragma Unreferenced (attempt);
        exit when handler.count = 2;
        status := Clair.Event_Loop.iterate
          (event_loop, timeout => 10, dispatched => dispatched);
        exit when status /= Clair.Status.OK;
      end loop;
      A.assert_equal_natural
        (reporter, app.stdin_bytes - before, data'length,
         "nonterminal Filter STDIN batch preserves payload");
      A.assert_equal_natural
        (reporter, handler.capacities(2), 1,
         "zero-output batch keeps only sentinel Writer storage");
    end;

    declare
      third : constant R.Identity :=
        (connection_id => 9, request_id => 3, generation => 1);
      name  : constant P.Byte_Array := [1 => 16#4E#];
      value : constant P.Byte_Array := [1 => 16#56#];
    begin
      status := E.submit_parameter
        (executor, third, app'Unchecked_Access, handler'Unchecked_Access,
         name, value, accepted, P.Responder);
      A.assert_true
        (reporter, status = Clair.Status.OK and then accepted,
         "parameter callback is accepted");
      for attempt in 1 .. 100 loop
        pragma Unreferenced (attempt);
        exit when handler.count = 3;
        status := Clair.Event_Loop.iterate
          (event_loop, timeout => 10, dispatched => dispatched);
        exit when status /= Clair.Status.OK;
      end loop;
      A.assert_equal_natural
        (reporter, handler.capacities(3), 1,
         "parameter callback does not allocate unused Writer capacity");
    end;

    declare
      fourth : constant R.Identity :=
        (connection_id => 9, request_id => 4, generation => 1);
    begin
      status := E.submit_stdin
        (executor, fourth, app'Unchecked_Access, handler'Unchecked_Access,
         data, 7, accepted, P.Responder);
      A.assert_true
        (reporter, status = Clair.Status.OK and then accepted,
         "ordinary STDIN callback is accepted");
      for attempt in 1 .. 100 loop
        pragma Unreferenced (attempt);
        exit when handler.count = 4;
        status := Clair.Event_Loop.iterate
          (event_loop, timeout => 10, dispatched => dispatched);
        exit when status /= Clair.Status.OK;
      end loop;
      A.assert_equal_natural
        (reporter, handler.capacities(4), 7,
         "ordinary callback Writer matches actual output limit");
    end;

    declare
      fifth : constant R.Identity :=
        (connection_id => 9, request_id => 5, generation => 1);
      encoded : constant P.Byte_Array (0 .. 3) :=
        [0 => 1, 1 => 1, 2 => 16#4E#, 3 => 16#56#];
    begin
      status := EI.submit_parameter_batch
        (executor, fifth, app'Unchecked_Access, handler'Unchecked_Access,
         encoded, finish_params => False, output_limit => 0,
         accepted => accepted, role => P.Responder);
      A.assert_true
        (reporter, status = Clair.Status.OK and then accepted,
         "zero-based parameter batch is accepted");
      for attempt in 1 .. 100 loop
        pragma Unreferenced (attempt);
        exit when handler.count = 5;
        status := Clair.Event_Loop.iterate
          (event_loop, timeout => 10, dispatched => dispatched);
        exit when status /= Clair.Status.OK;
      end loop;
      A.assert_equal_natural
        (reporter, app.parameter_count, 2,
         "parameter batch preserves source-array index independence");
      A.assert_equal_natural
        (reporter, handler.capacities(5), 1,
         "nonterminal parameter batch keeps sentinel Writer storage");
    end;

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "batch semantics executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "batch semantics executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "batch semantics loop finalizes");
  end batch_submission_semantics;

  procedure role_terminal_deferral
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Role_Defer_Application;
    handler    : aliased Test_Completion_Handler;
    responder  : constant R.Identity :=
      (connection_id => 2, request_id => 1, generation => 1);
    authorizer : constant R.Identity :=
      (connection_id => 2, request_id => 2, generation => 1);
    filter     : constant R.Identity :=
      (connection_id => 2, request_id => 3, generation => 1);
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer loop initializes");
    --  This scenario submits one terminal callback for each FastCGI role
    --  back-to-back.  Keep capacity for all three so role semantics do not
    --  depend on whether a worker dequeues an earlier item first.
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 2, 3, 64, 128, 4);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer executor initializes");

    status := E.submit_stdin_end
      (executor, responder, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "responder terminal callback is accepted");
    status := E.submit_stdin_end
      (executor, authorizer, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Authorizer);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_ARGUMENT and then not accepted,
       "authorizer STDIN submission is rejected");
    status := E.submit_params_end
      (executor, authorizer, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Authorizer);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "authorizer terminal callback is accepted");
    status := E.submit_data_end
      (executor, filter, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "filter terminal callback is accepted");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 3;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter,
         status = Clair.Status.OK,
         "role defer notification dispatch succeeds");
    end loop;

    A.assert_equal_natural
      (reporter,
       handler.count,
       3,
       "role callbacks complete");
    A.assert_true
      (reporter, app.responder_status = R.Defer_Complete and then
       R.current_identity(app.responder_handle) = responder,
       "responder may defer at STDIN end");
    A.assert_true
      (reporter, app.authorizer_status = R.Defer_Complete and then
       R.current_identity(app.authorizer_handle) = authorizer,
       "authorizer may defer at PARAMS end");
    A.assert_true
      (reporter, app.filter_status = R.Defer_Complete and then
       R.current_identity(app.filter_handle) = filter,
       "filter may defer at DATA end");
    A.assert_true
      (reporter,
       E.active_count(executor) = 0 and then
         E.pending_count(executor) = 0,
       "role deferred handles do not retain workers");

    EI.retire_deferred (executor, responder);
    EI.retire_deferred (executor, authorizer);
    EI.retire_deferred (executor, filter);
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer loop finalizes");
  end role_terminal_deferral;

  procedure zero_deferred_capacity_disables_deferral
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Role_Defer_Application;
    handler    : aliased Test_Completion_Handler;
    request    : constant R.Identity :=
      (connection_id => 103, request_id => 1, generation => 1);
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "disabled-defer loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access,
       worker_count      => 1,
       pending_capacity  => 1,
       max_input_bytes   => 64,
       max_output_bytes  => 128,
       deferred_capacity => 0);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "zero deferred capacity initializes executor");

    status := E.submit_stdin_end
      (executor, request, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "zero deferred capacity keeps synchronous submission available");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 1;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "disabled-defer completion dispatch succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, 1,
       "zero deferred capacity still publishes completion");
    A.assert_true
      (reporter, app.responder_status = R.Defer_Not_Allowed,
       "zero deferred capacity disables response deferral by policy");
    A.assert_true
      (reporter, R.is_null(R.current_identity(app.responder_handle)),
       "disabled deferral leaves no retained request handle");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "disabled-defer shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "disabled-defer executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "disabled-defer loop finalizes");
  end zero_deferred_capacity_disables_deferral;

  procedure admission_index_resists_ordered_churn
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    A.assert_true
      (reporter, ET.admission_index_churn_consistent,
       "executor admission AVL index survives ordered saturation and reuse");
  end admission_index_resists_ordered_churn;

  procedure deferred_index_resists_ordered_churn
    (reporter : in out Clair.Test.Reporter.Context)
  is
    ENTRY_COUNT : constant Positive := 64;
    event_loop  : aliased Clair.Event_Loop.Context;
    executor    : aliased E.Context;
    handler     : aliased Test_Completion_Handler;
    type Application_Array is
      array (Positive range 1 .. ENTRY_COUNT) of Role_Defer_Application_Access;
    type Request_Array is
      array (Positive range 1 .. ENTRY_COUNT) of R.Identity;
    applications : Application_Array := [others => null];
    requests     : Request_Array := [others => R.NULL_IDENTITY];
    accepted     : Boolean;
    dispatched   : Boolean;
    status       : Clair.Status.Code;

    procedure drive_until (expected : Natural; message : String) is
      ok : Boolean := True;
    begin
      for attempt in 1 .. 200 loop
        pragma Unreferenced (attempt);
        exit when handler.count >= expected;
        status := Clair.Event_Loop.iterate
          (event_loop, timeout => 10, dispatched => dispatched);
        if status /= Clair.Status.OK then
          ok := False;
          exit;
        end if;
      end loop;
      A.assert_true
        (reporter, ok and then handler.count >= expected, message);
    end drive_until;

    procedure submit_request
      (number     : Positive;
       generation : R.Generation;
       expected   : Natural)
    is
    begin
      requests(number) :=
        (connection_id => R.Connection_Identity(number),
         request_id    => 1,
         generation    => generation);
      applications(number) := new Role_Defer_Application;
      status := E.submit_stdin_end
        (executor, requests(number),
         applications(number).all'Unchecked_Access,
         handler'Unchecked_Access, 64, accepted, P.Responder);
      A.assert_true
        (reporter, status = Clair.Status.OK and then accepted,
         "ordered deferred request submission succeeds");
      drive_until (expected, "ordered deferred callback completes");
      A.assert_true
        (reporter,
         applications(number).responder_status = R.Defer_Complete,
         "ordered deferred callback retains its request handle");
      A.assert_true
        (reporter, ET.deferred_index_consistent(executor),
         "deferred AVL indices remain consistent after insertion");
    end submit_request;

    procedure retire_request (number : Positive) is
    begin
      ET.retire_deferred_request (executor, requests(number));
      Free_Role_Defer_Application (applications(number));
      A.assert_true
        (reporter, applications(number) = null,
         "retired deferred application is finalized and released");
      A.assert_true
        (reporter, ET.deferred_index_consistent(executor),
         "deferred AVL indices remain consistent after retirement");
    end retire_request;

    completion_target : Natural := 0;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "ordered deferred churn loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access,
       worker_count      => 1,
       pending_capacity  => ENTRY_COUNT,
       max_input_bytes   => 64,
       max_output_bytes  => 128,
       deferred_capacity => ENTRY_COUNT);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "ordered deferred churn executor initializes");

    for number in 1 .. ENTRY_COUNT loop
      completion_target := completion_target + 1;
      submit_request (number, 1, completion_target);
    end loop;
    A.assert_true
      (reporter, ET.deferred_index_consistent(executor),
       "ascending deferred request and connection trees are balanced");

    for number in 1 .. ENTRY_COUNT / 2 loop
      retire_request (2 * number);
    end loop;
    A.assert_true
      (reporter, ET.deferred_index_consistent(executor),
       "alternating deferred removals preserve both AVL indices");

    for number in reverse 1 .. ENTRY_COUNT / 2 loop
      completion_target := completion_target + 1;
      submit_request (2 * number, 2, completion_target);
    end loop;
    A.assert_true
      (reporter, ET.deferred_index_consistent(executor),
       "descending deferred reuse preserves both AVL indices");

    for number in reverse 1 .. ENTRY_COUNT loop
      retire_request (number);
    end loop;
    A.assert_true
      (reporter, ET.deferred_index_consistent(executor),
       "empty deferred indices remain consistent after ordered churn");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "ordered deferred churn shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "ordered deferred churn executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "ordered deferred churn loop finalizes");
  end deferred_index_resists_ordered_churn;

  procedure deferred_capacity_is_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    first_app  : aliased Role_Defer_Application;
    second_app : aliased Role_Defer_Application;
    handler    : aliased Test_Completion_Handler;
    first      : constant R.Identity :=
      (connection_id => 3, request_id => 1, generation => 1);
    second     : constant R.Identity :=
      (connection_id => 3, request_id => 2, generation => 1);
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 2, 64, 128, 1);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity executor initializes");

    status := E.submit_stdin_end
      (executor, first, first_app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "first deferred candidate is accepted");
    status := E.submit_stdin_end
      (executor, second, second_app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "second deferred candidate is accepted by executor");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter,
         status = Clair.Status.OK,
         "capacity completion notification succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, 2, "both capacity callbacks return");
    A.assert_true
      (reporter, first_app.responder_status = R.Defer_Complete,
       "first request consumes the sole deferred slot");
    A.assert_true
      (reporter, second_app.responder_status = R.Defer_Capacity_Exceeded,
       "second request observes bounded deferred capacity");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity loop finalizes");
  end deferred_capacity_is_bounded;

  procedure deferred_writable_wait_is_event_driven
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Multi_Defer_Application;
    handler    : aliased Activating_Completion_Handler;
    waiter     : aliased Deferred_Writable_Recorder;
    conflict   : aliased Deferred_Writable_Recorder;
    request    : constant R.Identity :=
      (connection_id => 93, request_id => 1, generation => 1);
    payload    : constant P.Byte_Array := [16#57#];
    accepted      : Boolean;
    dispatched    : Boolean;
    status        : Clair.Status.Code;
    write_status  : R.Deferred_Write_Status;
    wait_status   : R.Deferred_Wait_Status;
    cancel_status : R.Deferred_Wait_Cancel_Status;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-writable event loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 128, 1);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-writable executor initializes");
    handler.executor := executor'Unchecked_Access;

    status := E.submit_stdin_end
      (executor, request, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "deferred-writable terminal work submits");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 1;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred-writable activation notification succeeds");
    end loop;
    A.assert_true
      (reporter, app.defer_ok and then app.defer_count = 1 and then
       handler.activation_ok,
       "deferred-writable request activates with one handle");

    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Not_Blocked,
       "writable wait requires a preceding blocked write");

    EI.set_deferred_connection_busy (executor, request.connection_id, False);
    EI.sync_deferred_request (executor, request, 63);
    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Would_Block,
       "insufficient request bytes apply deferred backpressure");
    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Registered,
       "blocked producer registers one writable waiter");
    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Registered,
       "duplicate writable registration is idempotent");
    wait_status := R.wait_writable
      (app.handles(1), conflict'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Conflict,
       "second writable waiter is rejected without replacement");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 0, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then waiter.count = 0,
       "unchanged blocked state does not generate readiness callbacks");

    EI.sync_deferred_request (executor, request, 0);
    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when waiter.count = 1;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred-writable readiness notification succeeds");
    end loop;
    A.assert_equal_natural
      (reporter, waiter.count, 1,
       "writable waiter fires exactly once after capacity returns");
    A.assert_true
      (reporter, waiter.last_request = request and then conflict.count = 0,
       "writable callback identifies only the registered request");

    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Write_Complete,
       "producer retry succeeds after writable notification");
    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when EI.deferred_pending_bytes(executor, request) = 0;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred-writable staged output drains");
    end loop;

    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Not_Blocked,
       "writable wait requires a preceding blocked write token");

    EI.set_deferred_connection_busy (executor, request.connection_id, True);
    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Would_Block,
       "lost-wake probe records blocked write");
    EI.set_deferred_connection_busy (executor, request.connection_id, False);
    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Ready,
       "writable wait observes progress that preceded registration");
    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Not_Blocked,
       "immediate readiness is one-shot until another write blocks");

    EI.set_deferred_connection_busy (executor, request.connection_id, True);
    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Would_Block,
       "cancellation probe records blocked write");
    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Registered,
       "writable waiter can register again after callback");
    cancel_status := R.cancel_writable_wait (app.handles(1));
    A.assert_true
      (reporter, cancel_status = R.Deferred_Wait_Cancelled,
       "queued writable waiter cancels synchronously");
    EI.set_deferred_connection_busy (executor, request.connection_id, False);
    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 0, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then waiter.count = 1,
       "cancelled writable waiter receives no later callback");

    EI.set_deferred_connection_busy (executor, request.connection_id, True);
    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Would_Block,
       "shutdown probe records blocked write");
    wait_status := R.wait_writable
      (app.handles(1), waiter'Unchecked_Access);
    A.assert_true
      (reporter, wait_status = R.Deferred_Wait_Registered,
       "shutdown probe registers while blocked");
    waiter.fail_once := True;
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-writable executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_STATE,
       "shutdown cannot finalize while writable callback is retained");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 10, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.CALLBACK_FAILED and then
       waiter.count = 2,
       "shutdown wakes producer and propagates callback failure once");
    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Closed and then
       R.cancellation_reason(app.handles(1)) = R.Runtime_Shutdown,
       "shutdown wake lets producer observe closed generation");

    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-writable executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-writable event loop finalizes");
  end deferred_writable_wait_is_event_driven;

  procedure deferred_connection_groups_are_indexed
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Multi_Defer_Application;
    handler    : aliased Activating_Completion_Handler;
    identities : Identity_Array;
    payload    : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
    write_status : R.Deferred_Write_Status;
    expected_staged : constant Natural := P.HEADER_LENGTH + payload'length;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-index loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 5, 64, 128, 5);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-index executor initializes");
    handler.executor := executor'Unchecked_Access;

    for index in identities'range loop
      identities(index) :=
        (connection_id => R.Connection_Identity(6 - index),
         request_id    => P.Request_Id(index),
         generation    => 1);
      status := E.submit_stdin_end
        (executor, identities(index), app'Unchecked_Access,
         handler'Unchecked_Access, 64, accepted, P.Responder);
      A.assert_true
        (reporter, status = Clair.Status.OK and then accepted,
         "deferred-index terminal work is accepted");
    end loop;

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = identities'length;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred-index terminal completion dispatch succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, identities'length,
       "all deferred-index terminal completions arrive");
    A.assert_true
      (reporter, app.defer_ok and then app.defer_count = identities'length,
       "all deferred-index requests obtain handles");
    A.assert_true
      (reporter, handler.activation_ok,
       "all deferred-index requests activate before handler binding");

    for index in identities'range loop
      EI.set_deferred_connection_busy
        (executor, identities(index).connection_id, False);
      write_status := R.write_stdout (app.handles(index), payload);
      A.assert_true
        (reporter, write_status = R.Deferred_Write_Complete,
         "deferred-index output stages");
      A.assert_equal_natural
        (reporter, EI.deferred_pending_bytes(executor, identities(index)),
         expected_staged, "request staged-byte aggregate is exact");
      A.assert_equal_natural
        (reporter,
         EI.deferred_connection_pending_bytes
           (executor, identities(index).connection_id),
         expected_staged, "connection staged-byte aggregate is exact");
    end loop;

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2 * identities'length;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred-index output dispatch succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, 2 * identities'length,
       "ready connection queue drains every staged command");
    for index in identities'range loop
      A.assert_equal_natural
        (reporter, EI.deferred_pending_bytes(executor, identities(index)), 0,
         "request staged-byte aggregate drains to zero");
      A.assert_equal_natural
        (reporter,
         EI.deferred_connection_pending_bytes
           (executor, identities(index).connection_id),
         0, "connection staged-byte aggregate drains to zero");
      EI.retire_deferred (executor, identities(index));
    end loop;

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-index executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-index executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-index loop finalizes");
  end deferred_connection_groups_are_indexed;

  procedure deferred_delivery_is_byte_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Multi_Defer_Application;
    handler    : aliased Deferred_Slice_Completion_Handler;
    request    : constant R.Identity :=
      (connection_id => 91, request_id => 1, generation => 1);
    payload    : constant P.Byte_Array
      (1 .. 8 * EI.deferred_output_chunk_bytes) := [others => 16#44#];
    expected_encoded : constant Natural :=
      payload'length + 8 * P.HEADER_LENGTH;
    accepted      : Boolean;
    dispatched    : Boolean;
    status        : Clair.Status.Code;
    write_status  : R.Deferred_Write_Status;
    first_chunks  : Natural;
    first_encoded : Natural;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-slice event loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 262_144, 1);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-slice executor initializes");
    handler.executor := executor'Unchecked_Access;

    status := E.submit_stdin_end
      (executor, request, app'Unchecked_Access, handler'Unchecked_Access,
       262_144, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "deferred-slice terminal work submits");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.ordinary_count = 1;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred-slice activation notification succeeds");
    end loop;

    A.assert_true
      (reporter, app.defer_ok and then app.defer_count = 1,
       "deferred-slice request obtains one handle");
    A.assert_true
      (reporter, handler.activation_ok,
       "deferred-slice request activates before handler binding");

    EI.set_deferred_connection_busy (executor, request.connection_id, False);
    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Write_Complete,
       "large deferred output stages");
    A.assert_equal_natural
      (reporter, EI.deferred_pending_bytes(executor, request),
       expected_encoded,
       "full deferred reservation is visible before delivery");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 10, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then dispatched,
       "first deferred-slice notification succeeds");
    A.assert_equal_natural
      (reporter, handler.deferred_count, 1,
       "first notification delivers one deferred slice");
    A.assert_positive
      (reporter, Integer(handler.lengths(1)),
       "first deferred slice carries payload");
    A.assert_true
      (reporter,
       handler.lengths(1) mod EI.deferred_output_chunk_bytes = 0,
       "non-final deferred slice ends on a deferred chunk boundary");
    A.assert_true
      (reporter, handler.lengths(1) <= ET.completion_delivery_budget,
       "first deferred slice stays within notification byte budget");
    A.assert_false
      (reporter, handler.finals(1),
       "large deferred command remains pending after first slice");

    first_chunks := handler.lengths(1) / EI.deferred_output_chunk_bytes;
    first_encoded := handler.lengths(1) + first_chunks * P.HEADER_LENGTH;
    A.assert_equal_natural
      (reporter, EI.deferred_pending_bytes(executor, request),
       expected_encoded - first_encoded,
       "remaining deferred request reservation stays authoritative");
    A.assert_equal_natural
      (reporter,
       EI.deferred_connection_pending_bytes(executor, request.connection_id),
       expected_encoded - first_encoded,
       "remaining connection reservation matches deferred request reservation");
    A.assert_equal_natural
      (reporter, E.completed_count(executor), 1,
       "retained deferred delivery remains visible as one completion");
    A.assert_false
      (reporter, E.is_idle(executor),
       "executor is not idle while deferred delivery is retained");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when EI.deferred_pending_bytes(executor, request) = 0;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "remaining deferred-slice notification succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.deferred_count, 2,
       "large deferred command drains in two owner slices");
    A.assert_true
      (reporter, handler.finals(2),
       "second deferred slice is final");
    A.assert_equal_natural
      (reporter, handler.bytes_seen, payload'length,
       "deferred slices deliver every staged payload byte once");
    A.assert_true
      (reporter, handler.copy_ok,
       "deferred slice copy returns the exact copied byte count");
    A.assert_equal_natural
      (reporter, EI.deferred_pending_bytes(executor, request), 0,
       "deferred request reservation drains to zero");
    A.assert_equal_natural
      (reporter,
       EI.deferred_connection_pending_bytes(executor, request.connection_id), 0,
       "deferred connection reservation drains to zero");
    A.assert_true
      (reporter, E.is_idle(executor),
       "executor becomes idle after final deferred slice");

    EI.retire_deferred (executor, request);
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-slice executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-slice executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-slice event loop finalizes");
  end deferred_delivery_is_byte_bounded;

  procedure deferred_delivery_cancellation_releases_reservation
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Multi_Defer_Application;
    handler    : aliased Deferred_Slice_Completion_Handler;
    request    : constant R.Identity :=
      (connection_id => 92, request_id => 1, generation => 1);
    payload    : constant P.Byte_Array
      (1 .. 8 * EI.deferred_output_chunk_bytes) := [others => 16#45#];
    accepted     : Boolean;
    dispatched   : Boolean;
    status       : Clair.Status.Code;
    write_status : R.Deferred_Write_Status;
    remaining    : Natural;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-cancel event loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 262_144, 1);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-cancel executor initializes");
    handler.executor := executor'Unchecked_Access;

    status := E.submit_stdin_end
      (executor, request, app'Unchecked_Access, handler'Unchecked_Access,
       262_144, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "deferred-cancel terminal work submits");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.ordinary_count = 1;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "deferred-cancel activation notification succeeds");
    end loop;

    A.assert_true
      (reporter, app.defer_ok and then app.defer_count = 1 and then
       handler.activation_ok,
       "deferred-cancel request activates with one handle");
    EI.set_deferred_connection_busy (executor, request.connection_id, False);
    write_status := R.write_stdout (app.handles(1), payload);
    A.assert_true
      (reporter, write_status = R.Deferred_Write_Complete,
       "deferred-cancel large output stages");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 10, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then dispatched,
       "deferred-cancel first slice dispatch succeeds");
    A.assert_equal_natural
      (reporter, handler.deferred_count, 1,
       "deferred-cancel delivers exactly one slice before cancellation");
    remaining := EI.deferred_pending_bytes(executor, request);
    A.assert_positive
      (reporter, Integer(remaining),
       "deferred-cancel retains remaining staged reservation");

    EI.retire_deferred (executor, request, R.Peer_Abort);
    A.assert_true
      (reporter, R.cancellation_reason(app.handles(1)) = R.Peer_Abort,
       "deferred-cancel handle observes cancellation between slices");
    A.assert_equal_natural
      (reporter, EI.deferred_pending_bytes(executor, request), remaining,
       "retired in-flight slice keeps reservation until owner cleanup");

    status := Clair.Event_Loop.iterate
      (event_loop, timeout => 10, dispatched => dispatched);
    A.assert_true
      (reporter, status = Clair.Status.OK and then dispatched,
       "deferred-cancel retained delivery cleanup is notified");
    A.assert_equal_natural
      (reporter, handler.deferred_count, 1,
       "deferred-cancel does not deliver a second slice after retirement");
    A.assert_equal_natural
      (reporter, EI.deferred_pending_bytes(executor, request), 0,
       "deferred-cancel releases remaining request reservation");
    A.assert_equal_natural
      (reporter,
       EI.deferred_connection_pending_bytes(executor, request.connection_id), 0,
       "deferred-cancel releases remaining connection reservation");
    A.assert_true
      (reporter, E.is_idle(executor),
       "deferred-cancel executor becomes idle after retained cleanup");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-cancel executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-cancel executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "deferred-cancel event loop finalizes");
  end deferred_delivery_cancellation_releases_reservation;

  procedure notification_rearms_after_bounded_drain
    (reporter : in out Clair.Test.Reporter.Context)
  is
    JOB_COUNT  : constant Positive := 80;
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Test_Application;
    handler    : aliased Test_Completion_Handler;
    data       : constant P.Byte_Array := [16#41#];
    request    : R.Identity;
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "bounded notification loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 4,
       pending_capacity => JOB_COUNT,
       max_input_bytes  => 64,
       max_output_bytes => 128);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "bounded notification executor initializes");

    for index in 1 .. JOB_COUNT loop
      request :=
        (connection_id => 4,
         request_id    => P.Request_Id(index),
         generation    => 1);
      status := E.submit_stdin
        (executor, request, app'Unchecked_Access, handler'Unchecked_Access,
         data, 64, accepted);
      A.assert_true
        (reporter, status = Clair.Status.OK and then accepted,
         "bounded notification job is accepted");
    end loop;

    for attempt in 1 .. 1_000 loop
      pragma Unreferenced (attempt);
      exit when E.completed_count(executor) = JOB_COUNT;
      delay 0.001;
    end loop;
    A.assert_equal_natural
      (reporter, E.completed_count(executor), JOB_COUNT,
       "completion queue fills before notification dispatch");

    for attempt in 1 .. 4 loop
      pragma Unreferenced (attempt);
      exit when handler.count = JOB_COUNT;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 50, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "bounded notification dispatch succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, JOB_COUNT,
       "notification rearm drains work beyond one callback bound");
    A.assert_equal_natural
      (reporter, E.completed_count(executor), 0,
       "bounded completion queue is fully drained");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "bounded notification shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "bounded notification executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "bounded notification loop finalizes");
  end notification_rearms_after_bounded_drain;

  procedure bounded_saturation_and_shutdown
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    gate       : aliased Test_Gate;
    app        : aliased Test_Application;
    handler    : aliased Test_Completion_Handler;
    first      : constant R.Identity :=
      (connection_id => 1, request_id => 1, generation => 1);
    second     : constant R.Identity :=
      (connection_id => 1, request_id => 2, generation => 1);
    third      : constant R.Identity :=
      (connection_id => 1, request_id => 3, generation => 1);
    data       : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    started    : Boolean := False;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    app.gate := gate'Unchecked_Access;

    status := E.submit_stdin
      (executor, first, app'Unchecked_Access, handler'Unchecked_Access,
       data, 64, accepted);
    A.assert_true
      (reporter, status = Clair.Status.INVALID_STATE and then not accepted,
       "uninitialized executor rejects submission as invalid state");

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "event loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 64,
       max_output_bytes => 128);
    A.assert_true
      (reporter, status = Clair.Status.OK, "executor initializes");

    status := E.submit_stdin
      (executor, first, app'Unchecked_Access, handler'Unchecked_Access,
       data, 129, accepted);
    A.assert_true
      (reporter, status = Clair.Status.RANGE_ERROR and then not accepted,
       "submission beyond configured output capacity is a range error");

    status := E.submit_stdin
      (executor,
       first,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then accepted,
       "first job is accepted");

    select
      gate.wait_started;
      started := True;
    or
      delay 1.0;
    end select;
    A.assert_true (reporter, started, "worker begins gated job");

    status := E.submit_stdin
      (executor,
       first,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.INVALID_STATE and then not accepted,
       "same request generation is an invalid concurrent state");

    status := E.submit_stdin
      (executor,
       second,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then accepted,
       "pending job is accepted");
    A.assert_equal_natural
      (reporter, E.active_count(executor), 1, "worker count is bounded");
    A.assert_equal_natural
      (reporter, E.pending_count(executor), 1, "pending queue is bounded");

    status := E.submit_stdin
      (executor,
       third,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then not accepted,
       "job beyond pending capacity is refused");

    gate.release;

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2;

      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "completion notification succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, 2, "two accepted jobs complete");
    A.assert_true
      (reporter,
       handler.identities(1) = first,
       "first completion retains request identity");
    A.assert_true
      (reporter,
       handler.identities(2) = second,
       "second completion retains request identity");
    A.assert_true
      (reporter,
       handler.bytes_seen > 0,
       "worker output returns through completion boundary");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "shutdown begins");
    A.assert_true
      (reporter, not E.is_accepting(executor), "shutdown stops admission");

    status := E.submit_stdin
      (executor,
       third,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.INVALID_STATE and then not accepted,
       "shutdown rejects new work as invalid state");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when E.is_idle(executor) and then E.completed_count(executor) = 0;

      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "shutdown notification drain succeeds");
    end loop;

    A.assert_true
      (reporter, E.is_idle(executor), "accepted work drains before finalize");

    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "executor finalizes");

    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "event loop finalizes");
  end bounded_saturation_and_shutdown;

  procedure shared_application_callbacks_may_run_concurrently
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    gate       : aliased Concurrency_Gate;
    app        : aliased Concurrent_Application;
    handler    : aliased Test_Completion_Handler;
    first      : constant R.Identity :=
      (connection_id => 101, request_id => 1, generation => 1);
    second     : constant R.Identity :=
      (connection_id => 102, request_id => 1, generation => 1);
    data       : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    dispatched : Boolean;
    started    : Natural;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "shared-application event loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 2, 2, 64, 64);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "shared-application executor initializes");
    app.concurrency_gate := gate'Unchecked_Access;

    status := E.submit_stdin
      (executor, first, app'Unchecked_Access, handler'Unchecked_Access,
       data, 0, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "first shared-application callback submits");
    status := E.submit_stdin
      (executor, second, app'Unchecked_Access, handler'Unchecked_Access,
       data, 0, accepted);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "second shared-application callback submits");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when gate.started_count = 2;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "shared-application concurrency wait succeeds");
    end loop;

    started := gate.started_count;
    gate.release;
    A.assert_equal_natural
      (reporter, started, 2,
       "one Application instance may run concurrently across connections");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "shared-application completion drain succeeds");
    end loop;
    A.assert_equal_natural
      (reporter, handler.count, 2,
       "both shared-application callbacks complete");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "shared-application executor shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "shared-application executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "shared-application event loop finalizes");
  end shared_application_callbacks_may_run_concurrently;

  procedure ordinary_completion_delivery_is_byte_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Large_Completion_Application;
    handler    : aliased Slice_Completion_Handler;
    request    : constant R.Identity :=
      (connection_id => 77, request_id => 9, generation => 1);
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "completion-slice event loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 1, 64, 262_144);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "completion-slice executor initializes");

    status := E.submit_stdin_end
      (executor, request, app'Unchecked_Access, handler'Unchecked_Access,
       262_144, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "large ordinary completion submits");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count > 0;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "first completion-slice notification succeeds");
    end loop;

    A.assert_true
      (reporter, app.write_ok, "large ordinary output is produced");
    A.assert_equal_natural
      (reporter, handler.count, 1,
       "first notification delivers one bounded ordinary slice");
    A.assert_positive
      (reporter, Integer(handler.lengths(1)),
       "first ordinary slice carries output bytes");
    A.assert_true
      (reporter, handler.lengths(1) <= ET.completion_delivery_budget,
       "first ordinary slice stays within notification byte budget");
    A.assert_false
      (reporter, handler.finals(1),
       "large ordinary completion remains pending after first slice");
    A.assert_true
      (reporter, handler.records_ok,
       "ordinary completion slices end on complete FastCGI records");
    A.assert_equal_natural
      (reporter, E.completed_count(executor), 1,
       "pending ordinary slice remains visible as a completion");
    A.assert_false
      (reporter, E.is_idle(executor),
       "executor is not idle while ordinary delivery is pending");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when E.completed_count(executor) = 0;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK,
         "remaining completion-slice notification succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, 2,
       "large ordinary completion drains in two owner slices");
    A.assert_true
      (reporter, handler.finals(2),
       "second ordinary slice is final");
    A.assert_true
      (reporter, handler.lengths(2) <= ET.completion_delivery_budget,
       "final ordinary slice stays within notification byte budget");
    A.assert_true
      (reporter, handler.bytes_seen > ET.completion_delivery_budget,
       "test completion exceeds one notification byte budget");
    A.assert_true
      (reporter, handler.records_ok,
       "all ordinary slices preserve FastCGI record boundaries");
    A.assert_true
      (reporter, E.is_idle(executor),
       "executor becomes idle after final ordinary slice");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "completion-slice shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "completion-slice executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK,
       "completion-slice event loop finalizes");
  end ordinary_completion_delivery_is_byte_bounded;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "idle executor has no periodic dispatch",
       idle_executor_has_no_periodic_dispatch'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "connection identity exhaustion",
       connection_identity_exhaustion'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "executor runtime coordination",
       executor_runtime_coordination'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "capacity waiter lifecycle",
       capacity_waiter_lifecycle'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "capacity waiter failure preserves progress",
       capacity_waiter_failure_preserves_progress'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "capacity wait budget rearms",
       capacity_wait_budget_rearms'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "capacity requeue waits for completion",
       capacity_requeue_waits_for_completion'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "notification rearms after handler failure",
       notification_rearms_after_handler_failure'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "batch submission semantics",
       batch_submission_semantics'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "role terminal deferral",
       role_terminal_deferral'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "zero deferred capacity disables deferral",
       zero_deferred_capacity_disables_deferral'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "admission index resists ordered churn",
       admission_index_resists_ordered_churn'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred index resists ordered churn",
       deferred_index_resists_ordered_churn'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred capacity is bounded",
       deferred_capacity_is_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred writable wait is event driven",
       deferred_writable_wait_is_event_driven'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred connection groups are indexed",
       deferred_connection_groups_are_indexed'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "notification rearms after bounded drain",
       notification_rearms_after_bounded_drain'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred delivery is byte bounded",
       deferred_delivery_is_byte_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred cancellation releases retained slice",
       deferred_delivery_cancellation_releases_reservation'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "shared Application callbacks may run concurrently",
       shared_application_callbacks_may_run_concurrently'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "ordinary completion delivery is byte bounded",
       ordinary_completion_delivery_is_byte_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded saturation and shutdown",
       bounded_saturation_and_shutdown'access);
  end run;

end Tests.Execution;
