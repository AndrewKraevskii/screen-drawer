const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("raylib").Image;
const rl = @import("raylib");

const log = std.log.scoped(.storage);

gpa: Allocator,
save_directory: std.fs.Dir,
images: Storage,
textures: std.AutoArrayHashMapUnmanaged(usize, rl.Texture),

thread_pool: std.Thread.Pool,
mutex: std.Thread.Mutex,
should_thread_quit: bool,

const Storage = std.StringArrayHashMapUnmanaged(?Image);

pub fn init(
    gpa: Allocator,
    save_path: []const u8,
) !@This() {
    var dir = try std.fs.openDirAbsolute(save_path, .{
        .iterate = true,
    });
    errdefer dir.close();
    var iter = dir.iterateAssumeFirstIteration();
    var images = Storage{};

    while (try iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, std.fs.path.extension(entry.name), ".qoi")) continue;

        try images.put(gpa, gpa.dupe(u8, entry.name) catch @panic("OOM"), null);
    }

    return .{
        .thread_pool = undefined,
        .textures = .{},
        .gpa = gpa,
        .images = images,
        .save_directory = dir,
        .mutex = .{},
        .should_thread_quit = false,
    };
}

pub fn startLoading(storage: *@This()) !void {
    try storage.thread_pool.init(.{
        .allocator = storage.gpa,
    });
}

pub fn deinit(storage: *@This()) void {
    {
        storage.flushFilesOnDisc();
        storage.mutex.lock();
        defer storage.mutex.unlock();
        storage.should_thread_quit = true;

        for (storage.images.keys()) |key|
            storage.gpa.free(key);
        for (storage.images.values()) |maybe_image| if (maybe_image) |image|
            image.unload();
        storage.images.deinit(storage.gpa);
        for (storage.textures.values()) |texture|
            texture.unload();
        storage.textures.deinit(storage.gpa);
        storage.save_directory.close();
    }
    storage.thread_pool.deinit();
}

fn flushFilesOnDisc(storage: *@This()) void {
    for (storage.images.keys(), storage.images.values()) |name, maybe_image| {
        const image = maybe_image orelse continue;
        storage.thread_pool.spawn(flushFileOnDisc, .{ storage, name, image }) catch @panic("Export error");
        storage.flushFileOnDisc(name, image);
    }
}
fn flushFileOnDisc(storage: *@This(), name: []const u8, image: rl.Image) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = @as([:0]u8, @ptrCast(storage.save_directory.realpath(name, &buffer) catch @panic("Export error")));
    path[path.len] = 0;
    _ = image.exportToFile(path);
}

pub fn loaded(storage: *@This()) usize {
    storage.mutex.lock();
    defer storage.mutex.unlock();

    var counter: usize = 0;
    for (storage.images.entries.items(.value)) |image| {
        if (image != null) counter += 1;
    }
    return counter;
}

pub fn len(storage: *@This()) usize {
    return storage.images.entries.len;
}

/// Returns image if loaded. If not loaded puts it in load queue.
/// Asserts index is less then storage.len();
pub fn getImage(storage: *@This(), index: usize) error{OutOfRange}!?Image {
    var changed = false;
    storage.mutex.lock();
    defer {
        storage.mutex.unlock();
    }

    // log.debug("{any}", .{storage.load_queue.items});
    if (index >= storage.len()) return error.OutOfRange;
    const small_index = std.math.cast(u32, index) orelse return error.OutOfRange;
    return storage.images.values()[small_index] orelse {
        storage.thread_pool.spawn(loaderThread, .{ storage, small_index }) catch @panic("adfasfsf");
        log.info("{d} appended to queue", .{small_index});
        changed = true;
        return null;
    };
}

pub fn setTexture(storage: *@This(), index: usize, texture: rl.Texture) !void {
    const gop = try storage.textures.getOrPut(storage.gpa, index);
    if (gop.found_existing) {
        gop.value_ptr.unload();
    }
    const image = rl.Image.fromTexture(texture);
    gop.value_ptr.* = rl.Texture.fromImage(image);
    storage.mutex.lock();
    defer storage.mutex.unlock();
    if (storage.images.values()[index]) |old_image| {
        old_image.unload();
    }
    storage.images.values()[index] = image;
}

pub fn getTexture(storage: *@This(), index: usize) !?rl.Texture {
    if (storage.textures.get(index)) |texture|
        return texture;

    const image = try storage.getImage(index) orelse return null;
    const texture = rl.Texture.fromImage(image);
    try storage.textures.put(storage.gpa, index, texture);
    return texture;
}

fn loaderThread(storage: *@This(), index: u32) void {
    storage.mutex.lock();
    var images_slice = storage.images.values();
    if (images_slice[index] != null) {
        storage.mutex.unlock();
        return;
    }

    const file_name = storage.images.keys()[index];
    storage.mutex.unlock();

    const image_encoded = storage.save_directory.readFileAllocOptions(storage.gpa, file_name, 1024 * 1024 * 1024, 10 * 1024 * 1024, 1, 0) catch |e| {
        @panic(@errorName(e));
    };
    defer storage.gpa.free(image_encoded);

    const image = rl.loadImageFromMemory(".qoi", image_encoded);
    log.info("Loaded image size of {d}x{d}", .{ image.width, image.height });
    storage.mutex.lock();
    images_slice[index] = image;
    defer storage.mutex.unlock();
}
