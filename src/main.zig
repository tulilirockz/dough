const std = @import("std");
const yazap = @import("yazap");
const yaml = @import("yaml");
const fdisk = @cImport(@cInclude("libfdisk/libfdisk.h"));

const Arg = yazap.Arg;

const Declaration = struct {
    version: []const u8,
    partitions: []const Partition,
};

const Partition = struct {
    type: ?PartitionType,
    // format: ?[]const u8,
    // filesystem: ?[]const u8,
    size: ?u64,
    start: ?u64,
    uuid: ?[]const u8,
    name: ?[]const u8,
    end: ?u64,
};

const PartitionType = struct {
    code: ?u32,
    name: ?[]const u8,
    flags: ?[]const u8,
};

pub fn main() !void {
    var app = yazap.App.init(std.heap.page_allocator, "dough", "Declarative disk management utility");
    defer app.deinit();

    var root = app.rootCommand();
    try root.addArg(Arg.booleanOption("version", null, null));

    var plan = app.createCommand("plan", "Plan changes before executing");
    try plan.addArgs(&[_]Arg{ Arg.positional("DEVICE", null, null), Arg.positional("DECLARATION", null, null) });
    try root.addSubcommand(plan);

    var apply = app.createCommand("apply", "Format the device with the desired configuration");
    try apply.addArgs(&[_]Arg{Arg.positional("DECLARATION", null, null)});
    try root.addSubcommand(apply);

    const args = try app.parseProcess();
    if (!args.containsArgs()) {
        try app.displayHelp();
        return;
    }

    if (args.containsArg("version")) {
        std.log.info("v0.1.0", .{});
        return;
    }

    if (args.subcommandMatches("plan")) |plan_matches| {
        var declaration_filepath: []const u8 = "";
        var device_path: []const u8 = "";

        if (plan_matches.getSingleValue("DEVICE")) |val| {
            device_path = val;
        } else {
            std.log.err("Must contain argument <DEVICE>", .{});
            return;
        }

        if (plan_matches.getSingleValue("DECLARATION")) |val| {
            declaration_filepath = val;
        } else {
            std.log.err("Must contain argument <DECLARATION>", .{});
            return;
        }

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const filealloc = gpa.allocator();
        const real_path = try std.fs.realpathAlloc(filealloc, declaration_filepath);
        defer filealloc.free(real_path);

        const file = try std.fs.openFileAbsolute(real_path, .{});
        defer file.close();

        const data = try file.reader().readAllAlloc(filealloc, 512);
        defer filealloc.free(data);

        const context = fdisk.fdisk_new_context();

        if (fdisk.fdisk_assign_device(context, @ptrCast(device_path), 1) != 0) {
            std.log.err("Failed assigning to device {s}", .{device_path});
            return;
        }
        defer _ = fdisk.fdisk_deassign_device(context, 1);

        if (fdisk.fdisk_get_npartitions(context) == 0) {
            std.log.warn("No partition found in device", .{});
            return;
        }

        // Read partition data into a fdisk_disk struct and print as JSON
        var partable = fdisk.fdisk_new_table();
        defer _ = fdisk.fdisk_unref_table(partable);

        _ = fdisk.fdisk_get_partitions(context, @ptrCast(&partable));

        var partitions = std.ArrayList(Partition).init(filealloc);
        defer partitions.deinit();

        var currpart: usize = 0;
        while (fdisk.fdisk_table_get_partition(partable, currpart)) |partition| : (currpart += 1) {
            const parttype = fdisk.fdisk_partition_get_type(partition);

            var pushpart: Partition = .{
                .start = fdisk.fdisk_partition_get_start(partition),
                .end = null,
                .type = PartitionType{
                    .code = fdisk.fdisk_parttype_get_code(parttype),
                    .name = std.mem.span(fdisk.fdisk_parttype_get_name(parttype)),
                    .flags = std.mem.span(fdisk.fdisk_parttype_get_string(parttype)),
                },
                .size = null,
                .name = std.mem.span(fdisk.fdisk_partition_get_name(partition)),
                .uuid = std.mem.span(fdisk.fdisk_partition_get_uuid(partition)),
            };

            if (fdisk.fdisk_partition_has_end(partition) != 0) {
                pushpart.end = fdisk.fdisk_partition_get_end(partition);
            }

            if (fdisk.fdisk_partition_has_size(partition) != 0) {
                pushpart.size = fdisk.fdisk_partition_get_size(partition);
            }

            try partitions.append(pushpart);
        }

        var untyped = try yaml.Yaml.load(filealloc, data);
        defer untyped.deinit();

        const userdecl = try untyped.parse(Declaration);

        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        std.log.info("This is your current system configuration", .{});
        try std.json.stringify(partitions.items, .{ .whitespace = .indent_4 }, bw.writer());
        _ = try bw.write("\n\n");
        try bw.flush();

        std.log.info("It will be replaced with this new configuration.", .{});

        try std.json.stringify(userdecl.partitions, .{ .whitespace = .indent_4 }, bw.writer());

        try bw.flush();
    }
}
