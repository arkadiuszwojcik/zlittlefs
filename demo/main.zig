const std = @import("std");
const builtin = @import("builtin");
pub const littlefs = @import("zlittlefs");

pub fn main() !void {
    std.debug.print("======== zLittleFS demo ========\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    // Create FixedBufferStorage (in-memory storage) type
    const storage_type = littlefs.FixedBufferStorage(128, 4096);
    var storage: storage_type = .{};

    // Create LfsFileSystem type based on storage type and with prealloc feature
    const lfs_type = littlefs.LfsFileSystem(storage_type, true);
    var fs: lfs_type = .{};

    // Initialize file system (prealloc all internal resources)
    try fs.init(gpa.allocator(),&storage, .{});
    defer fs.deinit();

    // Format storage and prepare lfs internal structure
    try fs.format();

    // Mount file system
    try fs.mount();
    defer fs.unmount() catch unreachable;

    // Get root directory and create some other dirs
    var root_dir = try fs.cwd();
    try root_dir.mkdir("dir1");
    try root_dir.mkdir("dir2");
    try root_dir.mkdir("dir3");
    try root_dir.mkdir("dir1/sub_dir1");
    try root_dir.mkdir("dir1/sub_dir2");

    // Writing to file
    const text1 = "This is some text that we will write to file.";
    std.debug.print("1. File: {s} - writing text: {s}\n", .{"test_file.txt", text1});
    var file1 = try root_dir.open_file("test_file.txt", .{ .mode = .write_only, .create = true }, gpa.allocator());
    _ = try file1.write(text1);
    try file1.close(gpa.allocator());

    // Appending to file
    const text2 = "This is another text that we will append to file.";
    std.debug.print("2. File: {s} - appending text: {s}\n", .{"test_file.txt", text2});
    var file2 = try root_dir.open_file("test_file.txt", .{ .mode = .write_only, .create = false, .append = true }, gpa.allocator());
    _ = try file2.write(text2);
    try file2.close(gpa.allocator());

    // Reading from file
    var text_buff: [100]u8 = undefined;
    var file3 = try root_dir.open_file("test_file.txt", .{ .mode = .read_only, .create = false }, gpa.allocator());
    const read_size = try file3.read(&text_buff);
    const read_str = text_buff[0..read_size];
    std.debug.print("3. File: {s} - content: {s}\n", .{"test_file.txt", read_str});
    try file3.close(gpa.allocator());

    std.debug.print("\n\n", .{});
    std.debug.print("------- root dir structure -------\n", .{});

    var walker = try root_dir.walk_flat();
    while (try walker.next()) |info| {
        std.debug.print("Name: {s} Type: {s} Size: {d}\n", .{info.basename, type_to_name(info.kind), if (info.file_size) |size| size else 0});
    }

    std.debug.print("----------------------------------\n", .{});
}

pub fn type_to_name(kind: littlefs.Kind) []const u8 {
    return switch (kind) {
        .file => "File",
        .directory => "Directory",
        else => "Unknown"
    };
}

export fn foundation_libc_assert(
    assertion: ?[*:0]const u8,
    file: ?[*:0]const u8,
    line: c_uint,
) noreturn {
    switch (builtin.mode) {
        .Debug, .ReleaseSafe => {
            var buf: [256]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "assertion failed: '{?s}' in file {?s} line {}", .{ assertion, file, line }) catch {
                @panic("assertion failed");
            };
            @panic(str);
        },
        .ReleaseSmall => @panic("assertion failed"),
        .ReleaseFast => unreachable,
    }
}