const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

const log = std.log.scoped(.storage);

gpa: Allocator,
save_directory: std.fs.Dir,
images: Storage,

thread_pool: *std.Thread.Pool,
mutex: std.Thread.Mutex,

const Storage = std.StringArrayHashMapUnmanaged(ImageData);

const ImageData = struct {
    /// Image needs to be saved on disc
    dirty: bool = false,
    /// image is loading or unloading
    processing: enum {
        loading,
        saving,
        none,
    } = .none,

    image: ?rl.Image = null,
    texture: ?rl.Texture = null,
};

pub fn init(
    gpa: Allocator,
    thead_pool: *std.Thread.Pool,
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

        try images.put(gpa, gpa.dupe(u8, entry.name) catch @panic("OOM"), .{});
    }

    return .{
        .thread_pool = thead_pool,
        .gpa = gpa,
        .images = images,
        .save_directory = dir,
        .mutex = .{},
    };
}

pub fn deinit(storage: *@This()) void {
    {
        storage.mutex.lock();
        defer storage.mutex.unlock();

        storage.flushFilesOnDisc();

        for (storage.images.keys()) |key|
            storage.gpa.free(key);
        for (storage.images.values()) |image_data| {
            std.debug.assert(image_data.dirty == false);
            if (image_data.image) |image| image.unload();
            if (image_data.texture) |texture| texture.unload();
        }
        storage.images.deinit(storage.gpa);

        storage.save_directory.close();
    }
}

fn flushFilesOnDisc(storage: *@This()) void {
    var wait_group = std.Thread.WaitGroup{};
    for (storage.images.keys(), storage.images.values()) |name, *image_data| {
        log.debug("considering saving {s}", .{name});
        std.debug.assert(!(image_data.dirty and image_data.image == null));
        if (!image_data.dirty) continue;
        const image = image_data.image.?;
        storage.thread_pool.spawnWg(&wait_group, flushFileOnDisc, .{ storage, name, image });
        image_data.dirty = false;
    }
    wait_group.wait();
}

fn flushFileOnDisc(storage: *@This(), name: []const u8, image: rl.Image) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = @as([:0]u8, @ptrCast(storage.save_directory.realpath(name, &buffer) catch @panic("Export error")));
    path[path.len] = 0;
    _ = image.exportToFile(path);
    log.info("saved {s}", .{path});
}

pub fn len(storage: *@This()) usize {
    return storage.images.entries.len;
}

/// Returns image if loaded. And if not starts loading in background.
/// Asserts index is less then storage.len().
pub fn getImage(storage: *@This(), index: usize) ?rl.Image {
    std.debug.assert(index < storage.len());

    const image_data = &storage.images.values()[index];
    if (image_data.image) |image| return image;

    if (image_data.processing != .loading) {
        image_data.processing = .loading;
        storage.thread_pool.spawn(loaderThread, .{ storage, index }) catch @panic("can't spawn thread");
    }
    return null;
}

pub fn setTexture(storage: *@This(), index: usize, texture: rl.Texture) !void {
    var new_image = rl.Image.fromTexture(texture);
    new_image.flipVertical();

    storage.mutex.lock();
    defer storage.mutex.unlock();
    const image_data = &storage.images.values()[index];
    if (image_data.texture) |old_texture| {
        std.debug.assert(old_texture.id != texture.id);
        old_texture.unload();
    }
    if (image_data.image) |old_image| {
        old_image.unload();
    }
    image_data.texture = null;
    image_data.image = new_image;
    image_data.dirty = true;
}

pub fn getTexture(storage: *@This(), index: usize) ?rl.Texture {
    storage.mutex.lock();
    defer storage.mutex.unlock();

    const image_data = &storage.images.values()[index];
    if (image_data.texture) |texture|
        return texture;

    const image = storage.getImage(index) orelse return null;
    image_data.texture = rl.Texture.fromImage(image);
    return image_data.texture;
}

fn loaderThread(storage: *@This(), index: usize) void {
    storage.mutex.lock();
    var image_data = &storage.images.values()[index];
    const file_name = storage.images.keys()[index];
    std.debug.assert(image_data.image == null);
    std.debug.assert(image_data.processing == .loading);
    storage.mutex.unlock();

    const image_encoded = storage.save_directory.readFileAllocOptions(storage.gpa, file_name, 1024 * 1024 * 1024, 10 * 1024 * 1024, 1, 0) catch |e| {
        @panic(@errorName(e));
    };
    defer storage.gpa.free(image_encoded);

    const image = rl.loadImageFromMemory(".qoi", image_encoded);
    log.info("Loaded image size of {d}x{d}", .{ image.width, image.height });
    storage.mutex.lock();
    image_data.image = image;
    image_data.processing = .none;
    defer storage.mutex.unlock();
}
