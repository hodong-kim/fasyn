-- ============================================================================
-- fasyn-request.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Fasyn.Protocol.Codec;

package body Fasyn.Request is

  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package B renames Fasyn.Protocol.Bodies;
  package N renames Fasyn.Protocol.Name_Values;

  use type Interfaces.Unsigned_8;
  use type Interfaces.Unsigned_16;
  use type Interfaces.Unsigned_64;
  use type B.Body_Status;
  use type P.Role;

  MAX_RECORD_CONTENT : constant Natural := 16#ffff#;

  procedure release_target (target : in out Deferred_Target_Access) is
    last : Boolean;
  begin
    if target = null then
      return;
    end if;

    release_reference (target.all, last);
    if last then
      deallocate (target.all, target);
    else
      target := null;
    end if;
  end release_target;

  protected body Cancellation_State is
    procedure signal (cause : in Cancellation_Cause) is
    begin
      if cause /= Not_Cancelled and then current_reason = Not_Cancelled then
        current_reason := cause;
      end if;
    end signal;

    function reason return Cancellation_Cause is
    begin
      return current_reason;
    end reason;
  end Cancellation_State;

  function is_null (request : Identity) return Boolean is
  begin
    return request.connection_id = NO_CONNECTION_IDENTITY or else
      request.request_id = 0 or else
      request.generation = NO_GENERATION;
  end is_null;

  function current_identity (context : Fasyn.Request.Context) return Identity is
  begin
    return context.request_value;
  end current_identity;

  function cancellation_reason
    (context : Fasyn.Request.Context) return Cancellation_Cause
  is
  begin
    return context.cancellation.reason;
  end cancellation_reason;

  function cancellation_requested
    (context : Fasyn.Request.Context) return Boolean
  is
  begin
    return cancellation_reason(context) /= Not_Cancelled;
  end cancellation_requested;

  function role (context : Fasyn.Request.Context) return P.Role is
  begin
    return context.role_value;
  end role;

  function defer_response
    (context  : in Fasyn.Request.Context;
     response : in out Writer;
     handle   : in out Deferred_Handle) return Defer_Status
  is
    result : Target_Defer_Result;
  begin
    if handle.target /= null then
      return Defer_Not_Ready;
    end if;

    if not context.defer_allowed or else
       context.deferred_target = null or else
       context.cancellation.reason /= Not_Cancelled or else
       is_null(context.request_value) or else
       not response.initialized or else
       response.request_id /= context.request_value.request_id or else
       response.finished or else response.deferred or else response.failed
    then
      return Defer_Not_Allowed;
    end if;

    request_defer
      (context.deferred_target.all, context.request_value, result);

    case result is
      when Target_Defer_Complete =>
        retain (context.deferred_target.all);
        handle.target := context.deferred_target;
        handle.request_value := context.request_value;
        response.deferred := True;
        declare
          cause : constant Cancellation_Cause := context.cancellation.reason;
        begin
          if cause /= Not_Cancelled then
            cancel_deferred
              (handle.target.all, handle.request_value, cause);
          end if;
        end;
        return Defer_Complete;
      when Target_Defer_Not_Ready =>
        return Defer_Not_Ready;
      when Target_Defer_Capacity_Exceeded =>
        return Defer_Capacity_Exceeded;
    end case;
  end defer_response;

  procedure submit_deferred_stream
    (self      : in out Deferred_Handle;
     operation : in Deferred_Command_Kind;
     data      : in P.Byte_Array;
     status    : out Deferred_Write_Status)
  is
  begin
    if self.target = null or else is_null(self.request_value) then
      status := Deferred_Closed;
      return;
    end if;

    submit_deferred
      (self.target.all, self.request_value, operation, data, 0, status);
  end submit_deferred_stream;

  function write_stdout
    (self : in out Deferred_Handle;
     data : in P.Byte_Array) return Deferred_Write_Status
  is
    status : Deferred_Write_Status;
  begin
    submit_deferred_stream (self, Deferred_Stdout, data, status);
    return status;
  end write_stdout;

  function write_stderr
    (self : in out Deferred_Handle;
     data : in P.Byte_Array) return Deferred_Write_Status
  is
    status : Deferred_Write_Status;
  begin
    submit_deferred_stream (self, Deferred_Stderr, data, status);
    return status;
  end write_stderr;

  function finish
    (self               : in out Deferred_Handle;
     application_status : in Interfaces.Unsigned_32)
     return Deferred_Write_Status
  is
    empty  : P.Byte_Array (1 .. 0);
    status : Deferred_Write_Status;
  begin
    if self.target = null or else is_null(self.request_value) then
      return Deferred_Closed;
    end if;

    submit_deferred
      (self.target.all, self.request_value, Deferred_Finish, empty,
       application_status, status);
    return status;
  end finish;

  function wait_writable
    (self   : in out Deferred_Handle;
     waiter : not null Deferred_Writable_Waiter_Access)
     return Deferred_Wait_Status
  is
    status : Deferred_Wait_Status;
  begin
    if self.target = null or else is_null(self.request_value) then
      return Deferred_Wait_Closed;
    end if;

    wait_deferred_writable
      (self.target.all, self.request_value, waiter, status);
    return status;
  end wait_writable;

  function cancel_writable_wait
    (self : in out Deferred_Handle) return Deferred_Wait_Cancel_Status
  is
    status : Deferred_Wait_Cancel_Status;
  begin
    if self.target = null or else is_null(self.request_value) then
      return Deferred_Wait_Not_Registered;
    end if;

    cancel_deferred_writable_wait
      (self.target.all, self.request_value, status);
    return status;
  end cancel_writable_wait;

  function current_identity (handle : Deferred_Handle) return Identity is
  begin
    return handle.request_value;
  end current_identity;

  function cancellation_reason
    (handle : Deferred_Handle) return Cancellation_Cause
  is
  begin
    if handle.target = null or else is_null(handle.request_value) then
      return Not_Cancelled;
    end if;

    return target_cancellation_reason
      (handle.target.all, handle.request_value);
  end cancellation_reason;

  function cancellation_requested
    (handle : Deferred_Handle) return Boolean
  is
  begin
    return cancellation_reason(handle) /= Not_Cancelled;
  end cancellation_requested;

  overriding procedure Finalize (self : in out Deferred_Handle) is
    last : Boolean;
  begin
    if self.target /= null then
      release_handle (self.target.all, self.request_value, last);
      if last then
        deallocate (self.target.all, self.target);
      else
        self.target := null;
      end if;
    end if;

    self.request_value := NULL_IDENTITY;
  end Finalize;

  procedure initialize_callback_context
    (context         : in out Fasyn.Request.Context;
     request         : in Identity;
     role            : in P.Role;
     deferred_target : in Deferred_Target_Access := null;
     defer_allowed   : in Boolean := False)
  is
  begin
    context.request_value := request;
    context.role_value := role;
    context.deferred_target := deferred_target;
    context.defer_allowed := defer_allowed;
  end initialize_callback_context;

  procedure signal_cancellation
    (context : in out Fasyn.Request.Context;
     cause   : in Cancellation_Cause)
  is
  begin
    context.cancellation.signal (cause);
  end signal_cancellation;

  function current_identity (self : Exchange) return Identity is
  begin
    return
      (connection_id => self.connection_id,
       request_id    => self.request_id,
       generation    => self.generation);
  end current_identity;

  function cancellation_reason (self : Exchange) return Cancellation_Cause is
  begin
    return self.cancel_reason;
  end cancellation_reason;

  function storage_fits
    (self         : Writer;
     data_length  : Natural)
  return Boolean
  is
    chunks : constant Natural :=
      (if data_length = 0 then
         0
       else
         data_length / MAX_RECORD_CONTENT +
           (if data_length mod MAX_RECORD_CONTENT = 0 then 0 else 1));
    required : constant Long_Long_Integer :=
      Long_Long_Integer(data_length) + Long_Long_Integer(chunks) *
        P.HEADER_LENGTH;
    available : constant Long_Long_Integer :=
      Long_Long_Integer(self.limit - self.length);
  begin
    return required <= available;
  end storage_fits;

  function ring_position
    (self   : Writer;
     offset : Natural) return Positive
  is
    tail : constant Natural := self.max_output_bytes - self.first;
  begin
    if offset <= tail then
      return self.first + offset;
    end if;

    return offset - tail;
  end ring_position;

  function buffered_byte
    (self  : Writer;
     index : Positive) return P.Byte
  is
    position : Positive;
  begin
    if index > self.length then
      raise Constraint_Error with "writer byte index out of range";
    end if;

    position := ring_position (self, index - 1);
    return self.bytes(position);
  end buffered_byte;

  procedure append_buffered_byte
    (self  : in out Writer;
     value : P.Byte)
  is
    position : Positive;
  begin
    if self.length = self.max_output_bytes then
      raise Program_Error with "writer append exceeds storage capacity";
    end if;

    position := ring_position (self, self.length);
    self.bytes(position) := value;
    self.length := self.length + 1;
  end append_buffered_byte;

  procedure consume_buffered
    (self  : in out Writer;
     count : Natural)
  is
  begin
    if count > self.length then
      raise Program_Error with "writer consumption exceeds buffered output";
    elsif count = self.length then
      self.first := 1;
      self.length := 0;
      return;
    elsif count = 0 then
      return;
    end if;

    self.first := ring_position (self, count);
    self.length := self.length - count;
  end consume_buffered;

  procedure append_bytes
    (self : in out Writer;
     data : in P.Byte_Array)
  is
    position : Positive;
  begin
    for index in data'range loop
      position := ring_position (self, self.length);
      self.bytes(position) := data(index);
      self.length := self.length + 1;
    end loop;
  end append_bytes;

  procedure append_record
    (self        : in out Writer;
     record_type : in P.Byte;
     content     : in P.Byte_Array)
  is
    record_header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => self.request_id,
       content_length => P.Content_Length(content'length),
       padding_length => 0);
    header_bytes : P.Byte_Array (0 .. P.HEADER_LENGTH - 1);
  begin
    C.encode_header (record_header, header_bytes);
    append_bytes (self, header_bytes);
    append_bytes (self, content);
  end append_record;

  procedure append_empty_record
    (self        : in out Writer;
     record_type : in P.Byte)
  is
    empty : P.Byte_Array (1 .. 0);
  begin
    append_record (self, record_type, empty);
  end append_empty_record;

  procedure initialize
    (self       : in out Writer;
     request_id : in P.Request_Id)
  is
  begin
    self.first := 1;
    self.length := 0;
    self.limit := self.max_output_bytes;
    self.request_id := request_id;
    self.initialized := True;
    self.finished := False;
    self.deferred := False;
    self.failed := False;
  end initialize;

  procedure write_stream
    (self        : in out Writer;
     record_type : in P.Byte;
     data        : in P.Byte_Array;
     status      : out Write_Status)
  is
    position  : Natural := data'first;
    remaining : Natural := data'length;
    count     : Natural;
  begin
    if not self.initialized then
      status := Writer_Not_Ready;
      return;
    end if;

    if self.finished or else self.deferred then
      status := Writer_Closed;
      return;
    end if;

    if self.failed or else not storage_fits (self, data'length) then
      self.failed := True;
      status := Output_Limit_Exceeded;
      return;
    end if;

    while remaining > 0 loop
      count := Natural'Min (remaining, MAX_RECORD_CONTENT);
      append_record
        (self,
         record_type,
         data(position .. position + count - 1));
      position := position + count;
      remaining := remaining - count;
    end loop;

    status := Write_Complete;
  end write_stream;

  function write_stdout
    (self : in out Writer;
     data : in P.Byte_Array) return Write_Status
  is
    status : Write_Status;
  begin
    write_stream (self, P.STDOUT, data, status);
    return status;
  end write_stdout;

  function write_stderr
    (self : in out Writer;
     data : in P.Byte_Array) return Write_Status
  is
    status : Write_Status;
  begin
    write_stream (self, P.STDERR, data, status);
    return status;
  end write_stderr;

  procedure finish_with_protocol_status
    (self                 : in out Writer;
     application_status   : in Interfaces.Unsigned_32;
     protocol_status_code : in P.Byte;
     close_streams        : in Boolean;
     status               : out Write_Status)
  is
    end_request : constant B.End_Request_Body :=
      (application_status   => application_status,
       protocol_status_code => protocol_status_code);
    body_bytes  : P.Byte_Array (0 .. B.END_REQUEST_BODY_LENGTH - 1);
    written     : Natural;
    body_status : B.Body_Status;
    required    : constant Natural :=
      (if close_streams then 2 * P.HEADER_LENGTH else 0) +
      P.HEADER_LENGTH + B.END_REQUEST_BODY_LENGTH;
  begin
    if not self.initialized then
      status := Writer_Not_Ready;
      return;
    end if;

    if self.finished then
      status := Writer_Closed;
      return;
    end if;

    if self.failed or else required > self.limit - self.length then
      self.failed := True;
      status := Output_Limit_Exceeded;
      return;
    end if;

    body_status := B.encode_end_request
      (request_body => end_request,
       output       => body_bytes,
       written      => written);

    if body_status /= B.Body_Complete or else
       written /= B.END_REQUEST_BODY_LENGTH
    then
      self.failed := True;
      status := Output_Limit_Exceeded;
      return;
    end if;

    if close_streams then
      append_empty_record (self, P.STDOUT);
      append_empty_record (self, P.STDERR);
    end if;

    append_record (self, P.END_REQUEST, body_bytes);
    self.finished := True;
    status := Write_Complete;
  end finish_with_protocol_status;

  function finish
    (self               : in out Writer;
     application_status : in Interfaces.Unsigned_32) return Write_Status
  is
    status : Write_Status;
  begin
    if self.deferred then
      return Writer_Closed;
    end if;

    finish_with_protocol_status
      (self                 => self,
       application_status   => application_status,
       protocol_status_code => P.REQUEST_COMPLETE,
       close_streams        => True,
       status               => status);
    return status;
  end finish;

  function cancel
    (self     : in out Exchange;
     response : in out Writer;
     cause    : in Cancellation_Cause) return Input_Status
  is
    completion_status : Write_Status;
  begin
    if cause = Not_Cancelled then
      return Invalid_Record_Sequence;
    end if;

    if self.complete_flag or else not self.active then
      return Ignored_Inactive;
    end if;

    finish_with_protocol_status
      (self                 => response,
       application_status   => 0,
       protocol_status_code => P.REQUEST_COMPLETE,
       close_streams        => True,
       status               => completion_status);

    if completion_status /= Write_Complete then
      self.failed := True;
      return Output_Failed;
    end if;

    self.active := False;
    self.complete_flag := True;
    self.record_open := False;
    self.content_remaining := 0;
    self.cancel_reason := cause;
    return Request_Complete;
  end cancel;

  function parameter_name_matches
    (self     : Exchange;
     expected : String) return Boolean
  is
  begin
    if N.name_length(self.params_decoder) /= expected'length then
      return False;
    end if;

    for offset in 0 .. expected'length - 1 loop
      if N.name_byte(self.params_decoder, offset + 1) /=
           P.Byte(Character'Pos(expected(expected'first + offset)))
      then
        return False;
      end if;
    end loop;

    return True;
  end parameter_name_matches;

  function decode_parameter_unsigned
    (self  : Exchange;
     value : out Interfaces.Unsigned_64) return Boolean
  is
    digit : Interfaces.Unsigned_64;
    byte_value : P.Byte;
  begin
    value := 0;

    if N.value_length(self.params_decoder) = 0 then
      return False;
    end if;

    for index in 1 .. N.value_length(self.params_decoder) loop
      byte_value := N.value_byte (self.params_decoder, index);
      if byte_value < P.Byte(Character'Pos('0')) or else
         byte_value > P.Byte(Character'Pos('9'))
      then
        return False;
      end if;

      digit :=
        Interfaces.Unsigned_64
          (byte_value - P.Byte(Character'Pos('0')));

      if value > (Interfaces.Unsigned_64'Last - digit) / 10 then
        return False;
      end if;

      value := value * 10 + digit;
    end loop;

    return True;
  end decode_parameter_unsigned;

  function capture_filter_parameter (self : in out Exchange) return Boolean is
    parsed : Interfaces.Unsigned_64;
  begin
    if self.role_value /= P.Filter then
      return True;
    end if;

    if parameter_name_matches(self, "FCGI_DATA_LENGTH") then
      if self.filter_data_length_seen or else
         not decode_parameter_unsigned(self, parsed)
      then
        return False;
      end if;

      self.filter_data_length := parsed;
      self.filter_data_length_seen := True;

    elsif parameter_name_matches(self, "FCGI_DATA_LAST_MOD") then
      if self.filter_data_last_mod_seen or else
         not decode_parameter_unsigned(self, parsed)
      then
        return False;
      end if;

      self.filter_data_last_mod_seen := True;
    end if;

    return True;
  end capture_filter_parameter;

  procedure deliver_parameter
    (self        : in out Exchange;
     application : in out Fasyn.Request.Application'Class)
  is
    context : Fasyn.Request.Context (callback_owned => True);

    procedure deliver
      (name  : in P.Byte_Array;
       value : in P.Byte_Array)
    is
    begin
      on_parameter (application, context, name, value);
    end deliver;
  begin
    initialize_callback_context
      (context, current_identity(self), self.role_value);
    N.visit_pair (self.params_decoder, deliver'Access);
    N.reset (self.params_decoder);
  end deliver_parameter;

  function begin_record
    (self          : in out Exchange;
     record_header : in P.Header;
     response      : in out Writer;
     connection_id : in Connection_Identity := NO_CONNECTION_IDENTITY;
     generation    : in Fasyn.Request.Generation := NO_GENERATION)
     return Input_Status
  is
    status : Input_Status;
    content_length : constant Natural := Natural(record_header.content_length);
  begin
    if self.failed then
      status := Invalid_Record_Sequence;
      return status;
    end if;

    if self.complete_flag then
      status := Ignored_Inactive;
      return status;
    end if;

    if self.record_open then
      self.failed := True;
      status := Invalid_Record_Sequence;
      return status;
    end if;

    if not self.active then
      if record_header.record_type /= P.BEGIN_REQUEST then
        status := Ignored_Inactive;
        return status;
      end if;

      if record_header.request_id = 0 or else
         content_length /= B.BEGIN_REQUEST_BODY_LENGTH
      then
        self.failed := True;
        status := Invalid_Content_Length;
        return status;
      end if;

      self.active := True;
      self.connection_id := connection_id;
      self.request_id := record_header.request_id;
      self.generation := generation;
      initialize (response, self.request_id);
    elsif record_header.request_id /= self.request_id then
      status := Wrong_Request_Id;
      return status;
    elsif record_header.record_type = P.ABORT_REQUEST then
      if content_length /= 0 then
        self.failed := True;
        status := Invalid_Content_Length;
        return status;
      end if;
    elsif record_header.record_type = P.PARAMS then
      if self.params_closed or else
         self.stdin_closed or else
         self.data_closed
      then
        self.failed := True;
        status := Invalid_Record_Sequence;
        return status;
      end if;
    elsif record_header.record_type = P.STDIN then
      if self.role_value = P.Authorizer then
        self.failed := True;
        status := Invalid_Record_Type;
        return status;
      end if;

      if not self.params_closed or else
         self.stdin_closed or else
         self.data_closed
      then
        self.failed := True;
        status := Invalid_Record_Sequence;
        return status;
      end if;
    elsif record_header.record_type = P.DATA then
      if self.role_value /= P.Filter then
        self.failed := True;
        status := Invalid_Record_Type;
        return status;
      end if;

      if not self.params_closed or else
         not self.stdin_closed or else
         self.data_closed
      then
        self.failed := True;
        status := Invalid_Record_Sequence;
        return status;
      end if;
    else
      self.failed := True;
      status := Invalid_Record_Type;
      return status;
    end if;

    self.current_record_type := record_header.record_type;
    self.current_content_length := content_length;
    self.content_remaining := content_length;
    self.record_open := True;
    status := Input_Progress;
    return status;
  end begin_record;

  function feed_content
    (self        : in out Exchange;
     data        : in P.Byte_Array;
     application : in out Fasyn.Request.Application'Class;
     response    : in out Writer) return Input_Status
  is
    status : Input_Status;
    feed_status : N.Feed_Status;
    position    : Natural;
  begin
    if self.failed or else not self.record_open then
      status := Invalid_Record_Sequence;
      return status;
    end if;

    if data'length > self.content_remaining then
      self.failed := True;
      status := Invalid_Content_Length;
      return status;
    end if;

    if self.current_record_type = P.BEGIN_REQUEST then
      position := B.BEGIN_REQUEST_BODY_LENGTH - self.content_remaining;

      for index in data'range loop
        self.begin_body(position) := data(index);
        position := position + 1;
      end loop;

    elsif self.current_record_type = P.PARAMS then
      for index in data'range loop
        feed_status := N.feed (self.params_decoder, data(index));

        case feed_status is
          when N.Progress =>
            null;
          when N.Pair_Complete =>
            if not capture_filter_parameter(self) then
              self.failed := True;
              status := Malformed_Params;
              return status;
            end if;

            deliver_parameter (self, application);
          when N.Limit_Exceeded =>
            self.failed := True;
            status := Parameter_Limit_Exceeded;
            return status;
          when N.Malformed_Length =>
            self.failed := True;
            status := Malformed_Params;
            return status;
        end case;
      end loop;

    elsif self.current_record_type = P.STDIN then
      if data'length > 0 and then not response.finished then
        declare
          context     : Fasyn.Request.Context (callback_owned => True);
          saved_limit : constant Natural := response.limit;
        begin
          if self.role_value = P.Filter then
            response.limit := response.length;
          end if;

          initialize_callback_context
            (context, current_identity(self), self.role_value);
          on_stdin (application, context, data, response);
          response.limit := saved_limit;
        end;

        if response.failed then
          self.failed := True;
          status := Output_Failed;
          return status;
        end if;
      end if;

    elsif self.current_record_type = P.DATA then
      if data'length > 0 and then not response.finished then
        declare
          context : Fasyn.Request.Context (callback_owned => True);
          count   : constant Interfaces.Unsigned_64 :=
            Interfaces.Unsigned_64(data'length);
        begin
          if self.filter_data_received > self.filter_data_length or else
             count > self.filter_data_length - self.filter_data_received
          then
            self.failed := True;
            status := Invalid_Content_Length;
            return status;
          end if;

          self.filter_data_received := self.filter_data_received + count;
          initialize_callback_context
            (context, current_identity(self), self.role_value);
          on_data (application, context, data, response);
        end;

        if response.failed then
          self.failed := True;
          status := Output_Failed;
          return status;
        end if;
      end if;
    else
      self.failed := True;
      status := Invalid_Record_Type;
      return status;
    end if;

    self.content_remaining := self.content_remaining - data'length;
    status := Input_Progress;
    return status;
  end feed_content;

  function end_record
    (self        : in out Exchange;
     application : in out Fasyn.Request.Application'Class;
     response    : in out Writer) return Input_Status
  is
    status : Input_Status;
    begin_request     : B.Begin_Request_Body;
    body_status       : B.Body_Status;
    completion_status : Write_Status;
    record_type       : P.Byte;
    content_length    : Natural;
  begin
    if self.failed or else not self.record_open then
      status := Invalid_Record_Sequence;
      return status;
    end if;

    if self.content_remaining /= 0 then
      self.failed := True;
      status := Invalid_Content_Length;
      return status;
    end if;

    record_type := self.current_record_type;
    content_length := self.current_content_length;
    self.record_open := False;

    if record_type = P.BEGIN_REQUEST then
      body_status := B.decode_begin_request (self.begin_body, begin_request);

      if body_status /= B.Body_Complete then
        self.failed := True;
        status := Invalid_Content_Length;
        return status;
      end if;

      self.keep_flag := (begin_request.flags and P.KEEP_CONN) /= 0;

      if begin_request.role_code = P.RESPONDER_CODE then
        self.role_value := P.Responder;
        status := Record_Complete;
        return status;
      elsif begin_request.role_code = P.AUTHORIZER_CODE then
        self.role_value := P.Authorizer;
        status := Record_Complete;
        return status;
      elsif begin_request.role_code = P.FILTER_CODE then
        self.role_value := P.Filter;
        status := Record_Complete;
        return status;
      end if;

      finish_with_protocol_status
        (self                 => response,
         application_status   => 0,
         protocol_status_code => P.UNKNOWN_ROLE,
         close_streams        => False,
         status               => completion_status);

      if completion_status /= Write_Complete then
        self.failed := True;
        status := Output_Failed;
        return status;
      end if;

      self.active := False;
      self.complete_flag := True;
      status := Request_Complete;
      return status;
    end if;

    if record_type = P.ABORT_REQUEST then
      return cancel
        (self     => self,
         response => response,
         cause    => Peer_Abort);
    end if;

    if record_type = P.PARAMS then
      if content_length = 0 then
        if not N.at_pair_boundary (self.params_decoder) then
          self.failed := True;
          status := Malformed_Params;
          return status;
        end if;

        if self.role_value = P.Filter and then
           (not self.filter_data_length_seen or else
            not self.filter_data_last_mod_seen)
        then
          self.failed := True;
          status := Malformed_Params;
          return status;
        end if;

        self.params_closed := True;
        declare
          context     : Fasyn.Request.Context (callback_owned => True);
          saved_limit : constant Natural := response.limit;
        begin
          if self.role_value = P.Filter then
            response.limit := response.length;
          end if;

          initialize_callback_context
            (context, current_identity(self), self.role_value);
          on_params_end (application, context, response);
          response.limit := saved_limit;
        end;
      end if;

    elsif record_type = P.STDIN then
      if content_length = 0 then
        self.stdin_closed := True;
        declare
          context : Fasyn.Request.Context (callback_owned => True);
        begin
          initialize_callback_context
            (context, current_identity(self), self.role_value);
          on_stdin_end (application, context, response);
        end;
      end if;

    elsif record_type = P.DATA then
      if content_length = 0 then
        self.data_closed := True;
        declare
          context : Fasyn.Request.Context (callback_owned => True);
        begin
          initialize_callback_context
            (context, current_identity(self), self.role_value);
          on_data_end (application, context, response);
        end;
      end if;
    else
      self.failed := True;
      status := Invalid_Record_Type;
      return status;
    end if;

    if response.failed then
      self.failed := True;
      status := Output_Failed;
      return status;
    end if;

    if response.finished then
      self.active := False;
      self.complete_flag := True;
      status := Request_Complete;
    else
      status := Record_Complete;
    end if;
    return status;
  end end_record;

  function keep_connection (self : Exchange) return Boolean is
  begin
    return self.keep_flag;
  end keep_connection;

  function is_complete (self : Exchange) return Boolean is
  begin
    return self.complete_flag;
  end is_complete;

end Fasyn.Request;
