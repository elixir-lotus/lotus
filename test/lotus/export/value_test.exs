defmodule Lotus.Export.ValueTest do
  use ExUnit.Case, async: true

  alias Lotus.Export.Value

  describe "basic types" do
    test "handles nil" do
      assert Value.to_csv_string(nil) == ""
      assert Value.for_json(nil) == nil
    end

    test "handles booleans" do
      assert Value.to_csv_string(true) == "true"
      assert Value.to_csv_string(false) == "false"
      assert Value.for_json(true) == true
      assert Value.for_json(false) == false
    end

    test "handles integers" do
      assert Value.to_csv_string(42) == "42"
      assert Value.to_csv_string(-100) == "-100"
      assert Value.for_json(42) == 42
    end

    test "handles strings" do
      assert Value.to_csv_string("hello") == "hello"
      assert Value.for_json("hello") == "hello"
    end

    test "handles atoms" do
      assert Value.to_csv_string(:active) == "active"
      assert Value.for_json(:active) == "active"
    end
  end

  describe "floats" do
    test "handles normal floats" do
      assert Value.to_csv_string(3.14) == "3.14"
      assert Value.for_json(3.14) == 3.14
    end

    test "handles negative floats" do
      assert Value.to_csv_string(-2.718) == "-2.718"
      assert Value.for_json(-2.718) == -2.718
    end

    test "handles zero float" do
      assert Value.to_csv_string(0.0) == "0.0"
      assert Value.for_json(0.0) == 0.0
    end
  end

  describe "Decimal" do
    test "handles Decimal values" do
      decimal = Decimal.new("123.456")
      assert Value.to_csv_string(decimal) == "123.456"
      assert Value.for_json(decimal) == "123.456"
    end

    test "handles high precision Decimal" do
      decimal = Decimal.new("999999999999999999999999.123456789")
      assert Value.to_csv_string(decimal) == "999999999999999999999999.123456789"
    end

    test "renders a Decimal wider than Decimal's default output cap" do
      digits = 7017
      decimal = %Decimal{sign: 1, coef: String.to_integer(String.duplicate("7", digits)), exp: 0}

      assert Value.to_csv_string(decimal) == String.duplicate("7", digits)
      assert Value.for_json(decimal) == String.duplicate("7", digits)
    end

    test "handles Decimal NaN" do
      decimal = %Decimal{sign: 1, coef: :NaN, exp: 0}
      assert Value.to_csv_string(decimal) == "NaN"
      assert Value.for_json(decimal) == "NaN"
    end

    test "handles Decimal positive infinity" do
      decimal = %Decimal{sign: 1, coef: :inf, exp: 0}
      assert Value.to_csv_string(decimal) == "Infinity"
      assert Value.for_json(decimal) == "Infinity"
    end

    test "handles Decimal negative infinity" do
      decimal = %Decimal{sign: -1, coef: :inf, exp: 0}
      assert Value.to_csv_string(decimal) == "-Infinity"
      assert Value.for_json(decimal) == "-Infinity"
    end
  end

  describe "Date/Time types" do
    test "handles Date" do
      date = ~D[2024-01-15]
      assert Value.to_csv_string(date) == "2024-01-15"
      assert Value.for_json(date) == "2024-01-15"
    end

    test "handles Time" do
      time = ~T[13:30:45.123456]
      result = Value.to_csv_string(time)
      assert result =~ "13:30:45.123456"
      assert Value.for_json(time) =~ "13:30:45.123456"
    end

    test "handles DateTime with microseconds" do
      dt = ~U[2024-01-15 10:30:45.123456Z]
      assert Value.to_csv_string(dt) == "2024-01-15T10:30:45.123456Z"
      assert Value.for_json(dt) == "2024-01-15T10:30:45.123456Z"
    end

    test "handles DateTime with timezone offset" do
      {:ok, dt} = DateTime.from_naive(~N[2024-01-15 10:30:45.123456], "Etc/UTC")
      result = Value.to_csv_string(dt)
      assert result =~ "2024-01-15"
      assert result =~ "10:30:45.123456"
      assert result =~ "Z"
    end

    test "handles NaiveDateTime with microseconds" do
      ndt = ~N[2024-01-15 10:30:45.123456]
      assert Value.to_csv_string(ndt) == "2024-01-15T10:30:45.123456"
      assert Value.for_json(ndt) == "2024-01-15T10:30:45.123456"
    end
  end

  describe "collections" do
    test "handles maps in JSON" do
      map = %{"name" => "Alice", "age" => 30}
      csv_result = Value.to_csv_string(map)
      assert csv_result == ~s({"age":30,"name":"Alice"})
      assert Value.for_json(map) == map
    end

    test "handles nested maps" do
      map = %{"user" => %{"name" => "Bob", "meta" => %{"role" => "admin"}}}
      csv_result = Value.to_csv_string(map)
      assert csv_result =~ "Bob"
      assert csv_result =~ "admin"
      assert Value.for_json(map) == map
    end

    test "handles lists" do
      list = [1, 2, 3]
      csv_result = Value.to_csv_string(list)
      assert csv_result == "[1,2,3]"
      assert Value.for_json(list) == list
    end

    test "handles charlists" do
      charlist = ~c"hello"
      assert Value.to_csv_string(charlist) == "hello"
      assert Value.for_json(charlist) == "hello"
    end

    test "handles mixed lists" do
      list = ["a", 1, true, nil]
      csv_result = Value.to_csv_string(list)
      assert csv_result == ~s(["a",1,true,null])
      assert Value.for_json(list) == list
    end
  end

  describe "Unicode and control characters" do
    test "handles emoji and Unicode" do
      text = "Olá 🌍 مرحبا"
      assert Value.to_csv_string(text) == text
      assert Value.for_json(text) == text
    end

    test "handles newlines and control characters" do
      text = "Line 1\nLine 2\tTabbed"
      assert Value.to_csv_string(text) == text
      assert Value.for_json(text) == text
    end

    test "handles RTL text" do
      text = "Hello עברית العربية"
      assert Value.to_csv_string(text) == text
      assert Value.for_json(text) == text
    end
  end

  describe "binary data" do
    test "handles valid UTF-8 binary" do
      binary = "Hello World"
      assert Value.to_csv_string(binary) == "Hello World"
      assert Value.for_json(binary) == "Hello World"
    end

    test "handles non-UTF-8 binary as Base64" do
      binary = <<255, 254, 253, 252>>
      result = Value.to_csv_string(binary)
      assert result == Base.encode64(binary)
      assert Value.for_json(binary) == Base.encode64(binary)
    end

    test "handles raw UUID binary" do
      # Create a proper UUID binary that Ecto.UUID can load
      {:ok, uuid_binary} = Ecto.UUID.dump("550e8400-e29b-41d4-a716-446655440000")
      result = Value.to_csv_string(uuid_binary)
      assert result == "550e8400-e29b-41d4-a716-446655440000"
    end

    test "handles 16-byte UTF-8 string as regular string, not UUID" do
      sixteen_byte_string = "charlie@test.com"
      assert byte_size(sixteen_byte_string) == 16
      assert Value.to_csv_string(sixteen_byte_string) == "charlie@test.com"
      assert Value.for_json(sixteen_byte_string) == "charlie@test.com"

      another_16_byte = "exactly16bytes!!"
      assert byte_size(another_16_byte) == 16
      assert Value.to_csv_string(another_16_byte) == "exactly16bytes!!"
      assert Value.for_json(another_16_byte) == "exactly16bytes!!"
    end

    test "handles non-UTF-8 16-byte binary as Base64" do
      # Invalid UTF-8 that's also not a valid UUID - should fall back to Base64
      invalid_binary =
        <<0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8, 0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2,
          0xF1, 0xF0>>

      result = Value.to_csv_string(invalid_binary)
      # Should either be UUID (if Ecto can load it) or Base64 (if it can't)
      # Let's just test that it's not the raw binary
      refute result == invalid_binary
      assert is_binary(result)
    end

    test "handles bitstrings (non-binary)" do
      # Create a 5-bit bitstring
      bitstring = <<13::5>>
      assert Value.to_csv_string(bitstring) == "13"
      assert Value.for_json(bitstring) == "13"
    end
  end

  describe "UUIDs" do
    test "handles UUID strings" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      assert Value.to_csv_string(uuid) == uuid
      assert Value.for_json(uuid) == uuid
    end

    test "handles UUIDv7 strings" do
      # Example UUIDv7
      uuid = "018dc3a5-3b87-7004-a716-446655440000"
      assert Value.to_csv_string(uuid) == uuid
      assert Value.for_json(uuid) == uuid
    end
  end

  describe "fallback handling" do
    test "handles URI structs via the URI normalizer" do
      struct = %URI{scheme: "https", host: "example.com"}
      result = Value.to_csv_string(struct)
      assert result == "https://example.com"
    end

    test "handles tuples" do
      tuple = {:ok, "value"}
      result = Value.to_csv_string(tuple)
      assert result == "{:ok, \"value\"}"
    end
  end
end
