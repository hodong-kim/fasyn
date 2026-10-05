-- ============================================================================
-- fasyn-protocol-codec.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
with Interfaces;

package body Fasyn.Protocol.Codec is

  use type Interfaces.Unsigned_8;
  use type Interfaces.Unsigned_16;

  function high_byte (value : Interfaces.Unsigned_16) return Byte is
  begin
    return Byte(Interfaces.Shift_Right (value, 8) and 16#ff#);
  end high_byte;

  function low_byte (value : Interfaces.Unsigned_16) return Byte is
  begin
    return Byte(value and 16#ff#);
  end low_byte;

  procedure reset (self : in out Header_Decoder) is
  begin
    self.bytes := [others => 0];
    self.received := 0;
  end reset;

  procedure reset (self : in out Record_Decoder) is
  begin
    reset (self.header_parser);
    self.current_header := (others => <>);
    self.phase := Reading_Header;
    self.content_remaining := 0;
    self.padding_remaining := 0;
    self.complete_flag := False;
  end reset;

  function feed
    (self          : in out Header_Decoder;
     value         : in Byte;
     record_header : out Header) return Decode_Status
  is
  begin
    record_header := (others => <>);

    if self.received = HEADER_LENGTH then
      reset (self);
    end if;

    self.bytes(self.received) := value;
    self.received := self.received + 1;

    if self.received < HEADER_LENGTH then
      return Need_More_Data;
    end if;

    return decode_header (self.bytes, record_header);
  end feed;

  function feed
    (self          : in out Record_Decoder;
     value         : in Byte;
     event         : out Record_Event;
     record_header : out Header) return Decode_Status
  is
    decoded_header : Header;
    status         : Decode_Status := Complete;
  begin
    if self.complete_flag then
      reset (self);
    end if;

    record_header := self.current_header;

    case self.phase is
      when Reading_Header =>
        status := feed
          (self          => self.header_parser,
           value         => value,
           record_header => decoded_header);

        if status = Need_More_Data then
          event := Header_Progress;
          return status;
        end if;

        if status /= Complete then
          event := Decode_Error;
          return status;
        end if;

        self.current_header := decoded_header;
        self.content_remaining := Natural(decoded_header.content_length);
        self.padding_remaining := Natural(decoded_header.padding_length);
        record_header := decoded_header;
        event := Header_Ready;

        if self.content_remaining > 0 then
          self.phase := Reading_Content;
        elsif self.padding_remaining > 0 then
          self.phase := Reading_Padding;
        else
          self.complete_flag := True;
        end if;

      when Reading_Content =>
        event := Content_Byte;
        self.content_remaining := self.content_remaining - 1;

        if self.content_remaining = 0 then
          if self.padding_remaining > 0 then
            self.phase := Reading_Padding;
          else
            self.complete_flag := True;
          end if;
        end if;

      when Reading_Padding =>
        event := Padding_Byte;
        self.padding_remaining := self.padding_remaining - 1;

        if self.padding_remaining = 0 then
          self.complete_flag := True;
        end if;
    end case;

    return status;
  end feed;

  function is_complete (self : Record_Decoder) return Boolean is
  begin
    return self.complete_flag;
  end is_complete;

  procedure encode_header
    (record_header : in Header;
     output        : out Byte_Array)
  is
    first : constant Natural := output'first;
  begin
    if output'length < HEADER_LENGTH then
      raise Constraint_Error with "FastCGI header output requires eight bytes";
    end if;

    output(first)     := record_header.version;
    output(first + 1) := record_header.record_type;
    output(first + 2) := high_byte (record_header.request_id);
    output(first + 3) := low_byte (record_header.request_id);
    output(first + 4) := high_byte (record_header.content_length);
    output(first + 5) := low_byte (record_header.content_length);
    output(first + 6) := record_header.padding_length;
    output(first + 7) := 0;
  end encode_header;

  function decode_header
    (input         : in Byte_Array;
     record_header : out Header) return Decode_Status
  is
    first : constant Natural := input'first;
  begin
    record_header := (others => <>);

    if input'length < HEADER_LENGTH then
      return Need_More_Data;
    end if;

    record_header.version := input(first);
    record_header.record_type := input(first + 1);
    record_header.request_id :=
      Interfaces.Unsigned_16(input(first + 2)) * 256 +
      Interfaces.Unsigned_16(input(first + 3));
    record_header.content_length :=
      Interfaces.Unsigned_16(input(first + 4)) * 256 +
      Interfaces.Unsigned_16(input(first + 5));
    record_header.padding_length := input(first + 6);

    if record_header.version /= VERSION_1 then
      return Unsupported_Version;
    end if;

    if not validate_request_id_domain (record_header) then
      return Invalid_Request_Id_Domain;
    end if;

    return Complete;
  end decode_header;

  function validate_request_id_domain
    (record_header : Header)
  return Boolean is
  begin
    if is_management_record (record_header.record_type) then
      return record_header.request_id = 0;
    end if;

    if is_application_record (record_header.record_type) then
      return record_header.request_id /= 0;
    end if;

    -- An unknown type is only meaningful as an unknown management record.
    -- FastCGI management records use the null request ID.
    return record_header.request_id = 0;
  end validate_request_id_domain;

end Fasyn.Protocol.Codec;
