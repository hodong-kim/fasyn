-- ============================================================================
-- fasyn-classic.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Ada.Environment_Variables;
with Interfaces.C;
with Clair.Errno;

package body Fasyn.Classic is

  use type Clair.Event_Loop.Context_Access;
  use type Clair.Network.IPv4_Address;
  use type Clair.Status.Code;
  use type Fasyn.Diagnostics.Reporter_Access;
  use type Fasyn.Listener.Accept_Handler_Access;

  function diagnostic
    (self     : in out Context;
     kind     : Fasyn.Diagnostics.Category;
     status   : Clair.Status.Code;
     message  : String) return Clair.Status.Code
  is
  begin
    if self.diagnostics /= null then
      Fasyn.Diagnostics.report
        (self.diagnostics.all, kind, status, message);
    end if;

    return status;
  end diagnostic;

  function parse_web_server_addresses
    (self  : in out Context;
     value : String) return Clair.Status.Code
  is
    address       : Clair.Network.IPv4_Address := [others => 0];
    address_count : Natural := 0;
    octet_index   : Positive range 1 .. 4 := 1;
    octet_value   : Natural := 0;
    digit_count   : Natural range 0 .. 3 := 0;

    function finish_octet return Boolean is
    begin
      if digit_count = 0 or else octet_value > 255 then
        return False;
      end if;

      address(octet_index) := Interfaces.C.unsigned_char(octet_value);
      octet_value := 0;
      digit_count := 0;
      return True;
    end finish_octet;

    function finish_address return Clair.Status.Code is
    begin
      if octet_index /= 4 or else not finish_octet then
        return Clair.Status.INVALID_ARGUMENT;
      end if;

      if address_count = MAX_WEB_SERVER_ADDRESSES then
        return Clair.Status.RANGE_ERROR;
      end if;

      address_count := address_count + 1;
      self.allowed_addresses(address_count) := address;
      address := [others => 0];
      octet_index := 1;
      return Clair.Status.OK;
    end finish_address;

    status : Clair.Status.Code;
  begin
    self.allowed_count := 0;

    if value'length = 0 then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    for ch of value loop
      if ch in '0' .. '9' then
        if digit_count = 3 then
          return Clair.Status.INVALID_ARGUMENT;
        end if;

        digit_count := digit_count + 1;
        octet_value := octet_value * 10 +
          Character'Pos(ch) - Character'Pos('0');

      elsif ch = '.' then
        if octet_index = 4 or else not finish_octet then
          return Clair.Status.INVALID_ARGUMENT;
        end if;

        octet_index := octet_index + 1;

      elsif ch = ',' then
        status := finish_address;
        if status /= Clair.Status.OK then
          return status;
        end if;

      else
        return Clair.Status.INVALID_ARGUMENT;
      end if;
    end loop;

    status := finish_address;
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.allowed_count := address_count;
    return Clair.Status.OK;
  end parse_web_server_addresses;

  function initialize
    (self        : in out Context;
     event_loop  : Clair.Event_Loop.Context_Access;
     handler     : Fasyn.Listener.Accept_Handler_Access;
     diagnostics : Fasyn.Diagnostics.Reporter_Access := null)
  return Clair.Status.Code
  is
    status : Clair.Status.Code;
  begin
    if self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    if event_loop = null or else handler = null then
      return Clair.Status.INVALID_ARGUMENT;
    end if;

    self.handler := handler;
    self.diagnostics := diagnostics;
    self.allowed_count := 0;
    self.restrict_peers :=
      Ada.Environment_Variables.Exists(FCGI_WEB_SERVER_ADDRS);

    if self.restrict_peers then
      declare
        value : constant String :=
          Ada.Environment_Variables.Value(FCGI_WEB_SERVER_ADDRS);
      begin
        status := parse_web_server_addresses (self, value);
      end;

      if status /= Clair.Status.OK then
        self.handler := null;
        self.restrict_peers := False;
        status := diagnostic
          (self,
           Fasyn.Diagnostics.Environment_Error,
           status,
           "invalid FCGI_WEB_SERVER_ADDRS binding");
        self.diagnostics := null;
        self.allowed_count := 0;
        return status;
      end if;
    end if;

    status := Fasyn.Listener.initialize
      (self       => self.listener,
       event_loop => event_loop,
       fd         => FCGI_LISTENSOCK_FILENO,
       handler    => self'Unchecked_Access);

    if status /= Clair.Status.OK then
      status := diagnostic
        (self,
         Fasyn.Diagnostics.System_Error,
         status,
         "failed to initialize inherited FastCGI listener");
      self.handler := null;
      self.diagnostics := null;
      self.allowed_count := 0;
      self.restrict_peers := False;
      return status;
    end if;

    self.initialized := True;
    return Clair.Status.OK;
  end initialize;

  function finalize (self : in out Context) return Clair.Status.Code is
    status : Clair.Status.Code;
  begin
    if not self.initialized then
      return Clair.Status.INVALID_STATE;
    end if;

    status := Fasyn.Listener.finalize (self.listener);
    if status /= Clair.Status.OK then
      return status;
    end if;

    self.handler := null;
    self.diagnostics := null;
    self.allowed_count := 0;
    self.restrict_peers := False;
    self.initialized := False;
    return Clair.Status.OK;
  end finalize;

  function is_active (self : Context) return Boolean is
  begin
    return self.initialized and then Fasyn.Listener.is_active(self.listener);
  end is_active;

  overriding function on_accept
    (self : in out Context;
     fd   : Clair.IO.Descriptor) return Clair.Status.Code
  is
    peer         : Clair.Network.IPv4_Address;
    status       : Clair.Status.Code;
    close_status : Clair.Status.Code;
    allowed      : Boolean := False;
  begin
    if not self.initialized or else self.handler = null then
      return Clair.Status.INVALID_STATE;
    end if;

    if self.restrict_peers then
      status := Clair.Network.peer_ipv4_address (fd, peer);

      if status = Clair.Status.OK then
        for index in 1 .. self.allowed_count loop
          if peer = self.allowed_addresses(index) then
            allowed := True;
            exit;
          end if;
        end loop;

        if not allowed then
          close_status := Clair.IO.close (fd);
          if close_status /= Clair.Status.OK then
            return diagnostic
              (self,
               Fasyn.Diagnostics.System_Error,
               close_status,
               "failed to close rejected FastCGI peer");
          end if;

          return Clair.Status.OK;
        end if;

      elsif status = Clair.Status.from_errno(Clair.Errno.EAFNOSUPPORT) then
        -- The specification rejects a non-TCP/IP transport whenever
        -- FCGI_WEB_SERVER_ADDRS is bound.
        close_status := Clair.IO.close (fd);
        if close_status /= Clair.Status.OK then
          return diagnostic
            (self,
             Fasyn.Diagnostics.System_Error,
             close_status,
             "failed to close rejected non-TCP FastCGI peer");
        end if;

        return Clair.Status.OK;

      else
        -- Returning an error leaves the accepted descriptor owned by the
        -- outer Listener callback, which closes it exactly once.
        return diagnostic
          (self,
           Fasyn.Diagnostics.System_Error,
           status,
           "failed to query FastCGI peer IPv4 address");
      end if;
    end if;

    return Fasyn.Listener.on_accept (self.handler.all, fd);
  end on_accept;

end Fasyn.Classic;
