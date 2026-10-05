-- ============================================================================
-- fasyn-admission.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Admission is

  protected body Counters is

    procedure try_connection (accepted : out Boolean) is
    begin
      if connections < max_connections then
        connections := connections + 1;
        accepted := True;
      else
        accepted := False;
      end if;
    end try_connection;

    procedure release_connection (released : out Boolean) is
    begin
      if connections = 0 then
        released := False;
      else
        connections := connections - 1;
        released := True;
      end if;
    end release_connection;

    procedure try_request (accepted : out Boolean) is
    begin
      if requests < max_requests then
        requests := requests + 1;
        accepted := True;
      else
        accepted := False;
      end if;
    end try_request;

    procedure release_request (released : out Boolean) is
    begin
      if requests = 0 then
        released := False;
      else
        requests := requests - 1;
        released := True;
      end if;
    end release_request;

    function connection_count return Natural is
    begin
      return connections;
    end connection_count;

    function request_count return Natural is
    begin
      return requests;
    end request_count;

  end Counters;

  function try_acquire_connection (self : in out Context) return Boolean is
    accepted : Boolean;
  begin
    self.state.try_connection (accepted);
    return accepted;
  end try_acquire_connection;

  procedure release_connection (self : in out Context) is
    released : Boolean;
  begin
    self.state.release_connection (released);
    if not released then
      raise Program_Error with "connection admission release underflow";
    end if;
  end release_connection;

  function try_acquire_request (self : in out Context) return Boolean is
    accepted : Boolean;
  begin
    self.state.try_request (accepted);
    return accepted;
  end try_acquire_request;

  procedure release_request (self : in out Context) is
    released : Boolean;
  begin
    self.state.release_request (released);
    if not released then
      raise Program_Error with "request admission release underflow";
    end if;
  end release_request;

  function max_connections (self : Context) return Natural is
  begin
    return self.max_connections;
  end max_connections;

  function max_requests (self : Context) return Natural is
  begin
    return self.max_requests;
  end max_requests;

  function active_connections (self : Context) return Natural is
  begin
    return self.state.connection_count;
  end active_connections;

  function active_requests (self : Context) return Natural is
  begin
    return self.state.request_count;
  end active_requests;

end Fasyn.Admission;
