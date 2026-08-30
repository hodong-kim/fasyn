-- ============================================================================
-- fasyn-protocol-name_values.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;

package body Fasyn.Protocol.Name_Values is

  use type Interfaces.Unsigned_8;
  use type Interfaces.Unsigned_32;

  function length_field_size (length : Natural) return Natural is
  begin
    if length <= 127 then
      return 1;
    end if;

    return 4;
  end length_field_size;

  procedure write_length
    (length   : in Natural;
     output   : in out Byte_Array;
     position : in out Natural)
  is
    encoded : constant Interfaces.Unsigned_32 :=
      Interfaces.Unsigned_32(length);
  begin
    if length <= 127 then
      output(position) := Byte(length);
      position := position + 1;
      return;
    end if;

    output(position) :=
      Byte(Interfaces.Shift_Right(encoded, 24) and 16#7f#) or 16#80#;
    output(position + 1) :=
      Byte(Interfaces.Shift_Right(encoded, 16) and 16#ff#);
    output(position + 2) :=
      Byte(Interfaces.Shift_Right(encoded, 8) and 16#ff#);
    output(position + 3) := Byte(encoded and 16#ff#);
    position := position + 4;
  end write_length;

  function encoded_size
    (name_length  : Natural;
     value_length : Natural)
  return Natural
  is
    total : constant Long_Long_Integer :=
      Long_Long_Integer(length_field_size(name_length)) +
      Long_Long_Integer(length_field_size(value_length)) +
      Long_Long_Integer(name_length) +
      Long_Long_Integer(value_length);
  begin
    if total > Long_Long_Integer(Natural'Last) then
      raise Constraint_Error with "FastCGI name-value pair is too large";
    end if;

    return Natural(total);
  end encoded_size;

  procedure encode_pair
    (name    : in Byte_Array;
     value   : in Byte_Array;
     output  : out Byte_Array;
     written : out Natural;
     status  : out Encode_Status)
  is
    required : constant Natural := encoded_size(name'length, value'length);
    position : Natural := output'first;
  begin
    written := 0;

    if output'length < required then
      status := Output_Too_Small;
      return;
    end if;

    write_length (name'length, output, position);
    write_length (value'length, output, position);

    for index in name'range loop
      output(position) := name(index);
      position := position + 1;
    end loop;

    for index in value'range loop
      output(position) := value(index);
      position := position + 1;
    end loop;

    written := required;
    status := Encode_Complete;
  end encode_pair;

  procedure reset (self : in out Decoder) is
  begin
    self.state := Name_Length_First;
    self.length_accumulator := 0;
    self.length_bytes_left := 0;
    self.decoded_name_length := 0;
    self.decoded_value_length := 0;
    self.name_position := 0;
    self.value_position := 0;
  end reset;

  function at_pair_boundary (self : Decoder) return Boolean is
  begin
    return self.state = Name_Length_First;
  end at_pair_boundary;

  procedure begin_length
    (self           : in out Decoder;
     value          : in Byte;
     rest_state     : in Phase;
     complete_state : in Phase)
  is
  begin
    if (value and 16#80#) = 0 then
      self.length_accumulator := Natural(value);
      self.length_bytes_left := 0;
      self.state := complete_state;
    else
      self.length_accumulator := Natural(value and 16#7f#);
      self.length_bytes_left := 3;
      self.state := rest_state;
    end if;
  end begin_length;

  procedure continue_length
    (self           : in out Decoder;
     value          : in Byte;
     complete_state : in Phase)
  is
  begin
    self.length_accumulator :=
      self.length_accumulator * 256 + Natural(value);
    self.length_bytes_left := self.length_bytes_left - 1;

    if self.length_bytes_left = 0 then
      self.state := complete_state;
    end if;
  end continue_length;

  procedure finish_name_length
    (self   : in out Decoder;
     status : out Feed_Status)
  is
  begin
    self.decoded_name_length := self.length_accumulator;
    self.length_accumulator := 0;

    if self.decoded_name_length > self.max_name_bytes then
      self.state := Failed_State;
      status := Limit_Exceeded;
      return;
    end if;

    self.state := Value_Length_First;
    status := Progress;
  end finish_name_length;

  procedure finish_value_length
    (self   : in out Decoder;
     status : out Feed_Status)
  is
  begin
    self.decoded_value_length := self.length_accumulator;
    self.length_accumulator := 0;

    if self.decoded_value_length > self.max_value_bytes then
      self.state := Failed_State;
      status := Limit_Exceeded;
      return;
    end if;

    if self.decoded_name_length > 0 then
      self.state := Name_Data;
      status := Progress;
    elsif self.decoded_value_length > 0 then
      self.state := Value_Data;
      status := Progress;
    else
      self.state := Complete_State;
      status := Pair_Complete;
    end if;
  end finish_value_length;

  procedure feed
    (self   : in out Decoder;
     value  : in Byte;
     status : out Feed_Status)
  is
  begin
    case self.state is
      when Name_Length_First =>
        begin_length
          (self           => self,
           value          => value,
           rest_state     => Name_Length_Rest,
           complete_state => Value_Length_First);

        if self.state = Value_Length_First then
          finish_name_length (self, status);
        else
          status := Progress;
        end if;

      when Name_Length_Rest =>
        continue_length
          (self           => self,
           value          => value,
           complete_state => Value_Length_First);

        if self.state = Value_Length_First then
          finish_name_length (self, status);
        else
          status := Progress;
        end if;

      when Value_Length_First =>
        begin_length
          (self           => self,
           value          => value,
           rest_state     => Value_Length_Rest,
           complete_state => Name_Data);

        if self.state = Name_Data then
          finish_value_length (self, status);
        else
          status := Progress;
        end if;

      when Value_Length_Rest =>
        continue_length
          (self           => self,
           value          => value,
           complete_state => Name_Data);

        if self.state = Name_Data then
          finish_value_length (self, status);
        else
          status := Progress;
        end if;

      when Name_Data =>
        self.name_position := self.name_position + 1;
        self.name_data(self.name_position) := value;

        if self.name_position = self.decoded_name_length then
          if self.decoded_value_length = 0 then
            self.state := Complete_State;
            status := Pair_Complete;
          else
            self.state := Value_Data;
            status := Progress;
          end if;
        else
          status := Progress;
        end if;

      when Value_Data =>
        self.value_position := self.value_position + 1;
        self.value_data(self.value_position) := value;

        if self.value_position = self.decoded_value_length then
          self.state := Complete_State;
          status := Pair_Complete;
        else
          status := Progress;
        end if;

      when Complete_State | Failed_State =>
        status := Invalid_State;
    end case;
  end feed;

  function name_length (self : Decoder) return Natural is
  begin
    return self.decoded_name_length;
  end name_length;

  function value_length (self : Decoder) return Natural is
  begin
    return self.decoded_value_length;
  end value_length;

  function name_byte
    (self  : Decoder;
     index : Positive)
  return Byte is
  begin
    if index > self.decoded_name_length then
      raise Constraint_Error with "name byte index out of range";
    end if;

    return self.name_data(index);
  end name_byte;

  function value_byte
    (self  : Decoder;
     index : Positive)
  return Byte is
  begin
    if index > self.decoded_value_length then
      raise Constraint_Error with "value byte index out of range";
    end if;

    return self.value_data(index);
  end value_byte;

end Fasyn.Protocol.Name_Values;
