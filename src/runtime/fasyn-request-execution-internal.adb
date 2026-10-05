-- ============================================================================
-- fasyn-request-execution-internal.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================

package body Fasyn.Request.Execution.Internal is

  function deferred_output_chunk_bytes return Positive is
  begin
    return Fasyn.Request.Execution.DEFERRED_OUTPUT_CHUNK_BYTES;
  end deferred_output_chunk_bytes;

  function max_parameter_pairs_per_batch return Positive is
  begin
    return Fasyn.Request.Execution.MAX_PARAMETER_PAIRS_PER_BATCH;
  end max_parameter_pairs_per_batch;

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
     return Clair.Status.Code
  is
  begin
    return Fasyn.Request.Execution.submit_parameter_batch
      (self, request, application, completion_handler, encoded, finish_params,
       output_limit, accepted, role);
  end submit_parameter_batch;

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
     return Clair.Status.Code
  is
  begin
    return Fasyn.Request.Execution.submit_stdin_batch
      (self, request, application, completion_handler, data, finish_stream,
       output_limit, accepted, role);
  end submit_stdin_batch;

  function submit_data_batch
    (self               : in out Context;
     request            : Identity;
     application        : not null Application_Access;
     completion_handler : not null Completion_Handler_Access;
     data               : Fasyn.Protocol.Byte_Array;
     finish_stream      : Boolean;
     output_limit       : Natural;
     accepted           : out Boolean) return Clair.Status.Code
  is
  begin
    return Fasyn.Request.Execution.submit_data_batch
      (self, request, application, completion_handler, data, finish_stream,
       output_limit, accepted);
  end submit_data_batch;

  function uses_event_loop
    (self       : Context;
     event_loop : not null Clair.Event_Loop.Context_Access) return Boolean
  is
  begin
    return Fasyn.Request.Execution.uses_event_loop (self, event_loop);
  end uses_event_loop;

  function issue_connection_identity
    (self     : in out Context;
     identity : out Connection_Identity) return Clair.Status.Code
  is
  begin
    return Fasyn.Request.Execution.issue_connection_identity (self, identity);
  end issue_connection_identity;

  function supports_work_limits
    (self                  : Context;
     required_input_bytes  : Positive;
     required_output_bytes : Positive) return Boolean
  is
  begin
    return Fasyn.Request.Execution.supports_work_limits
      (self, required_input_bytes, required_output_bytes);
  end supports_work_limits;

  function supports_batch_input_bytes
    (self           : Context;
     required_bytes : Positive) return Boolean
  is
  begin
    return Fasyn.Request.Execution.supports_batch_input_bytes
      (self, required_bytes);
  end supports_batch_input_bytes;

  function deferred_requested
    (self    : Context;
     request : Identity) return Boolean
  is
  begin
    return Fasyn.Request.Execution.deferred_requested (self, request);
  end deferred_requested;

  function activate_deferred
    (self               : in out Context;
     request            : Identity;
     request_pending    : Natural;
     request_limit      : Positive;
     connection_pending : Natural;
     connection_limit   : Positive) return Clair.Status.Code
  is
  begin
    return Fasyn.Request.Execution.activate_deferred
      (self, request, request_pending, request_limit, connection_pending,
       connection_limit);
  end activate_deferred;

  procedure retire_deferred
    (self    : in out Context;
     request : Identity;
     cause   : Cancellation_Cause := Not_Cancelled)
  is
  begin
    Fasyn.Request.Execution.retire_deferred (self, request, cause);
  end retire_deferred;

  procedure set_deferred_connection_busy
    (self          : in out Context;
     connection_id : Connection_Identity;
     busy          : Boolean)
  is
  begin
    Fasyn.Request.Execution.set_deferred_connection_busy
      (self, connection_id, busy);
  end set_deferred_connection_busy;

  procedure sync_deferred_connection
    (self          : in out Context;
     connection_id : Connection_Identity;
     pending       : Natural)
  is
  begin
    Fasyn.Request.Execution.sync_deferred_connection
      (self, connection_id, pending);
  end sync_deferred_connection;

  procedure sync_deferred_request
    (self    : in out Context;
     request : Identity;
     pending : Natural)
  is
  begin
    Fasyn.Request.Execution.sync_deferred_request (self, request, pending);
  end sync_deferred_request;

  function deferred_pending_bytes
    (self    : Context;
     request : Identity) return Natural
  is
  begin
    return Fasyn.Request.Execution.deferred_pending_bytes (self, request);
  end deferred_pending_bytes;

  function deferred_connection_pending_bytes
    (self          : Context;
     connection_id : Connection_Identity) return Natural
  is
  begin
    return Fasyn.Request.Execution.deferred_connection_pending_bytes
      (self, connection_id);
  end deferred_connection_pending_bytes;

end Fasyn.Request.Execution.Internal;
