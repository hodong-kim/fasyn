-- ============================================================================
-- fasyn-request-connection.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
private with System.Storage_Elements;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
private with Fasyn.Protocol.Codec;
private with Fasyn.Protocol.Management;
with Fasyn.Diagnostics;
with Fasyn.Admission;
with Fasyn.Request.Execution;
private with Fasyn.Request.Execution.Internal;

package Fasyn.Request.Connection is

  --! Total accepted request-stream bytes. These are workload bounds, distinct
  --! from the much smaller resident input buffers used while streaming.
  type Stream_Limits is record
    max_params_bytes : Natural := 1_048_576;
    max_stdin_bytes  : Natural := 1_073_741_824;
    max_data_bytes   : Natural := 1_073_741_824;
  end record;

  DEFAULT_STREAM_LIMITS : constant Stream_Limits :=
    (max_params_bytes => 1_048_576,
     max_stdin_bytes  => 1_073_741_824,
     max_data_bytes   => 1_073_741_824);

  --! Maximum continuous lifetime of an initialized connection while no
  --! application request is active. Transport bytes and management records do
  --! not refresh this deadline, so partial-byte trickle cannot retain a
  --! connection slot indefinitely.
  DEFAULT_IDLE_CONNECTION_TIMEOUT : constant Clair.Event_Loop.Milliseconds :=
    60_000;

  type Context
    (max_requests_per_connection : Positive;
     max_name_bytes              : Natural;
     max_value_bytes             : Natural;
     max_request_output_bytes    : Positive;
     max_connection_output_bytes : Positive;
     read_buffer_bytes           : Positive;
     write_chunk_bytes           : Positive)
  is limited private;

  type Context_Access is access all Context;

  type Initialization_Outcome is
    (Activated,
     Capacity_Refused,
     Failed_Releasable,
     Cleanup_Pending);

  --! `fd` must already be nonblocking. `Activated` transfers close ownership
  --! to this context until connection close/finalization. `Capacity_Refused`
  --! and `Failed_Releasable` leave the descriptor immediately releasable by the
  --! caller. `Cleanup_Pending` leaves close ownership with the caller but the
  --! same underlying descriptor must remain open until `finalize` succeeds.
  --! Application callbacks are submitted through the bounded executor and never
  --! run on the connection I/O callback. This connection keeps at most one
  --! application job in flight, but the same
  --! `application` may be called concurrently by other connections that share
  --! it; such a shared application must be thread-safe.
  --! `event_loop` must be the same loop used by `executor`; mismatched loop
  --! ownership is rejected so completion, timer, and socket callbacks stay
  --! serialized. The executor issues the connection identity, so simultaneous
  --! connections cannot alias asynchronous request generations through caller
  --! supplied IDs. `request_lifetime_timeout` remains authoritative until the
  --! request and its queued completion output retire from the connection. While
  --! no application request is active, `idle_connection_timeout` bounds the
  --! continuous zero-request lifetime and is not refreshed by arbitrary peer
  --! bytes or management records. Both timeout values must be positive.
  --! `Activated` borrows `event_loop`, `application`, `executor`,
  --! `admission`, and any supplied `diagnostics` until finalization.
  --! `Cleanup_Pending` retains only the Event Loop and shared admission
  --! lifetimes required for cleanup, keeps one connection admission slot, and
  --! requires successful `finalize` before reinitialization. Other outcomes
  --! retain no initialization borrow. Invalid or executor-incompatible
  --! configuration returns `INVALID_ARGUMENT`; an invalid descriptor returns
  --! `INVALID_HANDLE`. `OK + Capacity_Refused` is the only normal
  --! connection-capacity refusal. Non-OK results use `Failed_Releasable` or
  --! `Cleanup_Pending` to expose whether provider cleanup still imposes a
  --! descriptor lifetime obligation. An activated connection owns one
  --! admission slot until connection close or finalization releases it.
  function initialize
    (self            : aliased in out Context;
     event_loop      : not null Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     application     : not null Application_Access;
     executor        : not null Fasyn.Request.Execution.Context_Access;
     request_lifetime_timeout : Clair.Event_Loop.Milliseconds;
     idle_connection_timeout : Clair.Event_Loop.Milliseconds :=
       DEFAULT_IDLE_CONNECTION_TIMEOUT;
     admission       : not null Fasyn.Admission.Context_Access;
     outcome          : out Initialization_Outcome;
     diagnostics     : Fasyn.Diagnostics.Reporter_Access := null;
     input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS)
  return Clair.Status.Code;

  --! Stops input admission and cancels every active request with
  --! Runtime_Shutdown. Already-running application work may complete, but its
  --! output is rejected by request-generation cancellation state.
  function begin_shutdown (self : in out Context) return Clair.Status.Code;

  --! Removes the watch before closing the owned connection descriptor. If
  --! application work still holds this context as its completion target, the
  --! transport is closed but INVALID_STATE is returned until that work drains.
  --! Cleanup is recovery-safe: finalize may be called after failed
  --! initialization or again after successful finalization. A cleanup failure
  --! remains retryable. For `Cleanup_Pending`, successful finalization ends
  --! the provider descriptor-lifetime obligation. OK means no application work
  --! or owned/retained cleanup resource remains.
  function finalize (self : in out Context) return Clair.Status.Code;

  --! Successfully finalized contexts report inactive/zero observable state;
  --! request_is_current is False for every identity after finalization.
  function is_active (self : Context) return Boolean;
  function is_read_paused (self : Context) return Boolean;
  function active_requests (self : Context) return Natural;
  function pending_input_bytes (self : Context) return Natural;
  function pending_output_bytes (self : Context) return Natural;

  --! Returns True only while this exact connection/request generation is still
  --! active on the wire. A reused request ID therefore never validates an older
  --! identity, and equal request generations on different connections remain
  --! distinct.
  function request_is_current
    (self    : Context;
     request : Identity) return Boolean;

private

  package A renames Fasyn.Admission;
  package E renames Fasyn.Request.Execution;
  package EI renames Fasyn.Request.Execution.Internal;
  package PM renames Fasyn.Protocol.Management;

  -- Test/internal path that intentionally omits shared admission.
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
  return Clair.Status.Code;

  type Lifecycle_State is
    (Reusable_State,
     Active_State,
     Finalization_Required_State);

  type IO_Adapter is limited record
    owner : Context_Access := null;
  end record;

  function on_io
    (self   : in out IO_Adapter;
     io     : Clair.Event_Loop.Source_Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code;

  type Timer_Adapter is limited record
    owner      : Context_Access := null;
    slot_index : Natural := 0;
  end record;

  function on_timer
    (self  : in out Timer_Adapter;
     timer : Clair.Event_Loop.Source_Handle) return Clair.Status.Code;

  type Completion_Adapter is limited new E.Completion_Handler with record
    owner : Context_Access := null;
  end record;

  overriding function on_completion
    (self            : in out Completion_Adapter;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code;

  type Capacity_Adapter is limited new E.Capacity_Waiter with record
    owner : Context_Access := null;
  end record;

  overriding function on_capacity_available
    (self : in out Capacity_Adapter) return Clair.Status.Code;

  CONTROL_OUTPUT_CAPACITY      : constant Positive := 256;
  MANAGEMENT_RESULT_CAPACITY   : constant Positive := 192;
  INPUT_BYTES_PER_CALLBACK      : constant Positive := 65_536;
  OUTPUT_BYTES_PER_CALLBACK     : constant Positive := 65_536;
  NO_OUTPUT_SOURCE            : constant Integer := -1;
  CONTROL_OUTPUT_SOURCE       : constant Integer := 0;

  type Pending_Control_Kind is
    (No_Pending_Control,
     Pending_Protocol_Status,
     Pending_Get_Values_Result,
     Pending_Unknown_Type);

  type Application_Batch_Kind is
    (No_Application_Batch,
     Parameter_Application_Batch,
     Stdin_Application_Batch,
     Data_Application_Batch);

  type Byte_Buffer_Access is access Fasyn.Protocol.Byte_Array;
  type Storage_Buffer_Access is access System.Storage_Elements.Storage_Array;

  type Dispatch_Application is new Application with record
    owner : Context_Access := null;
  end record;

  overriding procedure on_parameter
    (self    : in out Dispatch_Application;
     context : in Fasyn.Request.Context;
     name    : in Fasyn.Protocol.Byte_Array;
     value   : in Fasyn.Protocol.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer);

  overriding procedure on_stdin
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer);

  overriding procedure on_stdin_end
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer);

  overriding procedure on_data
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer);

  overriding procedure on_data_end
    (self     : in out Dispatch_Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer);

  type Request_Slot
    (max_name_bytes           : Natural;
     max_value_bytes          : Natural;
     max_request_output_bytes : Positive)
  is limited record
    exchange : Fasyn.Request.Exchange
      (max_name_bytes  => max_name_bytes,
       max_value_bytes => max_value_bytes);
    response : Writer (max_output_bytes => max_request_output_bytes);
    accounted_output_bytes : Natural := 0;
    active_position : Natural := 0;
    tree_parent     : Natural := 0;
    tree_left       : Natural := 0;
    tree_right      : Natural := 0;
    tree_height     : Positive := 1;
    identity_value : Identity := NULL_IDENTITY;
    timeout_handler : aliased Timer_Adapter;
    timeout_timer   : Clair.Event_Loop.Source_Handle :=
                        Clair.Event_Loop.NULL_SOURCE;
    params_bytes   : Natural := 0;
    stdin_bytes    : Natural := 0;
    data_bytes     : Natural := 0;
    application_deferred : Boolean := False;
    deferred_previous : Natural := 0;
    deferred_next     : Natural := 0;
    retirement_ready  : Boolean := False;
    retirement_next   : Natural := 0;
    free_next         : Natural := 0;
    in_use            : Boolean := False;
  end record;

  type Request_Slot_Access is access Request_Slot;
  type Request_Slot_Array is
    array (Positive range <>) of Request_Slot_Access;
  type Request_Slot_Array_Access is access Request_Slot_Array;
  type Request_Slot_Index_Array is
    array (Positive range <>) of Natural;
  type Request_Slot_Index_Array_Access is access Request_Slot_Index_Array;

  type Context
    (max_requests_per_connection : Positive;
     max_name_bytes              : Natural;
     max_value_bytes             : Natural;
     max_request_output_bytes    : Positive;
     max_connection_output_bytes : Positive;
     read_buffer_bytes           : Positive;
     write_chunk_bytes           : Positive)
  is limited record
    io_handler         : aliased IO_Adapter;
    timer_handler      : aliased Timer_Adapter;
    completion_handler : aliased Completion_Adapter;
    capacity_handler   : aliased Capacity_Adapter;
    event_loop   : Clair.Event_Loop.Context_Access := null;
    fd           : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    watch        : Clair.Event_Loop.Source_Handle :=
                     Clair.Event_Loop.NULL_SOURCE;
    application  : Application_Access := null;
    executor     : E.Context_Access := null;
    shared_admission : A.Context_Access := null;
    diagnostics      : Fasyn.Diagnostics.Reporter_Access := null;
    admission_connection_owned : Boolean := False;
    request_lifetime_timeout : Clair.Event_Loop.Milliseconds := 1;
    idle_connection_timeout : Clair.Event_Loop.Milliseconds :=
      DEFAULT_IDLE_CONNECTION_TIMEOUT;
    idle_timer     : Clair.Event_Loop.Source_Handle :=
                       Clair.Event_Loop.NULL_SOURCE;
    input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS;
    dispatcher   : aliased Dispatch_Application;
    decoder      : Fasyn.Protocol.Codec.Record_Decoder;
    decoder_at_record_boundary : Boolean := True;
    management_query : PM.Query;
    management_active : Boolean := False;
    management_record_type : Fasyn.Protocol.Byte := 0;
    slots        : Request_Slot_Array_Access := null;
    slot_order   : Request_Slot_Index_Array_Access := null;
    slot_capacity    : Natural := 0;
    slot_order_count : Natural := 0;
    slot_tree_root   : Natural := 0;
    next_unused_slot : Natural := 1;
    free_slot_head     : Natural := 0;
    deferred_slot_head : Natural := 0;
    retirement_head    : Natural := 0;
    connection_id : Connection_Identity := NO_CONNECTION_IDENTITY;
    active_requests : Natural := 0;
    next_generation : Generation := 1;
    generation_exhausted : Boolean := False;
    current_slot    : Natural := 0;
    next_output_position : Positive := 1;
    output_source    : Integer := NO_OUTPUT_SOURCE;
    output_record_remaining : Natural := 0;
    input_budget_remaining  : Natural := 0;
    output_budget_remaining : Natural := 0;
    request_output_bytes    : Natural := 0;
    control_bytes  : Fasyn.Protocol.Byte_Array (1 .. CONTROL_OUTPUT_CAPACITY);
    control_length : Natural := 0;
    control_consumed : Natural := 0;
    pending_control : Pending_Control_Kind := No_Pending_Control;
    pending_control_request_id : Fasyn.Protocol.Request_Id := 0;
    pending_control_value : Fasyn.Protocol.Byte := 0;
    input_bytes  : Byte_Buffer_Access := null;
    input_first  : Positive := 1;
    input_length : Natural := 0;
    paused_probe_bytes : Fasyn.Protocol.Byte_Array
      (1 .. Fasyn.Protocol.HEADER_LENGTH + 255);
    paused_probe_length : Natural := 0;
    paused_probe_target : Natural := Fasyn.Protocol.HEADER_LENGTH;
    paused_probe_is_abort : Boolean := False;
    stream_batch  : Byte_Buffer_Access := null;
    stream_batch_length : Natural := 0;
    application_batch : Byte_Buffer_Access := null;
    application_batch_capacity : Natural := 0;
    application_batch_append_reserve : Natural := 0;
    application_batch_length : Natural := 0;
    application_batch_pairs : Natural := 0;
    application_batch_request : Identity := NULL_IDENTITY;
    batch_kind : Application_Batch_Kind := No_Application_Batch;
    application_batch_finish : Boolean := False;
    application_batch_ready : Boolean := False;
    application_batch_flush_requested : Boolean := False;
    deferred_name  : Byte_Buffer_Access := null;
    deferred_name_length : Natural := 0;
    deferred_value : Byte_Buffer_Access := null;
    deferred_value_length : Natural := 0;
    deferred_data  : Byte_Buffer_Access := null;
    deferred_data_length : Natural := 0;
    deferred_request : Identity := NULL_IDENTITY;
    deferred_operation : EI.Operation_Kind := EI.Deliver_Parameter;
    write_scratch : Storage_Buffer_Access := null;
    capacity_wait_node : aliased E.Capacity_Wait_Node;
    inflight_jobs : Natural range 0 .. 1 := 0;
    lifecycle    : Lifecycle_State := Reusable_State;
    watch_active : Boolean := False;
    read_paused  : Boolean := False;
    application_paused : Boolean := False;
    deferred_active : Boolean := False;
    execution_waiting : Boolean := False;
    dispatch_failed : Boolean := False;
    skip_record  : Boolean := False;
    close_requested : Boolean := False;
    shutdown_requested : Boolean := False;
  end record;

end Fasyn.Request.Connection;
