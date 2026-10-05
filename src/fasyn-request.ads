-- ============================================================================
-- fasyn-request.ads
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
private with Ada.Finalization;
with Interfaces;
with Fasyn.Protocol;
private with Fasyn.Protocol.Bodies;
private with Fasyn.Protocol.Name_Values;

package Fasyn.Request is

  --! Runtime-assigned connection identity. Execution guarantees nonzero,
  --! non-reused values within one executor Context lifetime domain; values from
  --! independent executor Contexts are not a process-global identity namespace.
  type Connection_Identity is new Interfaces.Unsigned_64;
  NO_CONNECTION_IDENTITY : constant Connection_Identity := 0;

  --! Nonzero request-generation identity within one connection lifetime.
  --! Generations are never reused; exhaustion is terminal for new request
  --! admission on that connection rather than wrapping to an earlier value.
  type Generation is new Interfaces.Unsigned_64;
  NO_GENERATION : constant Generation := 0;

  type Identity is record
    connection_id : Connection_Identity := NO_CONNECTION_IDENTITY;
    request_id    : Fasyn.Protocol.Request_Id := 0;
    generation    : Fasyn.Request.Generation := NO_GENERATION;
  end record;

  NULL_IDENTITY : constant Identity :=
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

  --! Borrowed application-callback view created by Exchange or Execution.
  --! Applications receive it by parameter and cannot construct a standalone view.
  type Context (<>) is limited private;

  function is_null (request : Identity) return Boolean;
  function current_identity (context : Fasyn.Request.Context) return Identity;
  function cancellation_reason
    (context : Fasyn.Request.Context) return Cancellation_Cause;
  function cancellation_requested
    (context : Fasyn.Request.Context) return Boolean;
  function role (context : Fasyn.Request.Context) return Fasyn.Protocol.Role;

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

  --! Bounded FastCGI response writer. Exchange/runtime processing initializes
  --! it; asynchronous application callbacks receive it as callback-scoped.
  type Writer
    (max_output_bytes : Positive)
  is limited private;

  --! Writes require an initialized, open Writer. They report
  --! `Writer_Not_Ready`, `Writer_Closed`, or `Output_Limit_Exceeded` for those
  --! states. Exceeding the limit leaves it failed; successful `finish` emits
  --! terminal records and closes it.
  function write_stdout
    (self : in out Writer;
     data : in Fasyn.Protocol.Byte_Array) return Write_Status;

  --! Uses the same Writer state and output-limit contract as `write_stdout`.
  function write_stderr
    (self : in out Writer;
     data : in Fasyn.Protocol.Byte_Array) return Write_Status;

  --! On success emits terminal stream records and `END_REQUEST`, then closes
  --! the Writer. It uses the same failure-state contract as `write_stdout`.
  function finish
    (self               : in out Writer;
     application_status : in Interfaces.Unsigned_32) return Write_Status;

  --! A deferred request is an opaque capability for exactly one FastCGI
  --! connection/request generation. It never exposes transport ownership.
  --! Finalizing or dropping the handle releases only the capability; it does
  --! not finish or cancel the request, whose normal runtime lifetime remains
  --! authoritative. A queued writable waiter that owner-thread dispatch has
  --! not yet taken is removed with the handle. A waiter already dispatching
  --! must remain alive until that callback returns.
  type Deferred_Handle is limited private;

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

  type Deferred_Writable_Waiter is limited interface;
  type Deferred_Writable_Waiter_Access is
    access all Deferred_Writable_Waiter'Class;

  --! Runs on the executor's owning Event Loop. An exception escaping this
  --! callback is converted to the asynchronous runtime's callback-failure
  --! status; the one-shot registration is consumed before callback entry.
  procedure on_deferred_writable
    (self    : in out Deferred_Writable_Waiter;
     request : in Identity) is abstract;

  type Deferred_Wait_Status is
    (Deferred_Wait_Ready,
     Deferred_Wait_Registered,
     Deferred_Wait_Closed,
     Deferred_Wait_Conflict,
     Deferred_Wait_Not_Blocked);

  type Deferred_Wait_Cancel_Status is
    (Deferred_Wait_Cancelled,
     Deferred_Wait_Not_Registered,
     Deferred_Wait_Dispatching);

  --! Transfer terminal response ownership from the callback-scoped Writer to
  --! `handle`. Deferral is accepted only at the terminal input callback for
  --! the active role. On success, further application writes through `response`
  --! are rejected and the executor worker may return immediately.
  function defer_response
    (context  : in Fasyn.Request.Context;
     response : in out Writer;
     handle   : in out Deferred_Handle) return Defer_Status;

  --! Deferred writes are bounded. Deferred_Would_Block is transient; an
  --! event-driven producer should register `wait_writable` rather than poll.
  --! Deferred_Output_Limit_Exceeded means the encoded operation cannot fit the
  --! configured request/connection limit even when otherwise empty.
  --! Deferred_Resource_Failed means the operation was not queued because its
  --! bounded staging allocation failed; the live handle may be retried.
  --! Deferred_Closed means the exact request generation is no longer writable.
  function write_stdout
    (self : in out Deferred_Handle;
     data : in Fasyn.Protocol.Byte_Array) return Deferred_Write_Status;

  --! Uses the same bounded deferred-write contract as deferred `write_stdout`.
  function write_stderr
    (self : in out Deferred_Handle;
     data : in Fasyn.Protocol.Byte_Array) return Deferred_Write_Status;

  --! Queues terminal deferred output under the same bounded-write contract.
  function finish
    (self               : in out Deferred_Handle;
     application_status : in Interfaces.Unsigned_32)
     return Deferred_Write_Status;

  --! One-shot readiness registration for a deferred producer that observed
  --! `Deferred_Would_Block`. The most recent blocked write supplies one wait
  --! token; a later write attempt or wait consumes/supersedes it.
  --! `Deferred_Wait_Not_Blocked` means no blocked-attempt token is pending. If
  --! writable progress occurred after the blocked attempt,
  --! `Deferred_Wait_Ready` means
  --! retry immediately and no callback is retained.
  --! `Deferred_Wait_Registered` retains `waiter` until one later
  --! output/cancellation state change schedules exactly one callback on the
  --! executor's owning Event Loop. Re-registering
  --! the same waiter is idempotent; a different queued waiter reports
  --! `Deferred_Wait_Conflict`. `Deferred_Wait_Closed` means the exact request
  --! generation is no longer writable. A readiness callback is only a retry
  --! hint, not a byte reservation: the retry may still block and then register
  --! again. The waiter must outlive that callback or a successful cancellation.
  function wait_writable
    (self   : in out Deferred_Handle;
     waiter : not null Deferred_Writable_Waiter_Access)
     return Deferred_Wait_Status;

  --! Cancels a queued one-shot readiness waiter.
  --! `Deferred_Wait_Dispatching` means owner-thread dispatch has already taken
  --! the callback; the waiter must remain alive until that callback returns.
  function cancel_writable_wait
    (self : in out Deferred_Handle) return Deferred_Wait_Cancel_Status;

  function current_identity (handle : Deferred_Handle) return Identity;
  function cancellation_reason
    (handle : Deferred_Handle) return Cancellation_Cause;
  function cancellation_requested
    (handle : Deferred_Handle) return Boolean;

  --! Callback arguments are callback-scoped; application code must not retain
  --! access to `context`, input arrays, or `response` after returning. One
  --! connection serializes its own application callbacks, but distinct
  --! connections may invoke the same Application instance concurrently on
  --! executor workers. A shared instance must therefore synchronize any mutable
  --! state that crosses connections; otherwise use a separate instance per
  --! connection. Fasyn does not globally serialize Application callbacks.
  type Application is limited interface;
  type Application_Access is access all Application'Class;

  procedure on_parameter
    (self    : in out Application;
     context : in Fasyn.Request.Context;
     name    : in Fasyn.Protocol.Byte_Array;
     value   : in Fasyn.Protocol.Byte_Array)
  is abstract;

  procedure on_params_end
    (self     : in out Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer)
  is abstract;

  --! `data` is an ordered stream chunk, not a FastCGI record boundary. The
  --! runtime may coalesce adjacent input records/socket fragments within its
  --! bounded scheduling policy.
  procedure on_stdin
    (self     : in out Application;
     context  : in Fasyn.Request.Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer)
  is abstract;

  procedure on_stdin_end
    (self     : in out Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer)
  is abstract;

  --! `data` has the same implementation-defined bounded chunking contract as
  --! `on_stdin`; record and socket fragmentation is not exposed as semantics.
  procedure on_data
    (self     : in out Application;
     context  : in Fasyn.Request.Context;
     data     : in Fasyn.Protocol.Byte_Array;
     response : in out Writer)
  is null;

  procedure on_data_end
    (self     : in out Application;
     context  : in Fasyn.Request.Context;
     response : in out Writer)
  is null;

  --! Strict record state machine: `begin_record`, zero or more
  --! `feed_content` calls totaling the declared content length, then
  --! `end_record`. Fatal sequencing, content, parameter, or output errors leave
  --! the Exchange failed and it must be abandoned.
  type Exchange
    (max_name_bytes  : Natural;
     max_value_bytes : Natural)
  is limited private;

  --! Opens one record and enforces request ID, role, and stream sequencing.
  function begin_record
    (self          : in out Exchange;
     record_header : in Fasyn.Protocol.Header;
     response      : in out Writer;
     connection_id : in Connection_Identity := NO_CONNECTION_IDENTITY;
     generation    : in Fasyn.Request.Generation := NO_GENERATION)
     return Input_Status;

  --! If `feed_content` or `end_record` dispatches an application callback that
  --! raises an exception, the exception propagates to the caller. The caller
  --! must abandon the current `Exchange` and its `Writer`; direct exchange
  --! processing does not translate callback exceptions into cancellation.
  function feed_content
    (self        : in out Exchange;
     data        : in Fasyn.Protocol.Byte_Array;
     application : in out Fasyn.Request.Application'Class;
     response    : in out Writer) return Input_Status;

  --! Requires exactly the declared content to have been consumed, then
  --! closes the current record and dispatches any end-of-stream callback.
  function end_record
    (self        : in out Exchange;
     application : in out Fasyn.Request.Application'Class;
     response    : in out Writer) return Input_Status;

  --! Cancels an active request with a non-`Not_Cancelled` cause and emits its
  --! terminal response; inactive requests are reported as `Ignored_Inactive`.
  function cancel
    (self     : in out Exchange;
     response : in out Writer;
     cause    : in Cancellation_Cause) return Input_Status;

  function current_identity (self : Exchange) return Identity;
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
     request : in Identity;
     last    : out Boolean) is abstract;
  procedure deallocate
    (self   : in out Deferred_Target;
     target : in out Deferred_Target_Access) is abstract;
  procedure request_defer
    (self    : in out Deferred_Target;
     request : in Identity;
     result  : out Target_Defer_Result) is abstract;
  procedure submit_deferred
    (self               : in out Deferred_Target;
     request            : in Identity;
     operation          : in Deferred_Command_Kind;
     data               : in Fasyn.Protocol.Byte_Array;
     application_status : in Interfaces.Unsigned_32;
     status             : out Deferred_Write_Status) is abstract;
  procedure cancel_deferred
    (self    : in out Deferred_Target;
     request : in Identity;
     cause   : in Cancellation_Cause) is abstract;
  procedure wait_deferred_writable
    (self    : in out Deferred_Target;
     request : in Identity;
     waiter  : not null Deferred_Writable_Waiter_Access;
     status  : out Deferred_Wait_Status) is abstract;
  procedure cancel_deferred_writable_wait
    (self    : in out Deferred_Target;
     request : in Identity;
     status  : out Deferred_Wait_Cancel_Status) is abstract;
  function target_cancellation_reason
    (self    : Deferred_Target;
     request : Identity) return Cancellation_Cause is abstract;

  procedure release_target (target : in out Deferred_Target_Access);

  protected type Cancellation_State is
    procedure signal (cause : in Cancellation_Cause);
    function reason return Cancellation_Cause;
  private
    --  Exchange creates callback Contexts per dispatch.  Keep cancellation
    --  synchronization atomic-only so Context construction needs no OS lock.
    pragma Lock_Free;
    current_reason : Cancellation_Cause := Not_Cancelled;
  end Cancellation_State;

  type Context (callback_owned : Boolean) is limited record
    request_value   : Identity := NULL_IDENTITY;
    role_value      : Fasyn.Protocol.Role := Fasyn.Protocol.Responder;
    cancellation    : Cancellation_State;
    deferred_target : Deferred_Target_Access := null;
    defer_allowed   : Boolean := False;
  end record;

  type Callback_Context_Access is access all Context;

  procedure initialize_callback_context
    (context         : in out Fasyn.Request.Context;
     request         : in Identity;
     role            : in Fasyn.Protocol.Role;
     deferred_target : in Deferred_Target_Access := null;
     defer_allowed   : in Boolean := False);

  procedure signal_cancellation
    (context : in out Fasyn.Request.Context;
     cause   : in Cancellation_Cause);

  type Deferred_Handle is
    limited new Ada.Finalization.Limited_Controlled with record
    target        : Deferred_Target_Access := null;
    request_value : Identity := NULL_IDENTITY;
  end record;

  overriding procedure Finalize (self : in out Deferred_Handle);

  type Writer
    (max_output_bytes : Positive)
  is limited record
    bytes       : Fasyn.Protocol.Byte_Array (1 .. max_output_bytes);
    first       : Positive := 1;
    length      : Natural := 0;
    limit       : Natural := max_output_bytes;
    request_id  : Fasyn.Protocol.Request_Id := 0;
    initialized : Boolean := False;
    finished    : Boolean := False;
    deferred    : Boolean := False;
    failed      : Boolean := False;
  end record;

  function buffered_byte
    (self  : Writer;
     index : Positive) return Fasyn.Protocol.Byte;

  procedure append_buffered_byte
    (self  : in out Writer;
     value : Fasyn.Protocol.Byte);

  procedure consume_buffered
    (self  : in out Writer;
     count : Natural);

  type Exchange
    (max_name_bytes  : Natural;
     max_value_bytes : Natural)
  is limited record
    params_decoder : Fasyn.Protocol.Name_Values.Decoder
      (max_name_bytes  => max_name_bytes,
       max_value_bytes => max_value_bytes);
    begin_body : Fasyn.Protocol.Byte_Array
      (0 .. Fasyn.Protocol.Bodies.BEGIN_REQUEST_BODY_LENGTH - 1) :=
        [others => 0];
    connection_id          : Connection_Identity := NO_CONNECTION_IDENTITY;
    request_id             : Fasyn.Protocol.Request_Id := 0;
    generation             : Fasyn.Request.Generation := NO_GENERATION;
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
