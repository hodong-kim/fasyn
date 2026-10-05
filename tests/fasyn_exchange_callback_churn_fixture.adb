-- ============================================================================
-- fasyn_exchange_callback_churn_fixture.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- SPDX-License-Identifier: 0BSD
-- ============================================================================
with Ada.Command_Line;
with Ada.Text_IO;
with Fasyn.Protocol;
with Fasyn.Protocol.Bodies;
with Fasyn.Protocol.Name_Values;
with Fasyn.Request;

procedure Fasyn_Exchange_Callback_Churn_Fixture is
  package P renames Fasyn.Protocol;
  package B renames Fasyn.Protocol.Bodies;
  package N renames Fasyn.Protocol.Name_Values;
  package R renames Fasyn.Request;

  use type B.Body_Status;
  use type N.Encode_Status;
  use type R.Input_Status;

  WARMUP_REQUESTS : constant Positive := 50;
  MAX_NAME_BYTES  : constant Natural := 1_024;
  MAX_VALUE_BYTES : constant Natural := 4_096;
  OUTPUT_BYTES    : constant Positive := 256;

  type Workload_Kind is (Params_Finish, Params_Payload_Finish);

  function parse_workload (text : String) return Workload_Kind is
  begin
    if text = "params_finish" then
      return Params_Finish;
    elsif text = "params_payload_finish" then
      return Params_Payload_Finish;
    end if;
    raise Constraint_Error with "unknown Exchange callback workload";
  end parse_workload;

  function to_bytes (text : String) return P.Byte_Array is
    result : P.Byte_Array (1 .. text'Length);
  begin
    for offset in 0 .. text'Length - 1 loop
      result(offset + 1) := P.Byte(Character'Pos(text(text'First + offset)));
    end loop;
    return result;
  end to_bytes;

  function build_params return P.Byte_Array is
    buffer : P.Byte_Array (1 .. 1_024);
    used   : Natural := 0;

    procedure append_pair (name : String; value : String) is
      name_bytes    : constant P.Byte_Array := to_bytes (name);
      value_bytes   : constant P.Byte_Array := to_bytes (value);
      written       : Natural := 0;
      encode_status : N.Encode_Status;
    begin
      encode_status := N.encode_pair
        (name_bytes,
         value_bytes,
         buffer(used + 1 .. buffer'Last),
         written);
      if encode_status /= N.Encode_Complete then
        raise Program_Error with "Exchange PARAMS buffer is too small";
      end if;
      used := used + written;
    end append_pair;
  begin
    append_pair ("REQUEST_METHOD", "POST");
    append_pair ("CONTENT_TYPE", "application/json");
    append_pair ("CONTENT_LENGTH", "0");
    append_pair ("HTTP_ACCEPT", "application/json, text/event-stream");
    append_pair ("HTTP_MCP_PROTOCOL_VERSION", "2026-07-28");
    append_pair ("HTTP_MCP_METHOD", "tools/call");
    append_pair ("HTTP_MCP_NAME", "ping");
    return buffer(1 .. used);
  end build_params;

  function build_begin return P.Byte_Array is
    request : constant B.Begin_Request_Body :=
      (role_code => P.RESPONDER_CODE, flags => P.KEEP_CONN);
    bytes  : P.Byte_Array (0 .. B.BEGIN_REQUEST_BODY_LENGTH - 1);
    used   : Natural := 0;
    status : B.Body_Status;
  begin
    status := B.encode_begin_request (request, bytes, used);
    if status /= B.Body_Complete or else
       used /= B.BEGIN_REQUEST_BODY_LENGTH
    then
      raise Program_Error with "Exchange BEGIN_REQUEST encoding failed";
    end if;
    return bytes;
  end build_begin;

  PARAMS_PAYLOAD : constant P.Byte_Array := build_params;
  BEGIN_PAYLOAD  : constant P.Byte_Array := build_begin;
  EMPTY          : P.Byte_Array (1 .. 0);

  type Application is limited new R.Application with record
    parameter_count  : Natural := 0;
    params_end_count : Natural := 0;
  end record;

  overriding procedure on_parameter
    (self    : in out Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Application;
     context  : in R.Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Application;
     context : in R.Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (context, name, value);
  begin
    self.parameter_count := self.parameter_count + 1;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (context, response);
  begin
    self.params_end_count := self.params_end_count + 1;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Application;
     context  : in R.Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, data, response);
  begin
    null;
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Application;
     context  : in R.Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_stdin_end;

  app_handler : Application;
  workload    : Workload_Kind;
  batches     : Positive;
  batch_size  : Positive;
  sequence    : Natural := 0;
  failed      : Boolean := False;

  procedure set_exit (success : Boolean) is
  begin
    Ada.Command_Line.Set_Exit_Status
      (if success then Ada.Command_Line.Success else Ada.Command_Line.Failure);
  end set_exit;

  procedure wait_for_parent is
    acknowledgement : constant String := Ada.Text_IO.Get_Line;
    pragma Unreferenced (acknowledgement);
  begin
    null;
  end wait_for_parent;

  procedure drive_record
    (exchange   : in out R.Exchange;
     response   : in out R.Writer;
     record_type : P.Byte;
     request_id  : P.Request_Id;
     generation  : R.Generation;
     content     : P.Byte_Array)
  is
    header : constant P.Header :=
      (version        => P.VERSION_1,
       record_type    => record_type,
       request_id     => request_id,
       content_length => P.Content_Length(content'Length),
       padding_length => 0);
    status : R.Input_Status;
  begin
    status := R.begin_record
      (exchange,
       header,
       response,
       connection_id => 1,
       generation    => generation);
    if status /= R.Input_Progress then
      failed := True;
      return;
    end if;

    if content'Length /= 0 then
      status := R.feed_content (exchange, content, app_handler, response);
      if status /= R.Input_Progress then
        failed := True;
        return;
      end if;
    end if;

    status := R.end_record (exchange, app_handler, response);
    if status /= R.Record_Complete then
      failed := True;
    end if;
  end drive_record;

  procedure run_one is
    request_id : P.Request_Id;
    generation : R.Generation;
  begin
    sequence := sequence + 1;
    request_id := P.Request_Id(((sequence - 1) mod 65_535) + 1);
    generation := R.Generation(sequence);
    app_handler.parameter_count := 0;
    app_handler.params_end_count := 0;

    declare
      exchange : R.Exchange
        (max_name_bytes  => MAX_NAME_BYTES,
         max_value_bytes => MAX_VALUE_BYTES);
      response : R.Writer (max_output_bytes => OUTPUT_BYTES);
      status   : R.Input_Status;
    begin
      drive_record
        (exchange, response, P.BEGIN_REQUEST, request_id, generation,
         BEGIN_PAYLOAD);
      if failed then
        return;
      end if;

      if workload = Params_Payload_Finish then
        drive_record
          (exchange, response, P.PARAMS, request_id, generation,
           PARAMS_PAYLOAD);
        if failed then
          return;
        end if;
      end if;

      drive_record
        (exchange, response, P.PARAMS, request_id, generation, EMPTY);
      if failed then
        return;
      end if;

      if app_handler.params_end_count /= 1 or else
         (workload = Params_Finish and then
          app_handler.parameter_count /= 0) or else
         (workload = Params_Payload_Finish and then
          app_handler.parameter_count /= 7)
      then
        failed := True;
        return;
      end if;

      status := R.cancel (exchange, response, R.Peer_Abort);
      if status /= R.Request_Complete then
        failed := True;
      end if;
    end;
  end run_one;

  procedure run_many (count : Positive) is
  begin
    for iteration in 1 .. count loop
      pragma Unreferenced (iteration);
      run_one;
      exit when failed;
    end loop;
  end run_many;

begin
  if Ada.Command_Line.Argument_Count /= 3 then
    set_exit (False);
    return;
  end if;

  begin
    workload := parse_workload (Ada.Command_Line.Argument (1));
    batches := Positive'Value (Ada.Command_Line.Argument (2));
    batch_size := Positive'Value (Ada.Command_Line.Argument (3));
  exception
    when Constraint_Error =>
      set_exit (False);
      return;
  end;

  run_many (WARMUP_REQUESTS);
  if not failed then
    Ada.Text_IO.Put_Line ("ready");
    Ada.Text_IO.Flush;
    wait_for_parent;

    for batch in 1 .. batches loop
      run_many (batch_size);
      exit when failed;
      Ada.Text_IO.Put_Line (Positive'Image(batch));
      Ada.Text_IO.Flush;
      wait_for_parent;
    end loop;
  end if;

  set_exit (not failed);
exception
  when others =>
    set_exit (False);
end Fasyn_Exchange_Callback_Churn_Fixture;
