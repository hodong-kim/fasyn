-- ============================================================================
-- fasyn-request-execution.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.Status;
private with Clair.Worker_Pool;
with Fasyn.Protocol;
with Interfaces;

package Fasyn.Request.Execution is

  type Deferred_Output_Kind is
    (Deferred_Stdout_Output, Deferred_Stderr_Output, Deferred_Finish_Output);

  DEFAULT_DEFERRED_CAPACITY : constant Positive := 256;

  --! Callback-scoped view of one completed work item. Accessors are valid
  --! only while `on_completion` is running; do not retain or copy it for later.
  --! Borrowed callback view created only by the executor. Applications cannot
  --! construct a standalone Completion; all accessors require the callback value.
  type Completion (<>) is limited private;

  type Completion_Handler is limited interface;
  type Completion_Handler_Access is access all Completion_Handler'Class;

  --! For ordinary work, `callback_status` reports callback execution status;
  --! deferred-output delivery passes `OK`. A non-`OK` handler return stops the
  --! current completion-drain pass and propagates, but already-published
  --! remaining work is re-signaled before the callback returns.
  function on_completion
    (self            : in out Completion_Handler;
     item            : in Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is abstract;

  type Capacity_Waiter is limited interface;
  type Capacity_Waiter_Access is access all Capacity_Waiter'Class;

  --! Runs on the owning Event Loop after executor admission capacity is
  --! released and before the releasing completion handler may submit follow-up
  --! work. The waiter was removed from the FIFO before this callback, so it may
  --! re-register if submission still cannot proceed.
  function on_capacity_available
    (self : in out Capacity_Waiter) return Clair.Status.Code
  is abstract;

  --! Intrusive caller-owned wait node. Registration and removal are
  --! owner-thread operations and allocate no memory. The node must outlive any
  --! registration.
  type Capacity_Wait_Node is limited private;

  type Context is limited private;
  type Context_Access is access all Context;

  --! `event_loop` must remain alive until this Context has finalized
  --! successfully. Completions and deferred commands wake that loop through
  --! one coalesced notification source; no periodic polling timer is used.
  --! Reinitialization returns `INVALID_STATE`; capacity overflow returns
  --! `RANGE_ERROR`. `deferred_capacity = 0` disables application response
  --! deferral while synchronous execution/completion remains available.
  function initialize
    (self             : aliased in out Context;
     event_loop       : not null Clair.Event_Loop.Context_Access;
     worker_count     : Positive;
     pending_capacity : Positive;
     max_input_bytes   : Positive;
     max_output_bytes  : Positive;
     deferred_capacity : Natural := DEFAULT_DEFERRED_CAPACITY)
     return Clair.Status.Code;

  --! Registers one FIFO capacity waiter without allocation after a bounded
  --! executor submission returned `OK` with `accepted = False`. Re-registering
  --! the same node with the same handler is idempotent. The owning Event Loop
  --! thread must unregister the node before either the waiter or executor can
  --! finalize. A retry that still finds the Worker Pool pending queue full may
  --! re-register and waits for a later completion rather than self-polling.
  function wait_for_capacity
    (self   : aliased in out Context;
     node   : aliased in out Capacity_Wait_Node;
     waiter : not null Capacity_Waiter_Access) return Clair.Status.Code;

  --! Removes a registered capacity waiter in O(1). An unregistered node is a
  --! successful no-op.
  function cancel_capacity_wait
    (self : aliased in out Context;
     node : aliased in out Capacity_Wait_Node) return Clair.Status.Code;

  --! Stops new worker-pool admission and signals `Runtime_Shutdown` to
  --! reserved work. Returns `INVALID_STATE` while an executor-capacity waiter
  --! remains registered; connection owners must unregister those waiters before
  --! shutdown. Deferred writable waiters are instead retired and scheduled so
  --! their producers can observe closure.
  function begin_shutdown
    (self : in out Context) return Clair.Status.Code;

  --! Returns `INVALID_ARGUMENT` for a null request or `Not_Cancelled`. A valid
  --! request absent from worker admission is not an error; matching deferred
  --! state is still retired, otherwise cancellation is a successful no-op.
  function signal_cancellation
    (self    : in out Context;
     request : Identity;
     cause   : Cancellation_Cause) return Clair.Status.Code;

  --! Requires worker admission stopped, the pool idle, no queued
  --! completions, no reserved requests, no registered capacity waiters, and no
  --! queued or dispatching deferred writable waiters; otherwise returns
  --! `INVALID_STATE`.
  function finalize
    (self : in out Context) return Clair.Status.Code;

  --! For every accepted submission, `application` must remain alive until its
  --! callback returns, and `completion_handler` must remain alive until the
  --! corresponding completion has been delivered or the request is retired.
  --! Accepted input arrays are copied before return. Capacity rejection occurs
  --! before work-item payload allocation/copy; `OK` with `accepted = False`
  --! means only transient bounded backpressure. `INVALID_STATE` reports an
  --! executor that is not accepting or a request identity already in flight.
  --! `RANGE_ERROR` reports an output limit beyond executor capacity.
  function submit_parameter
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     name               : Fasyn.Protocol.Byte_Array;
     value              : Fasyn.Protocol.Byte_Array;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  --! Uses the same lifetime and backpressure contract as `submit_parameter`.
  function submit_params_end
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  --! Uses the same lifetime and backpressure contract as `submit_parameter`.
  function submit_stdin
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  --! Uses the same lifetime and backpressure contract as `submit_parameter`.
  function submit_stdin_end
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  --! Uses the same lifetime and backpressure contract as `submit_parameter`.
  function submit_data
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code;

  --! Uses the same lifetime and backpressure contract as `submit_parameter`.
  function submit_data_end
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code;

  function completion_request (item : Completion) return Identity;
  function output_length (item : Completion) return Natural;
  --! `output_byte` is defined only for indices `1 .. output_length(item)`.
  function output_byte
    (item  : Completion;
     index : Positive) return Fasyn.Protocol.Byte;
  function output_finished (item : Completion) return Boolean;
  function output_failed (item : Completion) return Boolean;
  --! True only when this callback presents the final slice of the completed
  --! work item. Intermediate slices keep the owning connection application
  --! work paused until a later notification resumes delivery.
  function delivery_complete (item : Completion) return Boolean;
  function is_deferred_output (item : Completion) return Boolean;

  --! Deferred-output accessors below require `is_deferred_output(item)`;
  --! otherwise they raise `Program_Error`.
  function deferred_kind (item : Completion) return Deferred_Output_Kind;
  --! Requires a deferred-output Completion; otherwise raises `Program_Error`.
  --! For sliced deferred delivery this is the payload length presented by the
  --! current callback, not the original staged command's total payload length.
  function deferred_data_length (item : Completion) return Natural;
  --! `offset` is zero-based within the current deferred-delivery slice. Returns
  --! zero when the offset is past that slice or `target` is empty.
  function copy_deferred_data
    (item   : in Completion;
     offset : in Natural;
     target : out Fasyn.Protocol.Byte_Array) return Natural;
  --! Requires a deferred-output Completion; otherwise raises `Program_Error`.
  function deferred_application_status
    (item : Completion) return Interfaces.Unsigned_32;

  function is_initialized (self : Context) return Boolean;
  function is_accepting (self : Context) return Boolean;
  function is_idle (self : Context) return Boolean;
  function pending_count (self : Context) return Natural;
  function active_count (self : Context) return Natural;
  function completed_count (self : Context) return Natural;

private

  type Operation_Kind is
    (Deliver_Parameter,
     Deliver_Parameter_Batch,
     Deliver_Parameter_Batch_And_Finish,
     Finish_Params,
     Deliver_Stdin,
     Deliver_Stdin_And_Finish,
     Finish_Stdin,
     Deliver_Data,
     Deliver_Data_And_Finish,
     Finish_Data);

  DEFERRED_OUTPUT_CHUNK_BYTES : constant Positive := 16_384;
  MAX_PARAMETER_PAIRS_PER_BATCH : constant Positive := 64;

  --! `encoded` contains one or more canonical FastCGI name-value pairs.
  --! At most `MAX_PARAMETER_PAIRS_PER_BATCH` pairs are accepted. When
  --! `finish_params` is True, the worker delivers the pairs in order and then
  --! invokes `on_params_end` in the same work item.
  function submit_parameter_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     encoded            : Fasyn.Protocol.Byte_Array;
     finish_params      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  --! Bounded internal stream batch. `finish_stream` combines the final data
  --! callback and `on_stdin_end` while preserving role-specific Writer limits.
  function submit_stdin_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     finish_stream      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean;
     role               : Fasyn.Protocol.Role := Fasyn.Protocol.Responder)
     return Clair.Status.Code;

  --! Bounded internal Filter DATA batch. `finish_stream` combines the final
  --! data callback and `on_data_end` in one work item.
  function submit_data_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     finish_stream      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code;

  function uses_event_loop
    (self       : Context;
     event_loop : not null Clair.Event_Loop.Context_Access) return Boolean;

  function issue_connection_identity
    (self     : in out Context;
     identity : out Connection_Identity) return Clair.Status.Code;

  function supports_work_limits
    (self                  : Context;
     required_input_bytes  : Positive;
     required_output_bytes : Positive) return Boolean;

  function supports_batch_input_bytes
    (self           : Context;
     required_bytes : Positive) return Boolean;

  function deferred_requested
    (self    : Context;
     request : Identity) return Boolean;

  function activate_deferred
    (self               : in out Context;
     request            : Identity;
     request_pending    : Natural;
     request_limit      : Positive;
     connection_pending : Natural;
     connection_limit   : Positive) return Clair.Status.Code;

  procedure retire_deferred
    (self    : in out Context;
     request : Identity;
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
     request : Identity;
     pending : Natural);

  function deferred_pending_bytes
    (self    : Context;
     request : Identity) return Natural;

  function deferred_connection_pending_bytes
    (self          : Context;
     connection_id : Connection_Identity) return Natural;

  function internal_deferred_indices_consistent
    (self : Context) return Boolean;

  type Notification_Adapter is limited record
    owner : Context_Access := null;
  end record;

  function on_notification
    (self   : in out Notification_Adapter;
     source : Clair.Event_Loop.Source_Handle) return Clair.Status.Code;

  type Capacity_Wait_Node_Access is access all Capacity_Wait_Node;

  type Capacity_Wait_Node is limited record
    owner      : Context_Access := null;
    waiter     : Capacity_Waiter_Access := null;
    previous   : Capacity_Wait_Node_Access := null;
    next       : Capacity_Wait_Node_Access := null;
    registered : Boolean := False;
  end record;

  type Admission_Entry is record
    request         : Identity := NULL_IDENTITY;
    context         : Callback_Context_Access := null;
    cause           : Cancellation_Cause := Not_Cancelled;
    active_position : Natural := 0;
    tree_parent     : Natural := 0;
    tree_left       : Natural := 0;
    tree_right      : Natural := 0;
    tree_height     : Positive := 1;
    free_next       : Natural := 0;
    in_use          : Boolean := False;
  end record;

  type Admission_Entry_Array is
    array (Positive range <>) of Admission_Entry;
  type Admission_Index_Array is array (Positive range <>) of Natural;

  type Reservation_Result is
    (Reservation_Accepted, Reservation_Full, Reservation_Not_Accepting,
     Reservation_Duplicate);

  protected type Admission_State (capacity : Positive) is
    procedure reserve
      (request : in Identity;
       result  : out Reservation_Result);
    procedure stop_accepting;
    procedure prepare_shutdown_entry
      (index   : in Positive;
       cause   : in Cancellation_Cause;
       request : out Identity;
       context : out Callback_Context_Access);
    procedure bind_context
      (request : in Identity;
       context : in Callback_Context_Access;
       cause   : out Cancellation_Cause);
    procedure note_cancellation
      (request : in Identity;
       cause   : in Cancellation_Cause;
       context : out Callback_Context_Access);
    procedure release (request : in Identity);
    function reserved_count return Natural;
    function has_capacity return Boolean;
    function is_accepting return Boolean;
    function is_empty return Boolean;
    function indices_consistent return Boolean;
  private
    entries      : Admission_Entry_Array (1 .. capacity);
    active_order : Admission_Index_Array (1 .. capacity) := [others => 0];
    count        : Natural := 0;
    tree_root    : Natural := 0;
    next_unused  : Natural := 1;
    free_head    : Natural := 0;
    accepting    : Boolean := True;
  end Admission_State;

  type Admission_State_Access is access Admission_State;

  COMPLETION_BYTES_PER_NOTIFICATION : constant Positive := 131_072;

  type Work_Item
    (name_capacity   : Positive;
     value_capacity  : Positive;
     data_capacity   : Positive;
     output_capacity : Positive)
  is limited record
    request_value      : Identity := NULL_IDENTITY;
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
    callback_context    : aliased Fasyn.Request.Context
      (callback_owned => True);
    response           : Writer (max_output_bytes => output_capacity);
  end record;

  type Work_Item_Access is access Work_Item;

  procedure execute_job (job : in out Work_Item_Access);

  package Pool is new Clair.Worker_Pool
    (Job_Type => Work_Item_Access,
     execute  => execute_job);

  type Completion (executor_owned : Boolean) is limited record
    item              : Work_Item_Access := null;
    deferred_output   : Boolean := False;
    delivery_offset   : Natural := 0;
    delivery_length   : Natural := 0;
    delivery_is_final : Boolean := True;
  end record;

  type Context is limited record
    notification_handler : aliased Notification_Adapter;
    event_loop          : Clair.Event_Loop.Context_Access := null;
    notification_source : Clair.Event_Loop.Source_Handle :=
      Clair.Event_Loop.NULL_SOURCE;
    workers          : Pool.Context;
    admission        : Admission_State_Access := null;
    max_input_bytes       : Positive := 1;
    max_batch_input_bytes : Positive := 1;
    max_output_bytes      : Positive := 1;
    next_connection_identity : Connection_Identity := 1;
    connection_identity_exhausted : Boolean := False;
    capacity_wait_head : Capacity_Wait_Node_Access := null;
    capacity_wait_tail : Capacity_Wait_Node_Access := null;
    capacity_wait_dispatching : Boolean := False;
    capacity_wake_pending : Boolean := False;
    delivery_job      : Work_Item_Access := null;
    delivery_status   : Clair.Status.Code := Clair.Status.OK;
    delivery_offset   : Natural := 0;
    deferred_delivery_job    : Work_Item_Access := null;
    deferred_delivery_offset : Natural := 0;
    deferred_target   : Deferred_Target_Access := null;
    deferred_enabled  : Boolean := False;
    initialized       : Boolean := False;
    pool_initialized     : Boolean := False;
    notification_active  : Boolean := False;
  end record;

end Fasyn.Request.Execution;
