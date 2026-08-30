-- ============================================================================
-- tests-classic.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Interfaces.C;
with Clair.Event_Loop;
with Clair.IO;
with Clair.Process.Execution;
with Clair.Status;
with Clair.Test.Assertions;
with Fasyn.Classic;
with Fasyn.Diagnostics;
with Fasyn.Listener;

package body Tests.Classic is

  package A renames Clair.Test.Assertions;
  package PE renames Clair.Process.Execution;
  package D renames Fasyn.Diagnostics;
  package US renames Ada.Strings.Unbounded;

  use type Clair.Status.Code;
  use type D.Category;
  use type Interfaces.C.int;
  use type PE.Completion_Kind;

  function c_unix_listener_pair
    (listener_fd : access Interfaces.C.int;
     client_fd   : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_listener_pair";

  function c_tcp_listener_pair
    (listener_fd : access Interfaces.C.int;
     client_fd   : access Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_tcp_listener_pair";

  function c_is_nonblocking
    (fd : Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_is_nonblocking";

  function c_run_sigterm_fixture
    (listener_fd : Interfaces.C.int) return Interfaces.C.int
  with import,
       convention    => c,
       external_name => "fasyn_test_run_sigterm_fixture";

  function fixture_path return String is
  begin
    if not Ada.Environment_Variables.exists ("FASYN_CLASSIC_FIXTURE") then
      raise Program_Error with "FASYN_CLASSIC_FIXTURE is not configured";
    end if;

    return Ada.Environment_Variables.value ("FASYN_CLASSIC_FIXTURE");
  end fixture_path;

  type Diagnostic_Recorder is new D.Reporter with record
    count  : Natural := 0;
    kind   : D.Category := D.Environment_Error;
    status : Clair.Status.Code := Clair.Status.OK;
  end record;

  overriding procedure report
    (self    : in out Diagnostic_Recorder;
     kind    : D.Category;
     status  : Clair.Status.Code;
     message : String)
  is
    pragma Unreferenced (message);
  begin
    self.count := self.count + 1;
    self.kind := kind;
    self.status := status;
  end report;

  type Accept_Recorder is new Fasyn.Listener.Accept_Handler with record
    count : Natural := 0;
  end record;

  overriding function on_accept
    (self : in out Accept_Recorder;
     fd   : Clair.IO.Descriptor) return Clair.Status.Code
  is
  begin
    self.count := self.count + 1;
    return Clair.IO.close (fd);
  end on_accept;

  procedure run_fixture
    (listener_fd      : Clair.IO.Descriptor;
     mode             : String;
     bind_addresses   : Boolean;
     addresses        : String;
     timeout          : Ada.Real_Time.Time_Span;
     graceful_period  : Ada.Real_Time.Time_Span;
     execution_status : out Clair.Status.Code;
     completion       : out PE.Completion_Kind;
     exit_code        : out Integer)
  is
    command : PE.Command := PE.empty_command;
    outcome : PE.Result := PE.empty_result;
    policy  : constant PE.Timeout_Policy :=
      (mode            => PE.Timeout_Enabled,
       interval        => timeout,
       graceful_period => graceful_period,
       scope           => PE.Process_Only);
  begin
    completion := PE.Launch_Failed;
    exit_code := -1;
    PE.set_environment_mode (command, PE.Empty_Environment);

    execution_status := PE.set_executable (command, fixture_path);
    if execution_status = Clair.Status.OK then
      execution_status := PE.add_argument (command, mode);
    end if;
    if execution_status = Clair.Status.OK and then bind_addresses then
      execution_status := PE.set_environment_value
        (command, Fasyn.Classic.FCGI_WEB_SERVER_ADDRS, addresses);
    end if;
    if execution_status = Clair.Status.OK then
      execution_status := PE.set_standard_input_route
        (command,
         (kind       => PE.Descriptor_Input,
          descriptor => listener_fd));
    end if;
    if execution_status = Clair.Status.OK then
      execution_status := PE.set_standard_output_route
        (command, (kind => PE.Null_Output));
    end if;
    if execution_status = Clair.Status.OK then
      execution_status := PE.set_standard_error_route
        (command, (kind => PE.Null_Output));
    end if;
    if execution_status = Clair.Status.OK then
      execution_status := PE.set_timeout_policy (command, policy);
    end if;
    if execution_status = Clair.Status.OK then
      execution_status := PE.execute (command, outcome);
    end if;

    if execution_status = Clair.Status.OK and then
       PE.has_completion(outcome)
    then
      completion := PE.completion_of (outcome);
      if completion = PE.Exited then
        exit_code := Integer(PE.exit_code_of(outcome));
      end if;
    end if;
  end run_fixture;

  procedure close_pair
    (listener_fd : Clair.IO.Descriptor;
     client_fd   : Clair.IO.Descriptor;
     listener_status : out Clair.Status.Code;
     client_status   : out Clair.Status.Code)
  is
  begin
    client_status := Clair.IO.close (client_fd);
    listener_status := Clair.IO.close (listener_fd);
  end close_pair;

  procedure inherited_accept_case
    (reporter      : in out Clair.Test.Reporter.Context;
     tcp           : Boolean;
     bind_addresses : Boolean;
     addresses     : String;
     expected_exit : Integer;
     label_text    : String)
  is
    listener_raw : aliased Interfaces.C.int := -1;
    client_raw   : aliased Interfaces.C.int := -1;
    listener_fd  : Clair.IO.Descriptor;
    client_fd    : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    status       : Clair.Status.Code;
    completion   : PE.Completion_Kind;
    exit_code    : Integer;
    listener_close : Clair.Status.Code;
    client_close   : Clair.Status.Code;
  begin
    if tcp then
      native_error := c_tcp_listener_pair
        (listener_raw'access, client_raw'access);
    else
      native_error := c_unix_listener_pair
        (listener_raw'access, client_raw'access);
    end if;

    A.assert_equal_integer
      (reporter, Integer(native_error), 0, label_text & " fixture is created");
    if native_error /= 0 then
      return;
    end if;

    listener_fd := Clair.IO.Descriptor(listener_raw);
    client_fd := Clair.IO.Descriptor(client_raw);
    A.assert_equal_integer
      (reporter,
       Integer(c_is_nonblocking(listener_raw)),
       0,
       label_text & " inherited listener starts blocking");

    run_fixture
      (listener_fd      => listener_fd,
       mode             => "accept",
       bind_addresses   => bind_addresses,
       addresses        => addresses,
       timeout          => Ada.Real_Time.Seconds(3),
       graceful_period  => Ada.Real_Time.Milliseconds(250),
       execution_status => status,
       completion       => completion,
       exit_code        => exit_code);

    A.assert_true
      (reporter,
       status = Clair.Status.OK,
       label_text & " fixture execution succeeds");
    A.assert_true
      (reporter, completion = PE.Exited,
       label_text & " fixture exits normally");
    A.assert_equal_integer
      (reporter, exit_code, expected_exit,
       label_text & " acceptance result matches");
    A.assert_equal_integer
      (reporter,
       Integer(c_is_nonblocking(listener_raw)),
       0,
       label_text & " inherited listener mode is restored");

    close_pair
      (listener_fd, client_fd, listener_close, client_close);
    A.assert_true
      (reporter, client_close = Clair.Status.OK, label_text & " client closes");
    A.assert_true
      (reporter, listener_close = Clair.Status.OK,
       label_text & " listener closes");
  end inherited_accept_case;

  procedure inherited_unix_listener
    (reporter : in out Clair.Test.Reporter.Context) is
  begin
    inherited_accept_case
      (reporter, False, False, "", 0, "Unix inherited listener");
  end inherited_unix_listener;

  procedure inherited_tcp_listener
    (reporter : in out Clair.Test.Reporter.Context) is
  begin
    inherited_accept_case
      (reporter, True, False, "", 0, "TCP inherited listener");
  end inherited_tcp_listener;

  procedure allowed_tcp_peer
    (reporter : in out Clair.Test.Reporter.Context) is
  begin
    inherited_accept_case
      (reporter, True, True, "127.0.0.1", 0, "allowed TCP peer");
  end allowed_tcp_peer;

  procedure rejected_tcp_peer
    (reporter : in out Clair.Test.Reporter.Context) is
  begin
    inherited_accept_case
      (reporter, True, True, "192.0.2.1", 70, "rejected TCP peer");
  end rejected_tcp_peer;

  procedure rejected_unix_peer_when_restricted
    (reporter : in out Clair.Test.Reporter.Context) is
  begin
    inherited_accept_case
      (reporter, False, True, "127.0.0.1", 70, "restricted Unix peer");
  end rejected_unix_peer_when_restricted;

  procedure malformed_environment_in_child
    (reporter : in out Clair.Test.Reporter.Context) is
  begin
    inherited_accept_case
      (reporter, True, True, "127.0.0.1,", 67, "malformed address environment");
  end malformed_environment_in_child;

  procedure sigterm_integration
    (reporter : in out Clair.Test.Reporter.Context)
  is
    listener_raw : aliased Interfaces.C.int := -1;
    client_raw   : aliased Interfaces.C.int := -1;
    listener_fd  : Clair.IO.Descriptor;
    client_fd    : Clair.IO.Descriptor;
    native_error : Interfaces.C.int;
    listener_close : Clair.Status.Code;
    client_close   : Clair.Status.Code;
  begin
    native_error := c_unix_listener_pair
      (listener_raw'access, client_raw'access);
    A.assert_equal_integer
      (reporter, Integer(native_error), 0,
       "SIGTERM inherited listener is created");
    if native_error /= 0 then
      return;
    end if;

    listener_fd := Clair.IO.Descriptor(listener_raw);
    client_fd := Clair.IO.Descriptor(client_raw);
    native_error := c_run_sigterm_fixture (listener_raw);

    A.assert_equal_integer
      (reporter,
       Integer(native_error),
       0,
       "SIGTERM is handled after classic listener readiness and exits zero");
    A.assert_equal_integer
      (reporter,
       Integer(c_is_nonblocking(listener_raw)),
       0,
       "SIGTERM path restores inherited listener mode");

    close_pair
      (listener_fd, client_fd, listener_close, client_close);
    A.assert_true
      (reporter, client_close = Clair.Status.OK, "SIGTERM client closes");
    A.assert_true
      (reporter, listener_close = Clair.Status.OK, "SIGTERM listener closes");
  end sigterm_integration;

  function oversized_address_binding return String is
    result : US.Unbounded_String;
  begin
    for index in 1 .. Fasyn.Classic.MAX_WEB_SERVER_ADDRESSES + 1 loop
      if index > 1 then
        US.append (result, ",");
      end if;
      US.append (result, "127.0.0.1");
    end loop;
    return US.to_string (result);
  end oversized_address_binding;

  procedure environment_diagnostics
    (reporter : in out Clair.Test.Reporter.Context)
  is
    loop_context : aliased Clair.Event_Loop.Context;
    classic      : aliased Fasyn.Classic.Context;
    acceptor     : aliased Accept_Recorder;
    diagnostics  : aliased Diagnostic_Recorder;
    old_exists   : constant Boolean :=
      Ada.Environment_Variables.exists(Fasyn.Classic.FCGI_WEB_SERVER_ADDRS);
    old_value    : US.Unbounded_String;
    status       : Clair.Status.Code;
    loop_status  : Clair.Status.Code;
  begin
    if old_exists then
      old_value := US.to_unbounded_string
        (Ada.Environment_Variables.value(Fasyn.Classic.FCGI_WEB_SERVER_ADDRS));
    end if;

    status := Clair.Event_Loop.initialize (loop_context);
    A.assert_true
      (reporter, status = Clair.Status.OK, "diagnostic event loop initializes");
    if status /= Clair.Status.OK then
      return;
    end if;

    Ada.Environment_Variables.set
      (Fasyn.Classic.FCGI_WEB_SERVER_ADDRS, "127.0.0.1,");
    status := Fasyn.Classic.initialize
      (self        => classic,
       event_loop  => loop_context'Unchecked_Access,
       handler     => acceptor'Unchecked_Access,
       diagnostics => diagnostics'Unchecked_Access);

    A.assert_true
      (reporter,
       status = Clair.Status.INVALID_ARGUMENT,
       "malformed address binding is rejected before listener admission");
    A.assert_equal_natural
      (reporter, diagnostics.count, 1,
       "environment syntax failure is reported");
    A.assert_true
      (reporter,
       diagnostics.kind = D.Environment_Error and then
       diagnostics.status = Clair.Status.INVALID_ARGUMENT,
       "environment diagnostic preserves category and status");

    Ada.Environment_Variables.set
      (Fasyn.Classic.FCGI_WEB_SERVER_ADDRS, oversized_address_binding);
    status := Fasyn.Classic.initialize
      (self        => classic,
       event_loop  => loop_context'Unchecked_Access,
       handler     => acceptor'Unchecked_Access,
       diagnostics => diagnostics'Unchecked_Access);

    A.assert_true
      (reporter,
       status = Clair.Status.RANGE_ERROR,
       "address policy count is bounded");
    A.assert_equal_natural
      (reporter, diagnostics.count, 2, "address bound failure is reported");

    if old_exists then
      Ada.Environment_Variables.set
        (Fasyn.Classic.FCGI_WEB_SERVER_ADDRS, US.to_string(old_value));
    else
      Ada.Environment_Variables.clear (Fasyn.Classic.FCGI_WEB_SERVER_ADDRS);
    end if;

    loop_status := Clair.Event_Loop.finalize (loop_context);
    A.assert_true
      (reporter, loop_status = Clair.Status.OK,
       "diagnostic event loop finalizes");
  end environment_diagnostics;

  procedure run
    (reporter : in out Clair.Test.Reporter.Context)
  is
  begin
    Clair.Test.Reporter.run_scenario
      (reporter, "classic inherited Unix listener",
       inherited_unix_listener'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "classic inherited TCP listener",
       inherited_tcp_listener'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "classic allowed TCP peer", allowed_tcp_peer'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "classic rejected TCP peer", rejected_tcp_peer'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "classic rejects Unix peer when address-restricted",
       rejected_unix_peer_when_restricted'access);
    Clair.Test.Reporter.run_scenario
      (reporter,
       "classic malformed environment child",
       malformed_environment_in_child'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "classic environment diagnostics",
       environment_diagnostics'access);
    Clair.Test.Reporter.run_scenario
      (reporter, "classic SIGTERM integration", sigterm_integration'access);
  end run;

end Tests.Classic;
