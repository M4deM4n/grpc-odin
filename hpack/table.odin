package hpack

import "base:runtime"

// Dynamic_Table is the HPACK dynamic table (RFC 7541 §2.3.2, §4).
//
// All storage is allocated once by table_init for the given capacity (the
// largest maximum size the table may ever be set to):
//   - `entries` is a ring of entry descriptors, newest first by index;
//   - `data` holds the name/value octets of live entries, appended in
//     insertion order. Because eviction always removes the oldest entry, the
//     live octets form one contiguous region [data_start, data_end), which is
//     compacted to the front of `data` when it runs out of tail room.
Dynamic_Table :: struct {
	entries:    []Table_Entry,
	newest:     int, // ring index of the most recently inserted entry
	count:      int,
	data:       []u8,
	data_start: int,
	data_end:   int,
	size:       int, // RFC 7541 size: sum of entry_size of live entries
	max_size:   int, // current maximum, <= capacity
	capacity:   int,
	allocator:  runtime.Allocator,
}

Table_Entry :: struct {
	offset:    u32,
	name_len:  u32,
	value_len: u32,
}

table_init :: proc(t: ^Dynamic_Table, capacity: int, allocator := context.allocator) -> Error {
	assert(capacity >= 0 && capacity <= MAX_INTEGER)
	t^ = {}
	t.allocator = allocator
	t.capacity = capacity
	t.max_size = capacity
	// Every entry costs at least ENTRY_OVERHEAD, bounding the entry count.
	max_entries := capacity / ENTRY_OVERHEAD + 1
	entries, e_err := make([]Table_Entry, max_entries, allocator)
	if e_err != nil {
		return .Out_Of_Memory
	}
	// Live octets never exceed `capacity`; doubling the buffer makes
	// compaction rare (amortised O(1) per inserted octet).
	data, d_err := make([]u8, max(capacity * 2, 1), allocator)
	if d_err != nil {
		delete(entries, allocator)
		return .Out_Of_Memory
	}
	t.entries = entries
	t.data = data
	return .None
}

table_destroy :: proc(t: ^Dynamic_Table) {
	delete(t.entries, t.allocator)
	delete(t.data, t.allocator)
	t^ = {}
}

// table_get returns the entry at 1-based dynamic index i (1 is the newest).
// The returned strings alias table storage and are invalidated by the next
// insertion or size change.
table_get :: proc(t: ^Dynamic_Table, i: int) -> (field: Header_Field, ok: bool) {
	if i < 1 || i > t.count {
		return {}, false
	}
	e := t.entries[ring_index(t, i)]
	base := int(e.offset)
	name_end := base + int(e.name_len)
	field.name = string(t.data[base:name_end])
	field.value = string(t.data[name_end:name_end + int(e.value_len)])
	return field, true
}

// table_set_max_size applies a dynamic table size update, evicting entries
// as needed. Callers validate new_max against the negotiated limit.
table_set_max_size :: proc(t: ^Dynamic_Table, new_max: int) {
	assert(new_max >= 0 && new_max <= t.capacity)
	t.max_size = new_max
	evict_until_fits(t, 0)
}

// table_insert adds a field as the newest entry (RFC 7541 §4.4). Entries
// larger than the maximum size empty the table and are not inserted.
//
// name and value must not alias the table's own storage (callers copy names
// referenced by index first), since eviction may reuse that memory.
table_insert :: proc(t: ^Dynamic_Table, name, value: string) {
	needed := entry_size(name, value)
	if needed > t.max_size {
		table_clear(t)
		return
	}
	evict_until_fits(t, needed)

	n := len(name) + len(value)
	if t.data_end + n > len(t.data) {
		// Compact the live region to the front. It fits because live octets
		// plus the new entry are bounded by max_size <= capacity <= len(data).
		live := t.data_end - t.data_start
		copy(t.data[:live], t.data[t.data_start:t.data_end])
		shift := t.data_start
		for k in 0 ..< t.count {
			idx := (t.newest - k + len(t.entries)) % len(t.entries)
			t.entries[idx].offset -= u32(shift)
		}
		t.data_start = 0
		t.data_end = live
	}
	if t.count == 0 {
		t.data_start = 0
		t.data_end = 0
	}
	offset := t.data_end
	copy(t.data[offset:], name)
	copy(t.data[offset + len(name):], value)
	t.data_end += n

	t.newest = (t.newest + 1) % len(t.entries)
	t.entries[t.newest] = {u32(offset), u32(len(name)), u32(len(value))}
	t.count += 1
	t.size += needed
}

table_clear :: proc "contextless" (t: ^Dynamic_Table) {
	t.count = 0
	t.size = 0
	t.data_start = 0
	t.data_end = 0
}

// table_aliases reports whether s points into the table's storage.
table_aliases :: proc "contextless" (t: ^Dynamic_Table, s: string) -> bool {
	if len(s) == 0 || len(t.data) == 0 {
		return false
	}
	p := uintptr(raw_data(s))
	lo := uintptr(raw_data(t.data))
	return p >= lo && p < lo + uintptr(len(t.data))
}

@(private)
ring_index :: #force_inline proc "contextless" (t: ^Dynamic_Table, i: int) -> int {
	return (t.newest - (i - 1) + len(t.entries)) % len(t.entries)
}

@(private)
evict_until_fits :: proc "contextless" (t: ^Dynamic_Table, extra: int) {
	for t.count > 0 && t.size + extra > t.max_size {
		oldest := t.entries[ring_index(t, t.count)]
		n := int(oldest.name_len) + int(oldest.value_len)
		t.size -= n + ENTRY_OVERHEAD
		t.data_start = int(oldest.offset) + n
		t.count -= 1
	}
	if t.count == 0 {
		t.data_start = 0
		t.data_end = 0
	}
}
