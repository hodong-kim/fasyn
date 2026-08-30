-- ============================================================================
-- fasyn-request.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Unchecked_Deallocation;
with Fasyn.Protocol.Codec;

package body Fasyn.Request is

  package P renames Fasyn.Protocol;
  package C renames Fasyn.Protocol.Codec;
  package M renames Fasyn.Protocol.Messages;
  package N renames Fasyn.Protocol.Name_Values;

  use type Interfaces.Unsigned_8;
  use type Interfaces.Unsigned_16;
  use type Interfaces.Unsigned_64;
  use type M.Body_Status;
  use type P.Role;

  MAX_RECORD_CONTENT : constant Natural := 16#ffff#;

  procedure Free_Deferred_Target is new Ada.Unchecked_Deallocation
    (Object => Deferred_Target'Class,
     Name   => Deferred_Target_Access);

  procedure release_target (target : in out Deferred_Target_Access) is
    last : Boolean;
  begin
    if target = null then
      return;
    end if;

    release_reference (target.all, last);
    if last then
      Free_Deferred_Target (target);
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

  function is_null (request : Request_Identity) return Boolean is
  begin
    return request.connection_id = NO_CONNECTION_IDENTITY or else
      request.request_id = 0 or else
      request.generation = NO_GENERATION;
  end is_null;

  function identity (context : Request_Context) return Request_Identity is
  begin
    return context.request_value;
  end identity;

  function cancellation_reason
    (context : Request_Context) return Cancellation_Cause
  is
  begin
    return context.cancellation.reason;
  end cancellation_reason;

  function cancellation_requested (context : Request_Context) return Boolean is
  begin
    return cancellation_reason(context) /= Not_Cancelled;
  end cancellation_requested;

  function request_role (context : Request_Context) return P.Role is
  begin
    return context.role_value;
  end request_role;

  procedure defer_response
    (context  : in Request_Context;
     response : in out Writer;
     request  : in out Deferred_Request;
     status   : out Defer_Status)
  is
    result : Target_Defer_Result;
  begin
    if request.target /= null then
      status := Defer_Not_Ready;
      return;
    end if;

    if not context.defer_allowed or else
       context.deferred_target = null or else
       context.cancellation.reason /= Not_Cancelled or else
       is_null(context.request_value) or else
       not response.initialized or else
       response.request_id /= context.request_value.request_id or else
       response.finished or else response.deferred or else response.failed
    then
      status := Defer_Not_Allowed;
      return;
    end if;

    request_defer
      (context.deferred_target.all, context.request_value, result);

    case result is
      when Target_Defer_Complete =>
        retain (context.deferred_target.all);
        request.target := context.deferred_target;
        request.request_value := context.request_value;
        response.deferred := True;
        declare
          cause : constant Cancellation_Cause := context.cancellation.reason;
        begin
          if cause /= Not_Cancelled then
            cancel_deferred
              (request.target.all, request.request_value, cause);
          end if;
        end;
        status := Defer_Complete;
      when Target_Defer_Not_Ready =>
        status := Defer_Not_Ready;
      when Target_Defer_Capacity_Exceeded =>
        status := Defer_Capacity_Exceeded;
    end case;
  end defer_response;

  procedure submit_deferred_stream
    (self      : in out Deferred_Request;
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

  procedure write_stdout
    (self   : in out Deferred_Request;
     data   : in P.Byte_Array;
     status : out Deferred_Write_Status)
  is
  begin
    submit_deferred_stream (self, Deferred_Stdout, data, status);
  end write_stdout;

  procedure write_stderr
    (self   : in out Deferred_Request;
     data   : in P.Byte_Array;
     status : out Deferred_Write_Status)
  is
  begin
    submit_deferred_stream (self, Deferred_Stderr, data, status);
  end write_stderr;

  procedure finish
    (self               : in out Deferred_Request;
     application_status : in Interfaces.Unsigned_32;
     status             : out Deferred_Write_Status)
  is
    empty : P.Byte_Array (1 .. 0);
  begin
    if self.target = null or else is_null(self.request_value) then
      status := Deferred_Closed;
      return;
    end if;

    submit_deferred
      (self.target.all, self.request_value, Deferred_Finish, empty,
       application_status, status);
  end finish;

  function identity (request : Deferred_Request) return Request_Identity is
  begin
    return request.request_value;
  end identity;

  function cancellation_reason
    (request : Deferred_Request) return Cancellation_Cause
  is
  begin
    if request.target = null or else is_null(request.request_value) then
      return Not_Cancelled;
    end if;

    return target_cancellation_reason
      (request.target.all, request.request_value);
  end cancellation_reason;

  function cancellation_requested
    (request : Deferred_Request) return Boolean
  is
  begin
    return cancellation_reason(request) /= Not_Cancelled;
  end cancellation_requested;

  overriding procedure Finalize (self : in out Deferred_Request) is
    last : Boolean;
  begin
    if self.target /= null then
      release_handle (self.target.all, self.request_value, last);
      if last then
        Free_Deferred_Target (self.target);
      else
        self.target := null;
      end if;
    end if;

    self.request_value := NULL_REQUEST_IDENTITY;
  end Finalize;

  procedure initialize_request_context
    (context         : in out Request_Context;
     request         : in Request_Identity;
     request_role    : in P.Role;
     deferred_target : in Deferred_Target_Access := null;
     defer_allowed   : in Boolean := False)
  is
  begin
    context.request_value := request;
    context.role_value := request_role;
    context.deferred_target := deferred_target;
    context.defer_allowed := defer_allowed;
  end initialize_request_context;

  procedure signal_cancellation
    (context : in out Request_Context;
     cause   : in Cancellation_Cause)
  is
  begin
    context.cancellation.signal (cause);
  end signal_cancellation;

  function identity (self : Exchange) return Request_Identity is
  begin
    return
      (connection_id => self.connection_id,
       request_id    => self.request_id,
       generation    => self.generation);
  end identity;

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

  procedure append_bytes
    (self : in out Writer;
     data : in P.Byte_Array)
  is
  begin
    for index in data'range loop
      self.length := self.length + 1;
      self.bytes(self.length) := data(index);
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
       content_length => P.Content_Length_Type(content'length),
       padding_length => 0,
       reserved       => 0);
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
     request_id : in P.Request_Id_Type)
  is
  begin
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

  procedure write_stdout
    (self   : in out Writer;
     data   : in P.Byte_Array;
     status : out Write_Status)
  is
  begin
    write_stream (self, P.STDOUT_TYPE, data, status);
  end write_stdout;

  procedure write_stderr
    (self   : in out Writer;
     data   : in P.Byte_Array;
     status : out Write_Status)
  is
  begin
    write_stream (self, P.STDERR_TYPE, data, status);
  end write_stderr;

  procedure finish_with_protocol_status
    (self                 : in out Writer;
     application_status   : in Interfaces.Unsigned_32;
     protocol_status_code : in P.Byte;
     close_streams        : in Boolean;
     status               : out Write_Status)
  is
    end_request : constant M.End_Request_Body :=
      (application_status   => application_status,
       protocol_status_code => protocol_status_code);
    body_bytes  : P.Byte_Array (0 .. M.END_REQUEST_BODY_LENGTH - 1);
    written     : Natural;
    body_status : M.Body_Status;
    required    : constant Natural :=
      (if close_streams then 2 * P.HEADER_LENGTH else 0) +
      P.HEADER_LENGTH + M.END_REQUEST_BODY_LENGTH;
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

    M.encode_end_request
      (request_body => end_request,
       output       => body_bytes,
       written      => written,
       status       => body_status);

    if body_status /= M.Body_Complete or else
       written /= M.END_REQUEST_BODY_LENGTH
    then
      self.failed := True;
      status := Output_Limit_Exceeded;
      return;
    end if;

    if close_streams then
      append_empty_record (self, P.STDOUT_TYPE);
      append_empty_record (self, P.STDERR_TYPE);
    end if;

    append_record (self, P.END_REQUEST_TYPE, body_bytes);
    self.finished := True;
    status := Write_Complete;
  end finish_with_protocol_status;

  procedure finish
    (self               : in out Writer;
     application_status : in Interfaces.Unsigned_32;
     status             : out Write_Status)
  is
  begin
    if self.deferred then
      status := Writer_Closed;
      return;
    end if;

    finish_with_protocol_status
      (self                 => self,
       application_status   => application_status,
       protocol_status_code => P.REQUEST_COMPLETE_STATUS,
       close_streams        => True,
       status               => status);
  end finish;

  procedure cancel
    (self     : in out Exchange;
     response : in out Writer;
     cause    : in Cancellation_Cause;
     status   : out Input_Status)
  is
    completion_status : Write_Status;
  begin
    if cause = Not_Cancelled then
      status := Invalid_Record_Sequence;
      return;
    end if;

    if self.complete_flag or else not self.active then
      status := Ignored_Inactive;
      return;
    end if;

    finish_with_protocol_status
      (self                 => response,
       application_status   => 0,
       protocol_status_code => P.REQUEST_COMPLETE_STATUS,
       close_streams        => True,
       status               => completion_status);

    if completion_status /= Write_Complete then
      self.failed := True;
      status := Output_Failed;
      return;
    end if;

    self.active := False;
    self.complete_flag := True;
    self.record_open := False;
    self.content_remaining := 0;
    self.cancel_reason := cause;
    status := Request_Complete;
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
    (self    : in out Exchange;
     handler : in out Application'Class)
  is
    context : Request_Context;
    name : P.Byte_Array (1 .. N.name_length(self.params_decoder));
    value : P.Byte_Array (1 .. N.value_length(self.params_decoder));
  begin
    initialize_request_context
      (context, identity(self), self.role_value);

    for index in name'range loop
      name(index) := N.name_byte (self.params_decoder, index);
    end loop;

    for index in value'range loop
      value(index) := N.value_byte (self.params_decoder, index);
    end loop;

    on_parameter (handler, context, name, value);
    N.reset (self.params_decoder);
  end deliver_parameter;

  procedure begin_record
    (self          : in out Exchange;
     record_header : in P.Header;
     response      : in out Writer;
     status        : out Input_Status;
     connection_id : in Connection_Identity := NO_CONNECTION_IDENTITY;
     generation    : in Request_Generation := NO_GENERATION)
  is
    content_length : constant Natural := Natural(record_header.content_length);
  begin
    if self.failed then
      status := Invalid_Record_Sequence;
      return;
    end if;

    if self.complete_flag then
      status := Ignored_Inactive;
      return;
    end if;

    if self.record_open then
      self.failed := True;
      status := Invalid_Record_Sequence;
      return;
    end if;

    if not self.active then
      if record_header.record_type /= P.BEGIN_REQUEST_TYPE then
        status := Ignored_Inactive;
        return;
      end if;

      if record_header.request_id = 0 or else
         content_length /= M.BEGIN_REQUEST_BODY_LENGTH
      then
        self.failed := True;
        status := Invalid_Content_Length;
        return;
      end if;

      self.active := True;
      self.connection_id := connection_id;
      self.request_id := record_header.request_id;
      self.generation := generation;
      initialize (response, self.request_id);
    elsif record_header.request_id /= self.request_id then
      status := Wrong_Request_Id;
      return;
    elsif record_header.record_type = P.ABORT_REQUEST_TYPE then
      if content_length /= 0 then
        self.failed := True;
        status := Invalid_Content_Length;
        return;
      end if;
    elsif record_header.record_type = P.PARAMS_TYPE then
      if self.params_closed or else
         self.stdin_closed or else
         self.data_closed
      then
        self.failed := True;
        status := Invalid_Record_Sequence;
        return;
      end if;
    elsif record_header.record_type = P.STDIN_TYPE then
      if self.role_value = P.Authorizer then
        self.failed := True;
        status := Invalid_Record_Type;
        return;
      end if;

      if not self.params_closed or else
         self.stdin_closed or else
         self.data_closed
      then
        self.failed := True;
        status := Invalid_Record_Sequence;
        return;
      end if;
    elsif record_header.record_type = P.DATA_TYPE then
      if self.role_value /= P.Filter then
        self.failed := True;
        status := Invalid_Record_Type;
        return;
      end if;

      if not self.params_closed or else
         not self.stdin_closed or else
         self.data_closed
      then
        self.failed := True;
        status := Invalid_Record_Sequence;
        return;
      end if;
    else
      self.failed := True;
      status := Invalid_Record_Type;
      return;
    end if;

    self.current_record_type := record_header.record_type;
    self.current_content_length := content_length;
    self.content_remaining := content_length;
    self.record_open := True;
    status := Input_Progress;
  end begin_record;

  procedure feed_content
    (self     : in out Exchange;
     data     : in P.Byte_Array;
     handler  : in out Application'Class;
     response : in out Writer;
     status   : out Input_Status)
  is
    feed_status : N.Feed_Status;
    position    : Natural;
  begin
    if self.failed or else not self.record_open then
      status := Invalid_Record_Sequence;
      return;
    end if;

    if data'length > self.content_remaining then
      self.failed := True;
      status := Invalid_Content_Length;
      return;
    end if;

    if self.current_record_type = P.BEGIN_REQUEST_TYPE then
      position := M.BEGIN_REQUEST_BODY_LENGTH - self.content_remaining;

      for index in data'range loop
        self.begin_body(position) := data(index);
        position := position + 1;
      end loop;

    elsif self.current_record_type = P.PARAMS_TYPE then
      for index in data'range loop
        N.feed (self.params_decoder, data(index), feed_status);

        case feed_status is
          when N.Progress =>
            null;
          when N.Pair_Complete =>
            if not capture_filter_parameter(self) then
              self.failed := True;
              status := Malformed_Params;
              return;
            end if;

            deliver_parameter (self, handler);
          when N.Limit_Exceeded =>
            self.failed := True;
            status := Parameter_Limit_Exceeded;
            return;
          when N.Invalid_State =>
            self.failed := True;
            status := Malformed_Params;
            return;
        end case;
      end loop;

    elsif self.current_record_type = P.STDIN_TYPE then
      if data'length > 0 and then not response.finished then
        declare
          context     : Request_Context;
          saved_limit : constant Natural := response.limit;
        begin
          if self.role_value = P.Filter then
            response.limit := response.length;
          end if;

          initialize_request_context
            (context, identity(self), self.role_value);
          on_stdin (handler, context, data, response);
          response.limit := saved_limit;
        end;

        if response.failed then
          self.failed := True;
          status := Output_Failed;
          return;
        end if;
      end if;

    elsif self.current_record_type = P.DATA_TYPE then
      if data'length > 0 and then not response.finished then
        declare
          context : Request_Context;
          count   : constant Interfaces.Unsigned_64 :=
            Interfaces.Unsigned_64(data'length);
        begin
          if self.filter_data_received > self.filter_data_length or else
             count > self.filter_data_length - self.filter_data_received
          then
            self.failed := True;
            status := Invalid_Content_Length;
            return;
          end if;

          self.filter_data_received := self.filter_data_received + count;
          initialize_request_context
            (context, identity(self), self.role_value);
          on_data (handler, context, data, response);
        end;

        if response.failed then
          self.failed := True;
          status := Output_Failed;
          return;
        end if;
      end if;
    else
      self.failed := True;
      status := Invalid_Record_Type;
      return;
    end if;

    self.content_remaining := self.content_remaining - data'length;
    status := Input_Progress;
  end feed_content;

  procedure end_record
    (self     : in out Exchange;
     handler  : in out Application'Class;
     response : in out Writer;
     status   : out Input_Status)
  is
    begin_request     : M.Begin_Request_Body;
    body_status       : M.Body_Status;
    completion_status : Write_Status;
    record_type       : P.Byte;
    content_length    : Natural;
  begin
    if self.failed or else not self.record_open then
      status := Invalid_Record_Sequence;
      return;
    end if;

    if self.content_remaining /= 0 then
      self.failed := True;
      status := Invalid_Content_Length;
      return;
    end if;

    record_type := self.current_record_type;
    content_length := self.current_content_length;
    self.record_open := False;

    if record_type = P.BEGIN_REQUEST_TYPE then
      M.decode_begin_request (self.begin_body, begin_request, body_status);

      if body_status /= M.Body_Complete then
        self.failed := True;
        status := Invalid_Content_Length;
        return;
      end if;

      self.keep_flag := (begin_request.flags and P.KEEP_CONN) /= 0;

      if begin_request.role_code = P.RESPONDER_ROLE then
        self.role_value := P.Responder;
        status := Record_Complete;
        return;
      elsif begin_request.role_code = P.AUTHORIZER_ROLE then
        self.role_value := P.Authorizer;
        status := Record_Complete;
        return;
      elsif begin_request.role_code = P.FILTER_ROLE then
        self.role_value := P.Filter;
        status := Record_Complete;
        return;
      end if;

      finish_with_protocol_status
        (self                 => response,
         application_status   => 0,
         protocol_status_code => P.UNKNOWN_ROLE_STATUS,
         close_streams        => False,
         status               => completion_status);

      if completion_status /= Write_Complete then
        self.failed := True;
        status := Output_Failed;
        return;
      end if;

      self.active := False;
      self.complete_flag := True;
      status := Request_Complete;
      return;
    end if;

    if record_type = P.ABORT_REQUEST_TYPE then
      cancel
        (self     => self,
         response => response,
         cause    => Peer_Abort,
         status   => status);
      return;
    end if;

    if record_type = P.PARAMS_TYPE then
      if content_length = 0 then
        if not N.at_pair_boundary (self.params_decoder) then
          self.failed := True;
          status := Malformed_Params;
          return;
        end if;

        if self.role_value = P.Filter and then
           (not self.filter_data_length_seen or else
            not self.filter_data_last_mod_seen)
        then
          self.failed := True;
          status := Malformed_Params;
          return;
        end if;

        self.params_closed := True;
        declare
          context     : Request_Context;
          saved_limit : constant Natural := response.limit;
        begin
          if self.role_value = P.Filter then
            response.limit := response.length;
          end if;

          initialize_request_context
            (context, identity(self), self.role_value);
          on_params_end (handler, context, response);
          response.limit := saved_limit;
        end;
      end if;

    elsif record_type = P.STDIN_TYPE then
      if content_length = 0 then
        self.stdin_closed := True;
        declare
          context : Request_Context;
        begin
          initialize_request_context
            (context, identity(self), self.role_value);
          on_stdin_end (handler, context, response);
        end;
      end if;

    elsif record_type = P.DATA_TYPE then
      if content_length = 0 then
        self.data_closed := True;
        declare
          context : Request_Context;
        begin
          initialize_request_context
            (context, identity(self), self.role_value);
          on_data_end (handler, context, response);
        end;
      end if;
    else
      self.failed := True;
      status := Invalid_Record_Type;
      return;
    end if;

    if response.failed then
      self.failed := True;
      status := Output_Failed;
      return;
    end if;

    if response.finished then
      self.active := False;
      self.complete_flag := True;
      status := Request_Complete;
    else
      status := Record_Complete;
    end if;
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
