const std = @import("std");
const Allocator = std.mem.Allocator;
const rl = @import("raylib");

const log = std.log.scoped(.storage);

gpa: Allocator,
save_directory: std.fs.Dir,
images: Storage,

thread_pool: *std.Thread.Pool,
mutex: std.Thread.Mutex,

const Storage = std.ArrayListUnmanaged(ImageData);

const ImageData = struct {
    file_name: []const u8,
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

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        alloc.free(self.file_name);
        if (self.image) |image| image.unload();
        if (self.texture) |texture| texture.unload();
    }
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

        try images.append(gpa, .{
            .file_name = gpa.dupe(u8, entry.name) catch @panic("OOM"),
        });
    }

    std.mem.sort(ImageData, images.items, {}, struct {
        pub fn lessThan(_: void, l: ImageData, r: ImageData) bool {
            return std.mem.lessThan(u8, l.file_name, r.file_name);
        }
    }.lessThan);

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

        for (storage.images.items) |*item| {
            std.debug.assert(item.dirty == false);
            item.deinit(storage.gpa);
        }
        storage.images.deinit(storage.gpa);

        storage.save_directory.close();
    }
}

fn flushFilesOnDisc(storage: *@This()) void {
    var wait_group = std.Thread.WaitGroup{};
    for (storage.images.items) |*image_data| {
        log.debug("considering saving {s}", .{image_data.file_name});
        std.debug.assert(!(image_data.dirty and image_data.image == null));
        if (!image_data.dirty) continue;
        const image = image_data.image.?;
        storage.thread_pool.spawnWg(&wait_group, flushFileOnDisc, .{ storage, image_data.file_name, image });
        image_data.dirty = false;
    }
    wait_group.wait();
}

fn flushFileOnDisc(storage: *@This(), name: []const u8, image: rl.Image) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = storage.save_directory.createFile(name, .{}) catch |e| {
        log.err("Failed to create a file {s}: {s}", .{ name, @errorName(e) });
        return;
    };
    file.close();
    const path = @as([:0]u8, @ptrCast(storage.save_directory.realpath(name, &buffer) catch |e| {
        log.err("Failed to get realpath {s}: {s}", .{ name, @errorName(e) });
        return;
    }));
    path[path.len] = 0;
    _ = image.exportToFile(path);
    log.info("saved {s}", .{path});
}

pub fn len(storage: *@This()) usize {
    return storage.images.items.len;
}

/// Returns image if loaded. And if not starts loading in background.
/// Asserts index is less then storage.len().
pub fn getImage(storage: *@This(), index: usize) ?rl.Image {
    std.debug.assert(index < storage.len());

    const image_data = &storage.images.items[index];
    if (image_data.image) |image| return image;

    if (image_data.processing != .loading) {
        image_data.processing = .loading;
        storage.thread_pool.spawn(loaderThread, .{ storage, index }) catch @panic("can't spawn thread");
    }
    return null;
}

pub fn addTexture(storage: *@This(), texture: rl.Texture) !void {
    const time: u128 = @abs(std.time.nanoTimestamp());

    var buffer: [100]u8 = undefined;

    const file_name = std.fmt.bufPrint(&buffer, "{d}.qoi", .{time}) catch unreachable;

    log.info("Named file {s}", .{file_name});
    storage.mutex.lock();
    try storage.images.append(storage.gpa, .{
        .file_name = storage.gpa.dupe(u8, file_name) catch @panic("OOM"),
    });
    storage.mutex.unlock();
    try storage.setTexture(storage.images.items.len - 1, texture);
    std.debug.assert(std.sort.isSorted(ImageData, storage.images.items, {}, struct {
        pub fn lessThan(_: void, l: ImageData, r: ImageData) bool {
            return std.mem.lessThan(u8, l.file_name, r.file_name);
        }
    }.lessThan));
}

pub fn remove(storage: *@This(), index: usize) !void {
    storage.mutex.lock();
    defer storage.mutex.unlock();
    if (storage.images.items[index].processing == .loading) {
        return;
    }
    var image = storage.images.orderedRemove(index);
    storage.save_directory.deleteFile(image.file_name) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    image.deinit(storage.gpa);
}

pub fn setTexture(storage: *@This(), index: usize, texture: rl.Texture) !void {
    var new_image = rl.Image.fromTexture(texture);
    new_image.flipVertical();

    storage.mutex.lock();
    defer storage.mutex.unlock();
    const image_data = &storage.images.items[index];
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

    const image_data = &storage.images.items[index];
    if (image_data.texture) |texture|
        return texture;

    const image = storage.getImage(index) orelse return null;
    image_data.texture = rl.Texture.fromImage(image);
    return image_data.texture;
}

fn loaderThread(storage: *@This(), index: usize) void {
    storage.mutex.lock();
    var image_data = &storage.images.items[index];
    std.debug.assert(image_data.image == null);
    std.debug.assert(image_data.processing == .loading);
    storage.mutex.unlock();

    const image_encoded = storage.save_directory.readFileAllocOptions(storage.gpa, image_data.file_name, 1024 * 1024 * 1024, 10 * 1024 * 1024, 1, 0) catch |e| {
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
