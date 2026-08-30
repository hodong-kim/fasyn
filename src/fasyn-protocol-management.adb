-- ============================================================================
-- fasyn-protocol-management.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Protocol.Management is

  use type Byte;
  use type N.Encode_Status;
  use type N.Feed_Status;

  function name_matches
    (self     : Query;
     expected : String) return Boolean
  is
  begin
    if N.name_length(self.decoder) /= expected'length then
      return False;
    end if;

    for offset in 0 .. expected'length - 1 loop
      if N.name_byte(self.decoder, offset + 1) /=
           Byte(Character'Pos(expected(expected'first + offset)))
      then
        return False;
      end if;
    end loop;

    return True;
  end name_matches;

  procedure reset (self : in out Query) is
  begin
    N.reset (self.decoder);
    self.max_connections_seen := False;
    self.max_requests_seen := False;
    self.multiplexing_seen := False;
  end reset;

  procedure feed
    (self   : in out Query;
     value  : in Byte;
     status : out Query_Status)
  is
    feed_status : N.Feed_Status;
  begin
    N.feed (self.decoder, value, feed_status);

    case feed_status is
      when N.Progress =>
        status := Query_Progress;

      when N.Pair_Complete =>
        if name_matches(self, "FCGI_MAX_CONNS") then
          self.max_connections_seen := True;
        elsif name_matches(self, "FCGI_MAX_REQS") then
          self.max_requests_seen := True;
        elsif name_matches(self, "FCGI_MPXS_CONNS") then
          self.multiplexing_seen := True;
        end if;

        N.reset (self.decoder);
        status := Query_Pair_Complete;

      when N.Limit_Exceeded =>
        status := Query_Limit_Exceeded;

      when N.Invalid_State =>
        status := Query_Invalid;
    end case;
  end feed;

  function at_pair_boundary (self : Query) return Boolean is
  begin
    return N.at_pair_boundary (self.decoder);
  end at_pair_boundary;

  function wants_max_connections (self : Query) return Boolean is
  begin
    return self.max_connections_seen;
  end wants_max_connections;

  function wants_max_requests (self : Query) return Boolean is
  begin
    return self.max_requests_seen;
  end wants_max_requests;

  function wants_multiplexing (self : Query) return Boolean is
  begin
    return self.multiplexing_seen;
  end wants_multiplexing;

  procedure encode_result
    (self    : in Query;
     configured_values : in Values;
     output  : out Byte_Array;
     written : out Natural;
     status  : out Result_Status)
  is
    failed : Boolean := False;

    procedure append_pair
      (name  : String;
       value : Natural)
    is
      image       : constant String := Natural'Image(value);
      digit_first : constant Positive := image'first + 1;
      digit_count : constant Natural := image'last - digit_first + 1;
      name_bytes  : Byte_Array (1 .. name'length);
      value_bytes : Byte_Array (1 .. digit_count);
      pair_bytes  : Byte_Array
        (1 .. N.encoded_size(name'length, digit_count));
      pair_written : Natural;
      pair_status  : N.Encode_Status;
    begin
      if failed then
        return;
      end if;

      for offset in 0 .. name'length - 1 loop
        name_bytes(offset + 1) :=
          Byte(Character'Pos(name(name'first + offset)));
      end loop;

      for offset in 0 .. digit_count - 1 loop
        value_bytes(offset + 1) :=
          Byte(Character'Pos(image(digit_first + offset)));
      end loop;

      N.encode_pair
        (name    => name_bytes,
         value   => value_bytes,
         output  => pair_bytes,
         written => pair_written,
         status  => pair_status);

      if pair_status /= N.Encode_Complete or else
         pair_written > output'length - written
      then
        failed := True;
        return;
      end if;

      for offset in 0 .. pair_written - 1 loop
        output(output'first + written + offset) :=
          pair_bytes(pair_bytes'first + offset);
      end loop;

      written := written + pair_written;
    end append_pair;

  begin
    written := 0;

    if self.max_connections_seen then
      append_pair ("FCGI_MAX_CONNS", configured_values.max_connections);
    end if;

    if self.max_requests_seen then
      append_pair ("FCGI_MAX_REQS", configured_values.max_requests);
    end if;

    if self.multiplexing_seen then
      if configured_values.multiplexing then
        append_pair ("FCGI_MPXS_CONNS", 1);
      else
        append_pair ("FCGI_MPXS_CONNS", 0);
      end if;
    end if;

    if failed then
      status := Result_Output_Too_Small;
    else
      status := Result_Complete;
    end if;
  end encode_result;

end Fasyn.Protocol.Management;
