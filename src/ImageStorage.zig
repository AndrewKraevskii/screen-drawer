const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("raylib").Image;
const rl = @import("raylib");

const log = std.log.scoped(.storage);

gpa: Allocator,
save_directory: std.fs.Dir,
images: Storage,
textures: std.AutoArrayHashMapUnmanaged(usize, rl.Texture),

mutex: std.Thread.Mutex,
work_condition: std.Thread.Condition,
should_thread_quit: bool,

/// Images requested for loading
load_queue: std.ArrayListUnmanaged(u32),

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
        .textures = .{},
        .gpa = gpa,
        .images = images,
        .save_directory = dir,
        .mutex = .{},
        .work_condition = .{},
        .should_thread_quit = false,
        .load_queue = .{},
    };
}

pub fn startLoading(storage: *@This()) void {
    _ = std.Thread.spawn(.{
        .allocator = storage.gpa,
    }, loaderThread, .{storage}) catch @panic("Can't spawn thread");
}

pub fn deinit(storage: *@This()) void {
    {
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
        storage.load_queue.deinit(storage.gpa);
    }
    storage.work_condition.signal();
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
        if (changed) {
            log.info("Queue changed", .{});
            storage.work_condition.signal();
        }
    }

    // log.debug("{any}", .{storage.load_queue.items});
    if (index >= storage.len()) return error.OutOfRange;
    const small_index = std.math.cast(u32, index) orelse return error.OutOfRange;
    return storage.images.values()[small_index] orelse {
        if (std.mem.indexOfScalar(
            u32,
            storage.load_queue.items,
            small_index,
        ) != null) return null;
        storage.load_queue.append(
            storage.gpa,
            small_index,
        ) catch {
            std.log.err("out of memory can't queue image loading", .{});
            return null;
        };
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

fn loaderThread(storage: *@This()) void {
    log.info("Started loader thread", .{});
    while (true) {
        storage.mutex.lock();
        log.info("Locked thread", .{});
        if (storage.load_queue.items.len == 0) {
            log.info("Queue is empty waiting", .{});
            storage.work_condition.wait(&storage.mutex);
            log.info("Condition fired", .{});
        }
        if (storage.should_thread_quit) {
            log.info("Exiting", .{});
            return;
        }

        const items = storage.gpa.dupe(u32, storage.load_queue.items) catch @panic("OOM");
        defer storage.gpa.free(items);

        log.info("Loading {any}", .{items});
        storage.mutex.unlock();

        var images_slice = storage.images.values();
        for (items) |index| {
            if (images_slice[index] != null) continue;
            const file_name = storage.images.keys()[index];

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
        storage.mutex.lock();
        storage.load_queue.clearRetainingCapacity();
        storage.mutex.unlock();
    }
}
