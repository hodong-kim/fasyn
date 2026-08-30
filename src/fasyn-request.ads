-- ============================================================================
-- fasyn-request.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Finalization;
with Interfaces;
with Fasyn.Protocol;
with Fasyn.Protocol.Messages;
with Fasyn.Protocol.Name_Values;

package Fasyn.Request is

  type Connection_Identity is new Interfaces.Unsigned_64;
  NO_CONNECTION_IDENTITY : constant Connection_Identity := 0;

  type Request_Generation is new Interfaces.Unsigned_64;
  NO_GENERATION : constant Request_Generation := 0;

  type Request_Identity is record
    connection_id : Connection_Identity := NO_CONNECTION_IDENTITY;
    request_id    : Fasyn.Protocol.Request_Id_Type := 0;
    generation    : Request_Generation := NO_GENERATION;
  end record;

  NULL_REQUEST_IDENTITY : constant Request_Identity :=
    (connection_id => NO_CONNECTION_IDENTITY,
     request_id    => 0,
     generation    => NO_GENERATION);

  type Cancellation_Cause is
    (Not_Cancelled,
     Peer_Abort,
     Request_Timeout,
     Resource_Limit,
     Runtime_Shutdown,
     Connection_Failure);

  type Request_Context is limited private;

  function is_null (request : Request_Identity) return Boolean;
  function identity (context : Request_Context) return Request_Identity;
  function cancellation_reason
    (context : Request_Context) return Cancellation_Cause;
  function cancellation_requested (context : Request_Context) return Boolean;
  function request_role (context : Request_Context) return Fasyn.Protocol.Role;

  type Write_Status is
    (Write_Complete,
     Output_Limit_Exceeded,
     Writer_Not_Ready,
     Writer_Closed);

  type Input_Status is
    (Input_Progress,
     Record_Complete,
     Request_Complete,
     Ignored_Inactive,
     Invalid_Record_Sequence,
     Wrong_Request_Id,
     Invalid_Content_Length,
     Invalid_Record_Type,
     Parameter_Limit_Exceeded,
     Malformed_Params,
     Output_Failed);

  type Writer
    (max_output_bytes : Positive)
  is limited private;

  procedure write_stdout
    (self   : in out Writer;
     data   : in Fasyn.Protocol.Byte_Array;
     status : out Write_Status);

  procedure write_stderr
    (self   : in out Writer;
     data   : in Fasyn.Protocol.Byte_Array;
     status : out Write_Status);

  procedure finish
    (self               : in out Writer;
     application_status : in Interfaces.Unsigned_32;
     status             : out Write_Status);

  --! A deferred request is an opaque capability for exactly one FastCGI
  --! connection/request generation. It never exposes transport ownership.
  --! Finalizing or dropping the handle releases only the capability; it does
  --! not finish or cancel the request, whose normal runtime lifetime remains
  --! authoritative.
  type Deferred_Request is
    limited new Ada.Finalization.Limited_Controlled with private;

  type Defer_Status is
    (Defer_Complete,
     Defer_Not_Allowed,
     Defer_Not_Ready,
     Defer_Capacity_Exceeded);

  type Deferred_Write_Status is
    (Deferred_Write_Complete,
     Deferred_Would_Block,
     Deferred_Output_Limit_Exceeded,
     Deferred_Resource_Failed,
     Deferred_Closed);

  --! Transfer terminal response ownership from the callback-scoped Writer to
  --! `request`. Deferral is accepted only at the terminal input callback for
  --! the active role. On success, further application writes through `response`
  --! are rejected and the executor worker may return immediately.
  procedure defer_response
    (context  : in Request_Context;
     response : in out Writer;
     request  : in out Deferred_Request;
     status   : out Defer_Status);

  --! Deferred writes are bounded. Deferred_Would_Block is transient and asks
  --! the producer to retry after queued output drains.
  --! Deferred_Output_Limit_Exceeded means the encoded operation cannot fit the
  --! configured request/connection limit even when otherwise empty.
  --! Deferred_Resource_Failed means the operation was not queued because its
  --! bounded staging allocation failed; the live handle may be retried.
  --! Deferred_Closed means the exact request generation is no longer writable.
  procedure write_stdout
    (self   : in out Deferred_Request;
     data   : in Fasyn.Protocol.Byte_Array;
     status : out Deferred_Write_Status);

  procedure write_stderr
    (self   : in out Deferred_Request;
     data   : in Fasyn.Protocol.Byte_Array;
     status : out Deferred_Write_Status);

  procedure finish
    (self               : in out Deferred_Request;
     application_status : in Interfaces.Unsigned_32;
     status             : out Deferred_Write_Status);

  function identity (request : Deferred_Request) return Request_Identity;
  function cancellation_reason
    (request : Deferred_Request) return Cancellation_Cause;
  function cancellation_requested
    (request : Deferred_Request) return Boolean;

  type Application is limited interface;
  type Application_Access is access all Application'Class;

  procedure on_parameter
    (self    : in out Application;
     context : in Request_Context;
     name    : in Fasyn.Protocol.Byte_Array;
     value   : in Fasyn.Protocol.Byte_Array)
  is abstract;

  procedure on_params_end
    (self     : in out Application;
     context  : in Request_Context;
     response : in out Writer)
  is abstract;

  procedure on_stdin
    (self     : in out Application;
     context  : in Request_Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer)
  is abstract;

  procedure on_stdin_end
    (self     : in out Application;
     context  : in Request_Context;
     response : in out Writer)
  is abstract;

  procedure on_data
    (self     : in out Application;
     context  : in Request_Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer)
  is null;

  procedure on_data_end
    (self     : in out Application;
     context  : in Request_Context;
     response : in out Writer)
  is null;

  type Exchange
    (max_name_bytes  : Positive;
     max_value_bytes : Positive)
  is limited private;

  procedure begin_record
    (self          : in out Exchange;
     record_header : in Fasyn.Protocol.Header;
     response      : in out Writer;
     status        : out Input_Status;
     connection_id : in Connection_Identity := NO_CONNECTION_IDENTITY;
     generation    : in Request_Generation := NO_GENERATION);

  --! If `feed_content` or `end_record` dispatches an application callback that
  --! raises an exception, the exception propagates to the caller. The caller
  --! must abandon the current `Exchange` and its `Writer`; direct exchange
  --! processing does not translate callback exceptions into cancellation.
  procedure feed_content
    (self     : in out Exchange;
     data     : in Fasyn.Protocol.Byte_Array;
     handler  : in out Application'Class;
     response : in out Writer;
     status   : out Input_Status);

  procedure end_record
    (self     : in out Exchange;
     handler  : in out Application'Class;
     response : in out Writer;
     status   : out Input_Status);

  procedure cancel
    (self     : in out Exchange;
     response : in out Writer;
     cause    : in Cancellation_Cause;
     status   : out Input_Status);

  function identity (self : Exchange) return Request_Identity;
  function cancellation_reason (self : Exchange) return Cancellation_Cause;
  function keep_connection (self : Exchange) return Boolean;
  function is_complete (self : Exchange) return Boolean;

private

  type Deferred_Command_Kind is
    (Deferred_Stdout, Deferred_Stderr, Deferred_Finish);

  type Target_Defer_Result is
    (Target_Defer_Complete,
     Target_Defer_Not_Ready,
     Target_Defer_Capacity_Exceeded);

  type Deferred_Target is limited interface;
  type Deferred_Target_Access is access all Deferred_Target'Class;

  procedure retain (self : in out Deferred_Target) is abstract;
  procedure release_reference
    (self : in out Deferred_Target; last : out Boolean) is abstract;
  procedure release_handle
    (self    : in out Deferred_Target;
     request : in Request_Identity;
     last    : out Boolean) is abstract;
  procedure request_defer
    (self    : in out Deferred_Target;
     request : in Request_Identity;
     result  : out Target_Defer_Result) is abstract;
  procedure submit_deferred
    (self               : in out Deferred_Target;
     request            : in Request_Identity;
     operation          : in Deferred_Command_Kind;
     data               : in Fasyn.Protocol.Byte_Array;
     application_status : in Interfaces.Unsigned_32;
     status             : out Deferred_Write_Status) is abstract;
  procedure cancel_deferred
    (self    : in out Deferred_Target;
     request : in Request_Identity;
     cause   : in Cancellation_Cause) is abstract;
  function target_cancellation_reason
    (self    : Deferred_Target;
     request : Request_Identity) return Cancellation_Cause is abstract;

  procedure release_target (target : in out Deferred_Target_Access);

  protected type Cancellation_State is
    procedure signal (cause : in Cancellation_Cause);
    function reason return Cancellation_Cause;
  private
    current_reason : Cancellation_Cause := Not_Cancelled;
  end Cancellation_State;

  type Request_Context is limited record
    request_value   : Request_Identity := NULL_REQUEST_IDENTITY;
    role_value      : Fasyn.Protocol.Role := Fasyn.Protocol.Responder;
    cancellation    : Cancellation_State;
    deferred_target : Deferred_Target_Access := null;
    defer_allowed   : Boolean := False;
  end record;

  type Request_Context_Access is access all Request_Context;

  procedure initialize_request_context
    (context         : in out Request_Context;
     request         : in Request_Identity;
     request_role    : in Fasyn.Protocol.Role;
     deferred_target : in Deferred_Target_Access := null;
     defer_allowed   : in Boolean := False);

  procedure signal_cancellation
    (context : in out Request_Context;
     cause   : in Cancellation_Cause);

  type Deferred_Request is
    limited new Ada.Finalization.Limited_Controlled with record
    target        : Deferred_Target_Access := null;
    request_value : Request_Identity := NULL_REQUEST_IDENTITY;
  end record;

  overriding procedure Finalize (self : in out Deferred_Request);

  type Writer
    (max_output_bytes : Positive)
  is limited record
    bytes       : Fasyn.Protocol.Byte_Array (1 .. max_output_bytes);
    length      : Natural := 0;
    limit       : Natural := max_output_bytes;
    request_id  : Fasyn.Protocol.Request_Id_Type := 0;
    initialized : Boolean := False;
    finished    : Boolean := False;
    deferred    : Boolean := False;
    failed      : Boolean := False;
  end record;

  type Exchange
    (max_name_bytes  : Positive;
     max_value_bytes : Positive)
  is limited record
    params_decoder : Fasyn.Protocol.Name_Values.Decoder
      (max_name_bytes  => max_name_bytes,
       max_value_bytes => max_value_bytes);
    begin_body : Fasyn.Protocol.Byte_Array
      (0 .. Fasyn.Protocol.Messages.BEGIN_REQUEST_BODY_LENGTH - 1) :=
        [others => 0];
    connection_id          : Connection_Identity := NO_CONNECTION_IDENTITY;
    request_id             : Fasyn.Protocol.Request_Id_Type := 0;
    generation             : Request_Generation := NO_GENERATION;
    role_value             : Fasyn.Protocol.Role := Fasyn.Protocol.Responder;
    current_record_type    : Fasyn.Protocol.Byte := 0;
    current_content_length : Natural := 0;
    content_remaining      : Natural := 0;
    active                 : Boolean := False;
    complete_flag          : Boolean := False;
    record_open            : Boolean := False;
    params_closed          : Boolean := False;
    stdin_closed           : Boolean := False;
    data_closed            : Boolean := False;
    filter_data_length_seen : Boolean := False;
    filter_data_last_mod_seen : Boolean := False;
    filter_data_length     : Interfaces.Unsigned_64 := 0;
    filter_data_received   : Interfaces.Unsigned_64 := 0;
    keep_flag              : Boolean := False;
    cancel_reason          : Cancellation_Cause := Not_Cancelled;
    failed                 : Boolean := False;
  end record;

end Fasyn.Request;
