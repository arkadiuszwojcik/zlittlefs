const std = @import("std");
const c = @cImport({
    @cInclude("lfs_util.h");
    @cInclude("lfs.h");
});

const build_options = @import("lfs_build_options");

pub const LfsGlobalError = error{
    IoErr,
    CorruptErr,
    NoDirEntry,
    EntryAlreadyExists,
    EntryNotDir,
    EntryIsDir,
    NotEmpty,
    BadFileNumber,
    FileTooLarge,
    InvalidParam,
    NoSpace,
    NoMemory,
    NoAttribute,
    FileNameTooLong,
};

inline fn mapGenericError(code: c.lfs_error) LfsGlobalError!void {
    return switch (code) {
        c.LFS_ERR_OK => {},
        c.LFS_ERR_IO => error.IoErr,
        c.LFS_ERR_CORRUPT => error.CorruptErr,
        c.LFS_ERR_NOENT => error.NoDirEntry,
        c.LFS_ERR_EXIST => error.EntryAlreadyExists,
        c.LFS_ERR_NOTDIR => error.EntryNotDir,
        c.LFS_ERR_ISDIR => error.EntryIsDir,
        c.LFS_ERR_NOTEMPTY => error.NotEmpty,
        c.LFS_ERR_BADF => error.BadFileNumber,
        c.LFS_ERR_FBIG => error.FileTooLarge,
        c.LFS_ERR_INVAL => error.InvalidParam,
        c.LFS_ERR_NOSPC => error.NoSpace,
        c.LFS_ERR_NOMEM => error.NoMemory,
        c.LFS_ERR_NOATTR => error.NoAttribute,
        c.LFS_ERR_NAMETOOLONG => error.FileNameTooLong,
        else => unreachable,
    };
}

pub inline fn throw(error_code: c_int) LfsGlobalError!void {
    return mapGenericError(error_code);
}

const lfs_global = struct {
    pub const name_max = build_options.lfs_name_max;
};

pub const Kind = enum {
    unknown,
    file,
    directory,
};

pub const OpenMode = enum(u2) {
    read_only  = 1,
    write_only = 2,
    read_write = 3,
};

pub const OpenFlags = packed struct(u32) {
    mode: OpenMode = .read_only,
    reserved1: u6 = 0,
    create: bool = false,     // Create a file if it does not exist
    exclusive: bool = false,  // Fail if a file already exists
    truncate: bool = false,   // Truncate the existing file to zero size
    append: bool = false,     // Move to end of file on every write
    reserved2: u20 = 0,
};

pub const SeekMode = enum(u8) {
    set  = 0,  // Seek relative to an absolute position
    curr = 1,  // Seek relative to the current file position
    end  = 2   // Seek relative to the end of the file
};

pub fn FixedBufferStorage(comptime block_num: u32, comptime block_size: u32) type {
    return struct { 
        const Self = @This();
        storage: [block_num * block_size]u8 = undefined,

        read_size: u32 = 16,
        prog_size: u32 = 16,

        block_size: u32 = block_size,
        block_count: u32 = block_num,
        block_cycles: i32 = -1,

        fn read(self: *Self, block: u32, off: u32, buffer: []u8) i32 {
            const start = block_size * block + off;
            const end = start + buffer.len;
            @memcpy(buffer, self.storage[start .. end]);
            return 0;
        }

        fn prog(self: *Self, block: u32, off: u32, buffer: []const u8) i32 {
            const start = block_size * block + off;
            const end = start + buffer.len;
            @memcpy(self.storage[start .. end], buffer[0..buffer.len]);
            return 0;
        }

        fn erase(self: *Self, block: u32) i32 {
            const start = block_size * block;
            const end = start + block_size;
            @memset(self.storage[start..end], 0);
            return 0;
        }

        fn sync(_: *Self) i32 {
            return 0;
        }
    };
}

pub const LfsOptions = struct {
    cache_size: u32 = 16,
    lookahead_size: u32 = 16,
    prealloc_max_open_dirs: u32 = 4,
    prealloc_max_open_files: u32 = 4
};

pub fn LfsFileSystem(comptime storage_type: type, comptime prealloc: bool) type {
    return struct {
        const Self = @This();
        const DirMemPool = std.heap.MemoryPoolExtra(c.lfs_dir_t, .{ .alignment = null, .growable = if (prealloc) false else true });
        const FileMemPool = std.heap.MemoryPoolExtra(c.lfs_file_t, .{ .alignment = null, .growable = if (prealloc) false else true });
        const FileCfgMemPool = std.heap.MemoryPoolExtra(c.lfs_file_config, .{ .alignment = null, .growable = if (prealloc) false else true });

        storage: *storage_type = undefined,
        cfg: c.lfs_config = undefined,
        allocator: std.mem.Allocator = undefined,

        read_cache: []u8 = undefined,
        prog_cache: []u8 = undefined,
        lookahead_cache: []u8 = undefined,

        fs: ?c.lfs_t = null,

        dir_pool: DirMemPool = undefined,
        file_pool: FileMemPool = undefined,
        filecfg_pool: FileCfgMemPool = undefined,

        pub fn init(self: *Self, allocator: std.mem.Allocator, storage: *storage_type, options: LfsOptions) !void {
            self.allocator = allocator;
            self.storage = storage;

            self.read_cache = try allocator.alloc(u8, options.cache_size);
            self.prog_cache = try allocator.alloc(u8, options.cache_size);
            self.lookahead_cache = try allocator.alloc(u8, options.lookahead_size);

            self.cfg = .{
                .context = @ptrCast(@constCast(storage)),
                .read = lfs_read,
                .prog = lfs_prog,
                .erase = lfs_erase,
                .sync = lfs_sync,

                .read_size = storage.read_size,
                .prog_size = storage.prog_size,

                .block_size = storage.block_size,
                .block_count = storage.block_count,
                .block_cycles = storage.block_cycles,

                .cache_size = @truncate(self.read_cache.len),
                .lookahead_size = @truncate(self.lookahead_cache.len),

                .read_buffer = self.read_cache.ptr,
                .prog_buffer = self.prog_cache.ptr,
                .lookahead_buffer = self.lookahead_cache.ptr
            };

            self.dir_pool = if (prealloc) try DirMemPool.initPreheated(allocator, options.prealloc_max_open_dirs) else try DirMemPool.init(allocator);
            self.file_pool = if (prealloc) try FileMemPool.initPreheated(allocator, options.prealloc_max_open_files) else try FileMemPool.init(allocator);
            self.filecfg_pool = if (prealloc) try FileCfgMemPool.initPreheated(allocator, options.prealloc_max_open_files) else try FileCfgMemPool.init(allocator);
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.read_cache);
            self.allocator.free(self.prog_cache);
            self.allocator.free(self.lookahead_cache);
            self.dir_pool.deinit();
            self.file_pool.deinit();
            self.filecfg_pool.deinit();
        }

        pub fn format(self: *Self) LfsGlobalError!void {
            var fs = c.lfs_t {};
            try throw(c.lfs_format(&fs, &self.cfg));
        }

        pub fn mount(self: *Self) LfsGlobalError!void {
            std.debug.assert(self.fs == null);
            self.fs = .{};
            try throw(c.lfs_mount(&self.fs.?, &self.cfg));
        }

        pub fn unmount(self: *Self) LfsGlobalError!void {
            std.debug.assert(self.fs != null);
            try throw(c.lfs_unmount(&self.fs.?));
            self.fs = null;
        }

        pub fn open_dir(self: *Self, sub_path: [:0]const u8) LfsGlobalError!Dir {
            const dir = self.dir_pool.create() catch return LfsGlobalError.NoMemory;
            errdefer self.dir_pool.destroy(dir);
            // TODO: do we have to zero dir struct? if littlefs is not doing it we have to do it.

            try throw(c.lfs_dir_open(&self.fs.?, dir, sub_path.ptr));
            return .{ .fs = self, .dir_handle = dir };
        }

        pub fn close_dir(self: *Self, dir: *Dir) void {
            _ = c.lfs_dir_close(&self.fs.?, dir.dir_handle);
            self.dir_pool.destroy(dir.dir_handle);
        }

        pub fn open_file(self: *Self, sub_path: [:0]const u8, flags: OpenFlags, allocator: std.mem.Allocator) LfsGlobalError!File {
            const file = self.file_pool.create() catch return LfsGlobalError.NoMemory;
            errdefer self.file_pool.destroy(file);
            // TODO: do we have to zero file struct? if littlefs is not doing it we have to do it.

            const file_cfg = self.filecfg_pool.create() catch return LfsGlobalError.NoMemory;
            errdefer self.filecfg_pool.destroy(file_cfg);
            file_cfg.* = std.mem.zeroes(c.lfs_file_config);

            const file_cache = allocator.alloc(u8, self.read_cache.len) catch return LfsGlobalError.NoMemory;
            errdefer allocator.free(file_cache);

            file_cfg.buffer = file_cache.ptr;
            try throw(c.lfs_file_opencfg(&self.fs.?, file, sub_path.ptr, @bitCast(flags), file_cfg));

            return File { .fs = self, .file_handle = file, .file_cfg_handle = file_cfg, .file_cache = file_cache };
        }

        pub fn close_file(self: *Self, file: *File, allocator: std.mem.Allocator) LfsGlobalError!void {
            try throw (c.lfs_file_close(&self.fs.?, file.file_handle));
            allocator.free(file.file_cache);
            self.file_pool.destroy(file.file_handle);
            self.filecfg_pool.destroy(file.file_cfg_handle);
        }

        pub fn sync_file(self: *Self, file: *File) LfsGlobalError!void {
            try throw(c.lfs_file_sync(&self.fs.?, file.file_handle));
        }

        pub fn mkdir(self: *Self, sub_path: [:0]const u8) LfsGlobalError!void {
            try throw(c.lfs_mkdir(&self.fs.?, sub_path.ptr));
        }

        pub fn cwd(self: *Self) LfsGlobalError!Dir {
            return try self.open_dir("/");
        }

        fn lfs_read(config: [*c]const c.lfs_config, block: u32, off: u32, buffer: ?*anyopaque, size: u32) callconv(.C) c_int {
            return @as(*storage_type, @ptrCast(@alignCast(config.*.context))).read(block, off, @as([*]u8, @ptrCast(buffer))[0..size]);
        }

        fn lfs_prog(config: [*c]const c.lfs_config, block: u32, off: u32, buffer: ?*const anyopaque, size: u32) callconv(.C) c_int {
            return @as(*storage_type, @ptrCast(@alignCast(config.*.context))).prog(block, off, @as([*]const u8, @ptrCast(buffer))[0..size]);
        }

        fn lfs_erase(config: [*c]const c.lfs_config, block: u32) callconv(.C) c_int {
            return @as(*storage_type, @ptrCast(@alignCast(config.*.context))).erase(block);
        }

        fn lfs_sync(config: [*c]const c.lfs_config) callconv(.C) c_int {
            return @as(*storage_type, @ptrCast(@alignCast(config.*.context))).sync();
        }

        const Dir = struct {
            const DirSelf = @This();
            fs: *Self,
            dir_handle: *c.lfs_dir_t,

            pub fn close(self: *DirSelf) void {
                self.fs.close_dir(self);
            }

            pub fn mkdir(self: *DirSelf, sub_path: [:0]const u8) LfsGlobalError!void {
                return self.fs.mkdir(sub_path);
            }

            pub fn walk_flat(self: *DirSelf) LfsGlobalError!WalkerFlat {
                try throw(c.lfs_dir_rewind(&self.fs.fs.?, self.dir_handle));
                return WalkerFlat { .dir = self };
            }

            pub fn open_file(self: *DirSelf, sub_path: [:0]const u8, flags: OpenFlags, allocator: std.mem.Allocator) LfsGlobalError!File {
                return try self.fs.open_file(sub_path, flags, allocator);
            }
        };

        const File = struct {
            const FileSelf = @This();
            fs: *Self,
            file_handle: *c.lfs_file_t,
            file_cfg_handle: *c.lfs_file_config,
            file_cache: []u8,

            pub fn close(self: *FileSelf, allocator: std.mem.Allocator) LfsGlobalError!void {
                return self.fs.close_file(self, allocator);
            }

            pub fn sync(self: *FileSelf) LfsGlobalError!void {
                return self.fs.sync_file(self);
            }

            // TODO: examine max write chunk size, if necessary create new api with loop that will write entire buffer
            pub fn write(self: *FileSelf, buffer: []const u8) LfsGlobalError!usize {
                const write_result = c.lfs_file_write(&self.fs.fs.?, self.file_handle, buffer.ptr, @truncate(buffer.len));
                if (write_result < 0) {
                    try mapGenericError(write_result);
                    unreachable;
                }
                return @intCast(write_result);
            }

            // TODO: examine max read chunk size, if necessary create new api with loop that will fill entire buffer
            pub fn read(self: *FileSelf, buffer: []u8) LfsGlobalError!usize {
                const read_result = c.lfs_file_read(&self.fs.fs.?, self.file_handle, buffer.ptr, @truncate(buffer.len));
                if (read_result < 0) {
                    try mapGenericError(read_result);
                    unreachable;
                }
                return @intCast(read_result);
            }

            pub fn seek(self: *FileSelf, offset: i32, mode: SeekMode) LfsGlobalError!usize {
                const seek_result =c.lfs_file_seek(&self.fs.fs.?, self.file_handle, offset, @intFromEnum(mode));
                if (seek_result < 0) {
                    try mapGenericError(seek_result);
                    unreachable;
                }
                return @intCast(seek_result);
            }
        };

        pub const WalkerFlat = struct {
            pub const Entry = struct {
                basename: []const u8,
                kind: Kind,
                file_size: ?u32
            };

            dir: *Dir,
            info: c.lfs_info = undefined,

            pub fn next(self: *WalkerFlat) LfsGlobalError!?WalkerFlat.Entry {
                const read_result = c.lfs_dir_read(&self.dir.fs.fs.?, self.dir.dir_handle, &self.info);
                if (read_result == 0) {
                    return null;
                } else if (read_result < 0) {
                    try mapGenericError(read_result);
                    unreachable;
                }

                const kind = switch (self.info.type) {
                    c.LFS_TYPE_REG => Kind.file,
                    c.LFS_TYPE_DIR => Kind.directory,
                    else => Kind.unknown
                };

                const file_size: ?u32 = if (kind == Kind.file) self.info.size else null;
                const name: [*:0]const u8 = @alignCast(@ptrCast(&self.info.name));
                const name_span = std.mem.span(name);
                
                return Entry { .kind = kind, .file_size = file_size, .basename = name_span };
            }
        };
    };
}