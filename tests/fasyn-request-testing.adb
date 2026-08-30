-- ============================================================================
-- fasyn-request-testing.adb
-- Copyright (c) 2023-2026 Hodong Kim <hodong@nimfsoft.com>
-- ============================================================================
package body Fasyn.Request.Testing is

  function output_length (self : Writer) return Natural is
  begin
    return self.length;
  end output_length;

  function output_byte
    (self  : Writer;
     index : Positive)
  return Fasyn.Protocol.Byte is
  begin
    if index > self.length then
      raise Constraint_Error with "request output byte index out of range";
    end if;

    return self.bytes(index);
  end output_byte;

end Fasyn.Request.Testing;
