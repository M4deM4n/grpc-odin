package protoc

// Embedded_Source is a .proto file compiled into odin-protoc so that imports
// of common well-known types resolve without a protobuf include directory.
Embedded_Source :: struct {
	path:   string,
	source: string,
}

// WELL_KNOWN_TYPES are the wire-compatible definitions of the
// google.protobuf well-known types used most often in gRPC APIs. Field
// names and numbers match the upstream definitions exactly.
WELL_KNOWN_TYPES := [?]Embedded_Source {
	{
		"google/protobuf/empty.proto",
		`syntax = "proto3";
package google.protobuf;
message Empty {}
`,
	},
	{
		"google/protobuf/timestamp.proto",
		`syntax = "proto3";
package google.protobuf;
message Timestamp {
  int64 seconds = 1;
  int32 nanos = 2;
}
`,
	},
	{
		"google/protobuf/duration.proto",
		`syntax = "proto3";
package google.protobuf;
message Duration {
  int64 seconds = 1;
  int32 nanos = 2;
}
`,
	},
	{
		"google/protobuf/wrappers.proto",
		`syntax = "proto3";
package google.protobuf;
message DoubleValue { double value = 1; }
message FloatValue { float value = 1; }
message Int64Value { int64 value = 1; }
message UInt64Value { uint64 value = 1; }
message Int32Value { int32 value = 1; }
message UInt32Value { uint32 value = 1; }
message BoolValue { bool value = 1; }
message StringValue { string value = 1; }
message BytesValue { bytes value = 1; }
`,
	},
	{
		"google/protobuf/any.proto",
		`syntax = "proto3";
package google.protobuf;
message Any {
  string type_url = 1;
  bytes value = 2;
}
`,
	},
	{
		"google/protobuf/field_mask.proto",
		`syntax = "proto3";
package google.protobuf;
message FieldMask {
  repeated string paths = 1;
}
`,
	},
	{
		"google/protobuf/struct.proto",
		`syntax = "proto3";
package google.protobuf;
message Struct {
  map<string, Value> fields = 1;
}
message Value {
  oneof kind {
    NullValue null_value = 1;
    double number_value = 2;
    string string_value = 3;
    bool bool_value = 4;
    Struct struct_value = 5;
    ListValue list_value = 6;
  }
}
enum NullValue {
  NULL_VALUE = 0;
}
message ListValue {
  repeated Value values = 1;
}
`,
	},
}
