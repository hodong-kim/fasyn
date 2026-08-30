-- ============================================================================
-- fasyn-request-connection.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.IO;
with Clair.Status;
with Fasyn.Protocol.Codec;
with Fasyn.Protocol.Management;
with Fasyn.Diagnostics;
with Fasyn.Request.Admission;
with Fasyn.Request.Execution;

package Fasyn.Request.Connection is

  --! Total accepted request-stream bytes. These are workload bounds, distinct
  --! from the much smaller resident input buffers used while streaming.
  type Stream_Limits is record
    max_params_bytes : Positive := 1_048_576;
    max_stdin_bytes  : Positive := 1_073_741_824;
    max_data_bytes   : Positive := 1_073_741_824;
  end record;

  DEFAULT_STREAM_LIMITS : constant Stream_Limits :=
    (max_params_bytes => 1_048_576,
     max_stdin_bytes  => 1_073_741_824,
     max_data_bytes   => 1_073_741_824);

  type Context
    (max_requests_per_connection : Positive;
     max_name_bytes              : Positive;
     max_value_bytes             : Positive;
     max_request_output_bytes    : Positive;
     max_output_bytes            : Positive;
     read_buffer_bytes           : Positive;
     write_chunk_bytes           : Positive)
  is limited new Clair.Event_Loop.IO_Handler
    and Clair.Event_Loop.Timer_Handler
    and Fasyn.Request.Execution.Completion_Handler with private;

  type Context_Access is access all Context;

  --! `fd` must already be nonblocking. On success, ownership of `fd` transfers
  --! to this context and remains here until the connection is closed or the
  --! context is finalized. Application callbacks are submitted through the
  --! bounded executor and never run on the connection I/O callback. The request
  --! timeout remains authoritative until the request and its queued completion
  --! output retire from the connection. `event_loop`, `handler`, `executor`,
  --! and any supplied `admission` or `diagnostics` object must remain alive
  --! until this Context has finalized successfully.
  function initialize
    (self            : in out Context;
     event_loop      : Clair.Event_Loop.Context_Access;
     fd              : Clair.IO.Descriptor;
     handler         : Application_Access;
     executor        : Fasyn.Request.Execution.Context_Access;
     request_timeout : Clair.Event_Loop.Milliseconds;
     connection_id   : Connection_Identity;
     admission       : Fasyn.Request.Admission.Context_Access := null;
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
  function finalize (self : in out Context) return Clair.Status.Code;

  function is_active (self : Context) return Boolean;
  function is_read_paused (self : Context) return Boolean;
  function active_request_count (self : Context) return Natural;
  function pending_input_bytes (self : Context) return Natural;
  function pending_output_bytes (self : Context) return Natural;

  --! Returns True only while this exact connection/request generation is still
  --! active on the wire. A reused request ID therefore never validates an older
  --! identity, and equal request generations on different connections remain
  --! distinct.
  function request_is_current
    (self    : Context;
     request : Request_Identity) return Boolean;

  overriding function on_io
    (self   : in out Context;
     io     : Clair.Event_Loop.Handle;
     fd     : Clair.IO.Descriptor;
     events : Clair.Event_Loop.Event_Mask) return Clair.Status.Code;

  overriding function on_timer
    (self  : in out Context;
     timer : Clair.Event_Loop.Handle) return Clair.Status.Code;

  overriding function on_completion
    (self            : in out Context;
     item            : in Fasyn.Request.Execution.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code;

private

  package A renames Fasyn.Request.Admission;
  package E renames Fasyn.Request.Execution;
  package PM renames Fasyn.Protocol.Management;

  CONTROL_OUTPUT_CAPACITY    : constant Positive := 256;
  MANAGEMENT_RESULT_CAPACITY : constant Positive := 192;
  NO_OUTPUT_SOURCE            : constant Integer := -1;
  CONTROL_OUTPUT_SOURCE   : constant Integer := 0;
  EXECUTION_RETRY_INTERVAL : constant Clair.Event_Loop.Milliseconds := 1;

  type Dispatch_Application is new Application with record
    owner : Context_Access := null;
  end record;

  overriding procedure on_parameter
    (self    : in out Dispatch_Application;
     context : in Request_Context;
     name    : in Fasyn.Protocol.Byte_Array;
     value   : in Fasyn.Protocol.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     response : in out Writer);

  overriding procedure on_stdin
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer);

  overriding procedure on_stdin_end
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     response : in out Writer);

  overriding procedure on_data
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer);

  overriding procedure on_data_end
    (self     : in out Dispatch_Application;
     context  : in Request_Context;
     response : in out Writer);

  type Request_Slot
    (max_name_bytes           : Positive;
     max_value_bytes          : Positive;
     max_request_output_bytes : Positive)
  is limited record
    exchange : Fasyn.Request.Exchange
      (max_name_bytes  => max_name_bytes,
       max_value_bytes => max_value_bytes);
    response : Writer (max_output_bytes => max_request_output_bytes);
    identity_value : Request_Identity := NULL_REQUEST_IDENTITY;
    timeout_timer  : Clair.Event_Loop.Handle := Clair.Event_Loop.NULL_HANDLE;
    params_bytes   : Natural := 0;
    stdin_bytes    : Natural := 0;
    data_bytes     : Natural := 0;
    application_deferred : Boolean := False;
    in_use         : Boolean := False;
  end record;

  type Request_Slot_Access is access Request_Slot;
  type Request_Slot_Array is
    array (Positive range <>) of Request_Slot_Access;

  type Context
    (max_requests_per_connection : Positive;
     max_name_bytes              : Positive;
     max_value_bytes             : Positive;
     max_request_output_bytes    : Positive;
     max_output_bytes            : Positive;
     read_buffer_bytes           : Positive;
     write_chunk_bytes           : Positive)
  is limited new Clair.Event_Loop.IO_Handler
    and Clair.Event_Loop.Timer_Handler
    and E.Completion_Handler with record
    event_loop   : Clair.Event_Loop.Context_Access := null;
    fd           : Clair.IO.Descriptor := Clair.IO.INVALID_DESCRIPTOR;
    watch        : Clair.Event_Loop.Handle := Clair.Event_Loop.NULL_HANDLE;
    handler      : Application_Access := null;
    executor     : E.Context_Access := null;
    shared_admission : A.Context_Access := null;
    diagnostics      : Fasyn.Diagnostics.Reporter_Access := null;
    admission_connection_owned : Boolean := False;
    request_timeout : Clair.Event_Loop.Milliseconds := 1;
    input_limits    : Stream_Limits := DEFAULT_STREAM_LIMITS;
    dispatcher   : aliased Dispatch_Application;
    decoder      : Fasyn.Protocol.Codec.Record_Decoder;
    management_query : PM.Query;
    management_active : Boolean := False;
    management_record_type : Fasyn.Protocol.Byte := 0;
    slots        : Request_Slot_Array (1 .. max_requests_per_connection) :=
      [others => null];
    connection_id : Connection_Identity := NO_CONNECTION_IDENTITY;
    active_requests : Natural := 0;
    next_generation : Request_Generation := 1;
    current_slot    : Natural := 0;
    next_output_slot : Positive := 1;
    output_source    : Integer := NO_OUTPUT_SOURCE;
    output_record_remaining : Natural := 0;
    control_bytes  : Fasyn.Protocol.Byte_Array (1 .. CONTROL_OUTPUT_CAPACITY);
    control_length : Natural := 0;
    input_bytes  : Fasyn.Protocol.Byte_Array (1 .. read_buffer_bytes);
    input_first  : Positive := 1;
    input_length : Natural := 0;
    paused_probe_bytes : Fasyn.Protocol.Byte_Array
      (1 .. Fasyn.Protocol.HEADER_LENGTH + 255);
    paused_probe_length : Natural := 0;
    paused_probe_target : Natural := Fasyn.Protocol.HEADER_LENGTH;
    paused_probe_is_abort : Boolean := False;
    stream_batch  : Fasyn.Protocol.Byte_Array (1 .. read_buffer_bytes);
    stream_batch_length : Natural := 0;
    deferred_name  : Fasyn.Protocol.Byte_Array (1 .. max_name_bytes);
    deferred_name_length : Natural := 0;
    deferred_value : Fasyn.Protocol.Byte_Array (1 .. max_value_bytes);
    deferred_value_length : Natural := 0;
    deferred_data  : Fasyn.Protocol.Byte_Array (1 .. read_buffer_bytes);
    deferred_data_length : Natural := 0;
    deferred_request : Request_Identity := NULL_REQUEST_IDENTITY;
    deferred_operation : E.Operation_Kind := E.Deliver_Parameter;
    retry_timer : Clair.Event_Loop.Handle := Clair.Event_Loop.NULL_HANDLE;
    inflight_jobs : Natural range 0 .. 1 := 0;
    initialized  : Boolean := False;
    watch_active : Boolean := False;
    read_paused  : Boolean := False;
    application_paused : Boolean := False;
    deferred_active : Boolean := False;
    retry_timer_active : Boolean := False;
    dispatch_failed : Boolean := False;
    skip_record  : Boolean := False;
    close_requested : Boolean := False;
    shutdown_requested : Boolean := False;
  end record;

end Fasyn.Request.Connection;
