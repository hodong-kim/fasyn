-- ============================================================================
-- tests-execution.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Clair.Event_Loop;
with Clair.Status;
with Clair.Test.Assertions;
with Fasyn.Protocol;
with Fasyn.Request;
with Fasyn.Request.Execution;

package body Tests.Execution is

  package A renames Clair.Test.Assertions;
  package E renames Fasyn.Request.Execution;
  package P renames Fasyn.Protocol;
  package R renames Fasyn.Request;

  use type Clair.Status.Code;
  use type R.Defer_Status;
  use type R.Request_Identity;

  protected type Test_Gate is
    procedure mark_started;
    entry wait_started;
    entry wait_release;
    procedure release;
  private
    has_started : Boolean := False;
    is_released : Boolean := False;
  end Test_Gate;

  protected body Test_Gate is
    procedure mark_started is
    begin
      has_started := True;
    end mark_started;

    entry wait_started when has_started is
    begin
      null;
    end wait_started;

    entry wait_release when is_released is
    begin
      null;
    end wait_release;

    procedure release is
    begin
      is_released := True;
    end release;
  end Test_Gate;

  type Gate_Access is access all Test_Gate;

  type Test_Application is new R.Application with record
    gate : Gate_Access := null;
  end record;

  overriding procedure on_parameter
    (self    : in out Test_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Test_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array)
  is
    pragma Unreferenced (self, context, name, value);
  begin
    null;
  end on_parameter;

  overriding procedure on_params_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer)
  is
    pragma Unreferenced (context);
    write_status : R.Write_Status;
  begin
    if self.gate /= null then
      self.gate.mark_started;
      self.gate.wait_release;
    end if;

    R.write_stdout (response, data, write_status);
  end on_stdin;

  overriding procedure on_stdin_end
    (self     : in out Test_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
    pragma Unreferenced (self, context, response);
  begin
    null;
  end on_stdin_end;

  type Role_Defer_Application is limited new R.Application with record
    responder_handle  : R.Deferred_Request;
    authorizer_handle : R.Deferred_Request;
    filter_handle     : R.Deferred_Request;
    responder_status  : R.Defer_Status := R.Defer_Not_Ready;
    authorizer_status : R.Defer_Status := R.Defer_Not_Ready;
    filter_status     : R.Defer_Status := R.Defer_Not_Ready;
  end record;

  overriding procedure on_parameter
    (self    : in out Role_Defer_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array);

  overriding procedure on_params_end
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_stdin
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer);

  overriding procedure on_stdin_end
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_data_end
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer);

  overriding procedure on_parameter
    (self    : in out Role_Defer_Application;
     context : in R.Request_Context;
     name    : in P.Byte_Array;
     value   : in P.Byte_Array) is null;

  overriding procedure on_params_end
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
  begin
    R.defer_response
      (context, response, self.authorizer_handle, self.authorizer_status);
  end on_params_end;

  overriding procedure on_stdin
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     data     : in P.Byte_Array;
     response : in out R.Writer) is null;

  overriding procedure on_stdin_end
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
  begin
    R.defer_response
      (context, response, self.responder_handle, self.responder_status);
  end on_stdin_end;

  overriding procedure on_data_end
    (self     : in out Role_Defer_Application;
     context  : in R.Request_Context;
     response : in out R.Writer)
  is
  begin
    R.defer_response
      (context, response, self.filter_handle, self.filter_status);
  end on_data_end;

  type Identity_Array is array (Positive range 1 .. 4) of R.Request_Identity;

  type Test_Completion_Handler is new E.Completion_Handler with record
    count      : Natural := 0;
    identities : Identity_Array := [others => R.NULL_REQUEST_IDENTITY];
    bytes_seen : Natural := 0;
  end record;

  overriding function on_completion
    (handler         : in out Test_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code;

  overriding function on_completion
    (handler         : in out Test_Completion_Handler;
     item            : in E.Completion;
     callback_status : in Clair.Status.Code) return Clair.Status.Code
  is
  begin
    if callback_status /= Clair.Status.OK then
      return callback_status;
    end if;

    handler.count := handler.count + 1;
    if handler.count <= handler.identities'last then
      handler.identities(handler.count) := E.completion_request(item);
    end if;

    handler.bytes_seen := handler.bytes_seen + E.output_length(item);
    return Clair.Status.OK;
  end on_completion;

  procedure role_terminal_deferral
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    app        : aliased Role_Defer_Application;
    handler    : aliased Test_Completion_Handler;
    responder  : constant R.Request_Identity :=
      (connection_id => 2, request_id => 1, generation => 1);
    authorizer : constant R.Request_Identity :=
      (connection_id => 2, request_id => 2, generation => 1);
    filter     : constant R.Request_Identity :=
      (connection_id => 2, request_id => 3, generation => 1);
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 2, 2, 64, 128, 1, 4);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer executor initializes");

    status := E.submit_stdin_end
      (executor, responder, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "responder terminal callback is accepted");
    status := E.submit_params_end
      (executor, authorizer, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Authorizer);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "authorizer terminal callback is accepted");
    status := E.submit_data_end
      (executor, filter, app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Filter);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "filter terminal callback is accepted");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 3;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter,
         status = Clair.Status.OK,
         "role defer polling succeeds");
    end loop;

    A.assert_equal_natural
      (reporter,
       handler.count,
       3,
       "role callbacks complete");
    A.assert_true
      (reporter, app.responder_status = R.Defer_Complete and then
       R.identity(app.responder_handle) = responder,
       "responder may defer at STDIN end");
    A.assert_true
      (reporter, app.authorizer_status = R.Defer_Complete and then
       R.identity(app.authorizer_handle) = authorizer,
       "authorizer may defer at PARAMS end");
    A.assert_true
      (reporter, app.filter_status = R.Defer_Complete and then
       R.identity(app.filter_handle) = filter,
       "filter may defer at DATA end");
    A.assert_true
      (reporter,
       E.active_count(executor) = 0 and then
         E.pending_count(executor) = 0,
       "role deferred handles do not retain workers");

    E.retire_deferred (executor, responder);
    E.retire_deferred (executor, authorizer);
    E.retire_deferred (executor, filter);
    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       "role defer loop finalizes");
  end role_terminal_deferral;

  procedure deferred_capacity_is_bounded
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    first_app  : aliased Role_Defer_Application;
    second_app : aliased Role_Defer_Application;
    handler    : aliased Test_Completion_Handler;
    first      : constant R.Request_Identity :=
      (connection_id => 3, request_id => 1, generation => 1);
    second     : constant R.Request_Identity :=
      (connection_id => 3, request_id => 2, generation => 1);
    accepted   : Boolean;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity loop initializes");
    status := E.initialize
      (executor, event_loop'Unchecked_Access, 1, 2, 64, 128, 1, 1);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity executor initializes");

    status := E.submit_stdin_end
      (executor, first, first_app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "first deferred candidate is accepted");
    status := E.submit_stdin_end
      (executor, second, second_app'Unchecked_Access, handler'Unchecked_Access,
       64, accepted, P.Responder);
    A.assert_true
      (reporter, status = Clair.Status.OK and then accepted,
       "second deferred candidate is accepted by executor");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2;
      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter,
         status = Clair.Status.OK,
         "capacity completion polling succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, 2, "both capacity callbacks return");
    A.assert_true
      (reporter, first_app.responder_status = R.Defer_Complete,
       "first request consumes the sole deferred slot");
    A.assert_true
      (reporter, second_app.responder_status = R.Defer_Capacity_Exceeded,
       "second request observes bounded deferred capacity");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity shutdown begins");
    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity executor finalizes");
    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "capacity loop finalizes");
  end deferred_capacity_is_bounded;

  procedure bounded_saturation_and_shutdown
    (reporter : in out Clair.Test.Reporter.Context)
  is
    event_loop : aliased Clair.Event_Loop.Context;
    executor   : aliased E.Context;
    gate       : aliased Test_Gate;
    app        : aliased Test_Application;
    handler    : aliased Test_Completion_Handler;
    first      : constant R.Request_Identity :=
      (connection_id => 1, request_id => 1, generation => 1);
    second     : constant R.Request_Identity :=
      (connection_id => 1, request_id => 2, generation => 1);
    third      : constant R.Request_Identity :=
      (connection_id => 1, request_id => 3, generation => 1);
    data       : constant P.Byte_Array := [16#41#];
    accepted   : Boolean;
    started    : Boolean := False;
    dispatched : Boolean;
    status     : Clair.Status.Code;
  begin
    app.gate := gate'Unchecked_Access;

    status := Clair.Event_Loop.initialize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "event loop initializes");

    status := E.initialize
      (self             => executor,
       event_loop       => event_loop'Unchecked_Access,
       worker_count     => 1,
       pending_capacity => 1,
       max_input_bytes  => 64,
       max_output_bytes => 128,
       poll_interval    => 1);
    A.assert_true
      (reporter, status = Clair.Status.OK, "executor initializes");

    status := E.submit_stdin
      (executor,
       first,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then accepted,
       "first job is accepted");

    select
      gate.wait_started;
      started := True;
    or
      delay 1.0;
    end select;
    A.assert_true (reporter, started, "worker begins gated job");

    status := E.submit_stdin
      (executor,
       first,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then not accepted,
       "same request generation cannot execute concurrently");

    status := E.submit_stdin
      (executor,
       second,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then accepted,
       "pending job is accepted");
    A.assert_equal_natural
      (reporter, E.active_count(executor), 1, "worker count is bounded");
    A.assert_equal_natural
      (reporter, E.pending_count(executor), 1, "pending queue is bounded");

    status := E.submit_stdin
      (executor,
       third,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then not accepted,
       "job beyond pending capacity is refused");

    gate.release;

    for attempt in 1 .. 200 loop
      pragma Unreferenced (attempt);
      exit when handler.count = 2;

      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK, "completion polling succeeds");
    end loop;

    A.assert_equal_natural
      (reporter, handler.count, 2, "two accepted jobs complete");
    A.assert_true
      (reporter,
       handler.identities(1) = first,
       "first completion retains request identity");
    A.assert_true
      (reporter,
       handler.identities(2) = second,
       "second completion retains request identity");
    A.assert_true
      (reporter,
       handler.bytes_seen > 0,
       "worker output returns through completion boundary");

    status := E.begin_shutdown (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "shutdown begins");
    A.assert_true
      (reporter, not E.is_accepting(executor), "shutdown stops admission");

    status := E.submit_stdin
      (executor,
       third,
       app'Unchecked_Access,
       handler'Unchecked_Access,
       data,
       64,
       accepted);
    A.assert_true
      (reporter,
       status = Clair.Status.OK and then not accepted,
       "shutdown refuses new work");

    for attempt in 1 .. 100 loop
      pragma Unreferenced (attempt);
      exit when E.is_idle(executor) and then E.completed_count(executor) = 0;

      status := Clair.Event_Loop.iterate
        (event_loop, timeout => 10, dispatched => dispatched);
      A.assert_true
        (reporter, status = Clair.Status.OK, "shutdown drain polling succeeds");
    end loop;

    A.assert_true
      (reporter, E.is_idle(executor), "accepted work drains before finalize");

    status := E.finalize (executor);
    A.assert_true
      (reporter, status = Clair.Status.OK, "executor finalizes");

    status := Clair.Event_Loop.finalize (event_loop);
    A.assert_true
      (reporter, status = Clair.Status.OK, "event loop finalizes");
  end bounded_saturation_and_shutdown;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter,
       "role terminal deferral",
       role_terminal_deferral'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "deferred capacity is bounded",
       deferred_capacity_is_bounded'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "bounded saturation and shutdown",
       bounded_saturation_and_shutdown'access);
  end run;

end Tests.Execution;
