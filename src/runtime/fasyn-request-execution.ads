-- ============================================================================
-- fasyn-request-execution.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.Status;
with Clair.Worker_Pool;
with Fasyn.Protocol;
with Interfaces;

package Fasyn.Request.Execution is

  type Operation_Kind is
    (Deliver_Parameter,
     Finish_Params,
     Deliver_Stdin,
     Finish_Stdin,
     Deliver_Data,
     Finish_Data);

  type Deferred_Output_Kind is
    (Deferred_Stdout_Output, Deferred_Stderr_Output, Deferred_Finish_Output);

  DEFERRED_OUTPUT_CHUNK_BYTES : constant Positive := 16_384;

  DEFAULT_DEFERRED_CAPACITY : constant Positive := 256;

  type Completion is private;

  type Completion_Handler is limited interface;
  type Completion_Handler_Access is access all Completion_Handler'Class;

  function on_completion
    (handler         : in out Completion_Handler;
     item            : in Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is abstract;

  type Context is limited new Clair.Event_Loop.Timer_Handler with private;
  type Context_Access is access all Context;

  --! `event_loop` must remain alive until this Context has finalized
  --! successfully.
  function initialize
    (self             : in out Context;
     event_loop       : Clair.Event_Loop.Context_Access;
     worker_count     : Positive;
     pending_capacity : Positive;
     max_input_bytes  : Positive;
     max_output_bytes  : Positive;
     poll_interval     : Clair.Event_Loop.Milliseconds := 1;
     deferred_capacity : Positive := DEFAULT_DEFERRED_CAPACITY)
     return Clair.Status.Code;

  function begin_shutdown
    (self : in out Context) return Clair.Status.Code;

  function signal_cancellation
    (self    : in out Context;
     request : Request_Identity;
     cause   : Cancellation_Cause) return Clair.Status.Code;

  function finalize
    (self : in out Context) return Clair.Status.Code;

  --! For every accepted submission, `application` must remain alive until its
  --! callback returns, and `completion_handler` must remain alive until the
  --! corresponding completion has been delivered or the request is retired.
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
     return Clair.Status.Code;

  function submit_params_end
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  function submit_stdin
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  function submit_stdin_end
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  function submit_data
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Filter)
     return Clair.Status.Code;

  function submit_data_end
    (self               : in out Context;
     request            : Request_Identity;
     application        : Application_Access;
     completion_handler : Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Filter)
     return Clair.Status.Code;

  function completion_request (item : Completion) return Request_Identity;
  function operation (item : Completion) return Operation_Kind;
  function output_length (item : Completion) return Natural;
  function output_byte
    (item  : Completion;
     index : Positive) return Fasyn.Protocol.Byte;
  function output_finished (item : Completion) return Boolean;
  function output_failed (item : Completion) return Boolean;
  function is_deferred_output (item : Completion) return Boolean;

  function deferred_kind (item : Completion) return Deferred_Output_Kind;
  function deferred_data_length (item : Completion) return Natural;
  procedure copy_deferred_data
    (item   : in Completion;
     offset : in Natural;
     target : out Fasyn.Protocol.Byte_Array;
     copied : out Natural);
  function deferred_application_status
    (item : Completion) return Interfaces.Unsigned_32;

  function deferred_requested
    (self    : Context;
     request : Request_Identity) return Boolean;

  function activate_deferred
    (self               : in out Context;
     request            : Request_Identity;
     request_pending    : Natural;
     request_limit      : Positive;
     connection_pending : Natural;
     connection_limit   : Positive) return Clair.Status.Code;

  procedure retire_deferred
    (self    : in out Context;
     request : Request_Identity;
     cause   : Cancellation_Cause := Not_Cancelled);

  procedure set_deferred_connection_busy
    (self          : in out Context;
     connection_id : Connection_Identity;
     busy          : Boolean);

  procedure sync_deferred_connection
    (self          : in out Context;
     connection_id : Connection_Identity;
     pending       : Natural);

  procedure sync_deferred_request
    (self    : in out Context;
     request : Request_Identity;
     pending : Natural);

  function deferred_pending_bytes
    (self    : Context;
     request : Request_Identity) return Natural;

  function deferred_connection_pending_bytes
    (self          : Context;
     connection_id : Connection_Identity) return Natural;

  function is_accepting (self : Context) return Boolean;
  function is_idle (self : Context) return Boolean;
  function pending_count (self : Context) return Natural;
  function active_count (self : Context) return Natural;
  function completed_count (self : Context) return Natural;

  overriding function on_timer
    (self  : in out Context;
     timer : Clair.Event_Loop.Handle) return Clair.Status.Code;

private

  type Request_Identity_Array is
    array (Positive range <>) of Request_Identity;

  type Request_Context_Access_Array is
    array (Positive range <>) of Request_Context_Access;

  protected type Admission_State (capacity : Positive) is
    procedure reserve
      (request  : in Request_Identity;
       context  : in Request_Context_Access;
       accepted : out Boolean);
    procedure release (request : in Request_Identity);
    function context_for
      (request : Request_Identity) return Request_Context_Access;
    function reserved_count return Natural;
    function context_at (index : Positive) return Request_Context_Access;
    function is_empty return Boolean;
  private
    identities : Request_Identity_Array (1 .. capacity) :=
      [others => NULL_REQUEST_IDENTITY];
    contexts : Request_Context_Access_Array (1 .. capacity) :=
      [others => null];
    count : Natural := 0;
  end Admission_State;

  type Admission_State_Access is access Admission_State;

  type Work_Item
    (name_capacity   : Positive;
     value_capacity  : Positive;
     data_capacity   : Positive;
     output_capacity : Positive)
  is limited record
    request_value      : Request_Identity := NULL_REQUEST_IDENTITY;
    operation_value    : Operation_Kind := Deliver_Parameter;
    application        : Application_Access := null;
    completion_handler : Completion_Handler_Access := null;
    name_bytes         : Fasyn.Protocol.Byte_Array (1 .. name_capacity);
    name_length        : Natural := 0;
    value_bytes        : Fasyn.Protocol.Byte_Array (1 .. value_capacity);
    value_length       : Natural := 0;
    data_bytes         : Fasyn.Protocol.Byte_Array (1 .. data_capacity);
    data_length        : Natural := 0;
    deferred_kind      : Deferred_Output_Kind := Deferred_Stdout_Output;
    deferred_status    : Interfaces.Unsigned_32 := 0;
    callback_context    : aliased Request_Context;
    response           : Writer (max_output_bytes => output_capacity);
  end record;

  type Work_Item_Access is access Work_Item;

  procedure execute_job (job : in out Work_Item_Access);

  package Pool is new Clair.Worker_Pool
    (Job_Type => Work_Item_Access,
     execute  => execute_job);

  type Completion is record
    item            : Work_Item_Access := null;
    deferred_output : Boolean := False;
  end record;

  type Context is limited new Clair.Event_Loop.Timer_Handler with record
    event_loop       : Clair.Event_Loop.Context_Access := null;
    timer            : Clair.Event_Loop.Handle := Clair.Event_Loop.NULL_HANDLE;
    workers          : Pool.Context;
    admission        : Admission_State_Access := null;
    max_input_bytes  : Positive := 1;
    max_output_bytes  : Positive := 1;
    deferred_target   : Deferred_Target_Access := null;
    initialized       : Boolean := False;
    pool_initialized : Boolean := False;
    timer_active     : Boolean := False;
  end record;

end Fasyn.Request.Execution;
