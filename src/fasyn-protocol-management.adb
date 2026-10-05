-- ============================================================================
-- fasyn-protocol-management.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Fasyn.Protocol.Name_Values;

package body Fasyn.Protocol.Management is

  package N renames Fasyn.Protocol.Name_Values;

  use type Byte;
  use type N.Encode_Status;

  MAX_CONNECTIONS_NAME : constant String := "FCGI_MAX_CONNS";
  MAX_REQUESTS_NAME    : constant String := "FCGI_MAX_REQS";
  MULTIPLEXING_NAME    : constant String := "FCGI_MPXS_CONNS";

  function byte_matches
    (expected : String;
     position : Positive;
     value    : Byte) return Boolean
  is
  begin
    return value =
      Byte(Character'Pos(expected(expected'first + position - 1)));
  end byte_matches;

  procedure reset_pair (self : in out Query) is
  begin
    self.phase := Name_Length_First;
    self.length_accumulator := 0;
    self.length_bytes_left := 0;
    self.length_is_long := False;
    self.name_length := 0;
    self.value_length := 0;
    self.name_position := 0;
    self.value_position := 0;
    self.max_connections_match := False;
    self.max_requests_match := False;
    self.multiplexing_match := False;
  end reset_pair;

  procedure reset (self : in out Query) is
  begin
    reset_pair (self);
    self.max_connections_seen := False;
    self.max_requests_seen := False;
    self.multiplexing_seen := False;
  end reset;

  procedure begin_length
    (self           : in out Query;
     value          : in Byte;
     rest_phase     : in Query_Phase;
     complete_phase : in Query_Phase)
  is
  begin
    if (value and 16#80#) = 0 then
      self.length_accumulator := Natural(value);
      self.length_bytes_left := 0;
      self.length_is_long := False;
      self.phase := complete_phase;
    else
      self.length_accumulator := Natural(value and 16#7f#);
      self.length_bytes_left := 3;
      self.length_is_long := True;
      self.phase := rest_phase;
    end if;
  end begin_length;

  procedure continue_length
    (self           : in out Query;
     value          : in Byte;
     complete_phase : in Query_Phase)
  is
  begin
    self.length_accumulator :=
      self.length_accumulator * 256 + Natural(value);
    self.length_bytes_left := self.length_bytes_left - 1;

    if self.length_bytes_left = 0 then
      self.phase := complete_phase;
    end if;
  end continue_length;

  procedure finish_name_length (self : in out Query) is
  begin
    self.name_length := self.length_accumulator;
    self.length_accumulator := 0;
    if self.length_is_long and then self.name_length <= 127 then
      self.phase := Malformed_State;
      return;
    end if;
    self.name_position := 0;
    self.max_connections_match :=
      self.name_length = MAX_CONNECTIONS_NAME'length;
    self.max_requests_match :=
      self.name_length = MAX_REQUESTS_NAME'length;
    self.multiplexing_match :=
      self.name_length = MULTIPLEXING_NAME'length;
    self.phase := Value_Length_First;
  end finish_name_length;

  procedure complete_pair (self : in out Query) is
  begin
    if self.max_connections_match then
      self.max_connections_seen := True;
    elsif self.max_requests_match then
      self.max_requests_seen := True;
    elsif self.multiplexing_match then
      self.multiplexing_seen := True;
    end if;

    reset_pair (self);
  end complete_pair;

  procedure finish_value_length (self : in out Query) is
  begin
    self.value_length := self.length_accumulator;
    self.length_accumulator := 0;
    if self.length_is_long and then self.value_length <= 127 then
      self.phase := Malformed_State;
      return;
    end if;
    self.value_position := 0;

    if self.name_length > 0 then
      self.phase := Name_Data;
    elsif self.value_length > 0 then
      self.phase := Value_Data;
    else
      complete_pair (self);
    end if;
  end finish_value_length;

  procedure feed
    (self  : in out Query;
     value : in Byte)
  is
  begin
    case self.phase is
      when Name_Length_First =>
        begin_length
          (self, value, Name_Length_Rest, Value_Length_First);
        if self.phase = Value_Length_First then
          finish_name_length (self);
        end if;

      when Name_Length_Rest =>
        continue_length (self, value, Value_Length_First);
        if self.phase = Value_Length_First then
          finish_name_length (self);
        end if;

      when Value_Length_First =>
        begin_length
          (self, value, Value_Length_Rest, Name_Data);
        if self.phase = Name_Data then
          finish_value_length (self);
        end if;

      when Value_Length_Rest =>
        continue_length (self, value, Name_Data);
        if self.phase = Name_Data then
          finish_value_length (self);
        end if;

      when Name_Data =>
        self.name_position := self.name_position + 1;
        if self.max_connections_match and then
           not byte_matches
             (MAX_CONNECTIONS_NAME, self.name_position, value)
        then
          self.max_connections_match := False;
        end if;
        if self.max_requests_match and then
           not byte_matches (MAX_REQUESTS_NAME, self.name_position, value)
        then
          self.max_requests_match := False;
        end if;
        if self.multiplexing_match and then
           not byte_matches (MULTIPLEXING_NAME, self.name_position, value)
        then
          self.multiplexing_match := False;
        end if;

        if self.name_position = self.name_length then
          if self.value_length = 0 then
            complete_pair (self);
          else
            self.phase := Value_Data;
          end if;
        end if;

      when Value_Data =>
        self.value_position := self.value_position + 1;
        if self.value_position = self.value_length then
          complete_pair (self);
        end if;

      when Malformed_State =>
        null;
    end case;
  end feed;

  function at_pair_boundary (self : Query) return Boolean is
  begin
    return self.phase = Name_Length_First;
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

  function encode_result
    (self              : in Query;
     configured_values : in Values;
     output            : out Byte_Array;
     written           : out Natural) return Result_Status
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

      pair_status := N.encode_pair
        (name    => name_bytes,
         value   => value_bytes,
         output  => pair_bytes,
         written => pair_written);

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
      append_pair (MAX_CONNECTIONS_NAME, configured_values.max_connections);
    end if;

    if self.max_requests_seen then
      append_pair (MAX_REQUESTS_NAME, configured_values.max_requests);
    end if;

    if self.multiplexing_seen then
      if configured_values.multiplexing then
        append_pair (MULTIPLEXING_NAME, 1);
      else
        append_pair (MULTIPLEXING_NAME, 0);
      end if;
    end if;

    if failed then
      return Result_Output_Too_Small;
    end if;

    return Result_Complete;
  end encode_result;

end Fasyn.Protocol.Management;
