const std = @import("std");
const yazap = @import("yazap");
const yaml = @import("yaml");
const fdisk = @cImport(@cInclude("libfdisk/libfdisk.h"));

const DOUGH_VERSION = "v0.1.2";
const Arg = yazap.Arg;

const Declaration = struct {
    version: []const u8,
    partitions: []const Partition,
};

const Partition = struct {
    // format: ?[]const u8,
    // filesystem: ?[]const u8,
    type: PartitionType,
    uuid: []const u8,
    name: []const u8,
    partno: ?usize,
    size: ?u64,
    start: ?u64,
    end: ?u64,
};

const PartitionType = struct {
    // TODO: add EF00 -> whatever codes
    code: u32,
    name: []const u8,
    flags: []const u8,
};

const defaultStringify = std.json.StringifyOptions{
    .whitespace = .indent_4,
    .emit_null_optional_fields = true,
    .emit_strings_as_arrays = false,
    .emit_nonportable_numbers_as_strings = true,
};

const PartitionParsingErrors = error{
    NoPartitions,
    NoPartType,
    InvalidPartition,
};

fn get_context_partitions(alloc: std.mem.Allocator, cxt: *fdisk.fdisk_context) !std.ArrayList(Partition) {
    if (fdisk.fdisk_get_npartitions(cxt) == 0) {
        return PartitionParsingErrors.NoPartitions;
    }

    const partable = fdisk.fdisk_new_table() orelse {
        return error.OutOfMemory;
    };

    if (fdisk.fdisk_get_partitions(cxt, @ptrCast(@alignCast(partable))) != 0) {
        return error.OutOfMemory;
    }
    var partitions = std.ArrayList(Partition).init(alloc);

    var currpart: usize = 0;
    while (fdisk.fdisk_table_get_partition(partable, currpart)) |partition| : (currpart += 1) {
        const parttype = fdisk.fdisk_partition_get_type(partition) orelse {
            return PartitionParsingErrors.NoPartitions;
        };

        if (fdisk.fdisk_partition_has_start(partition) == 0) {
            return PartitionParsingErrors.InvalidPartition;
        }
        var pushpart: Partition = .{
            .type = PartitionType{
                .code = fdisk.fdisk_parttype_get_code(parttype),
                .name = std.mem.span(fdisk.fdisk_parttype_get_name(parttype)),
                .flags = std.mem.span(fdisk.fdisk_parttype_get_string(parttype)),
            },
            .name = std.mem.span(fdisk.fdisk_partition_get_name(partition)),
            .uuid = std.mem.span(fdisk.fdisk_partition_get_uuid(partition)),
            .start = fdisk.fdisk_partition_get_start(partition),
            .end = null,
            .size = null,
            .partno = null,
        };

        if (fdisk.fdisk_partition_has_partno(partition) != 0) {
            pushpart.partno = fdisk.fdisk_partition_get_partno(partition);
        }

        if (fdisk.fdisk_partition_has_end(partition) != 0) {
            pushpart.end = fdisk.fdisk_partition_get_end(partition);
        }

        if (fdisk.fdisk_partition_has_size(partition) != 0) {
            pushpart.size = fdisk.fdisk_partition_get_size(partition);
        }
        try partitions.append(pushpart);
    }
    return partitions;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var app = yazap.App.init(alloc, "dough", "Declarative disk management utility");
    defer app.deinit();

    // dough -> info, plan, apply, destroy?, check
    var root = app.rootCommand();
    try root.addArg(Arg.booleanOption("version", null, null));

    var apply = app.createCommand("apply", "Format device using manifest as the base");
    try apply.addArgs(&[_]Arg{ Arg.positional("DEVICE", null, null), Arg.positional("DECLARATION", null, null) });
    try root.addSubcommand(apply);

    var destroy = app.createCommand("destroy", "Destroy the partition table data from disk");
    try destroy.addArgs(&[_]Arg{Arg.positional("DEVICE", null, null)});
    try root.addSubcommand(destroy);

    var plan = app.createCommand("plan", "Plan changes before formatting device");
    try plan.addArgs(&[_]Arg{ Arg.positional("DEVICE", null, null), Arg.positional("DECLARATION", null, null) });
    try root.addSubcommand(plan);

    var check = app.createCommand("check", "Check disk declaration for errors");
    try check.addArgs(&[_]Arg{
        Arg.positional("DECLARATION", "Declaration to be inspected", null),
        Arg.booleanOption("quiet", 'q', "Only return data without any logging"),
        Arg.singleValueOptionWithValidValues("format", 'f', "Format that will be output", &[_][]const u8{ "json", "yaml" }),
    });
    try root.addSubcommand(check);

    var info = app.createCommand("info", "Display device partitioning information");
    try info.addArgs(&[_]Arg{
        Arg.positional("DEVICE", "Device to be inspected", null),
        Arg.booleanOption("quiet", 'q', "Only return data without any logging"),
        Arg.singleValueOptionWithValidValues("format", 'f', "Format that will be output", &[_][]const u8{ "json", "yaml" }),
    });
    try root.addSubcommand(info);

    const args = try app.parseProcess();

    if (!args.containsArgs()) {
        try app.displayHelp();
        return;
    }

    if (args.containsArg("version")) {
        std.log.info("{s}", .{DOUGH_VERSION});
        return;
    }

    if (args.subcommandMatches("check")) |matches| {
        if (!matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }

        const declaration_path = matches.getSingleValue("DECLARATION") orelse {
            std.log.err("Must contain argument [DECLARATION]\n", .{});
            try app.displaySubcommandHelp();
            return;
        };
        const selected_format = matches.getSingleValue("format") orelse "yaml";
        const declaration_filepath = try std.fs.realpathAlloc(alloc, declaration_path);
        const file = try std.fs.openFileAbsolute(declaration_filepath, .{});
        defer file.close();

        const data = try file.reader().readAllAlloc(alloc, 512);

        if (std.mem.eql(u8, selected_format, "json")) {
            _ = try std.json.parseFromSlice(Declaration, alloc, data, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false });
        }
        if (std.mem.eql(u8, selected_format, "yaml")) {
            var untyped = try yaml.Yaml.load(alloc, data);
            defer untyped.deinit();
            _ = try untyped.parse(Declaration);
        }

        if (!matches.containsArg("quiet")) {
            std.log.info("The declaration has been parsed successfully, good to go!", .{});
        }
    }

    if (args.subcommandMatches("info")) |matches| {
        if (!matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }

        const device_path = matches.getSingleValue("DEVICE") orelse {
            std.log.err("Must contain argument [DEVICE]\n", .{});
            return;
        };

        const selected_format = matches.getSingleValue("format") orelse "json";
        const device_filepath = try std.fs.realpathAlloc(alloc, device_path);

        const context = fdisk.fdisk_new_context() orelse {
            return error.OutOfMemory;
        };

        if (fdisk.fdisk_assign_device(context, @ptrCast(device_filepath), 1) != 0) {
            std.log.err("Failed assigning to device {s}", .{device_path});
            return;
        }
        defer _ = fdisk.fdisk_deassign_device(context, 1);

        const partitions = get_context_partitions(alloc, context) catch |e| switch (e) {
            error.NoPartitions => {
                std.log.err("Failure finding partitions in device {s}", .{device_filepath});
                return;
            },
            error.NoPartType => {
                std.log.err("Failure finding partition type information", .{});
                return;
            },
            error.InvalidPartition => {
                std.log.err("Invalid partition found partition with no start", .{});
                return;
            },
            else => {
                std.log.err("Unexpected runtime error ocourred", .{});
                return e;
            },
        };
        defer partitions.deinit();

        if (!matches.containsArg("quiet")) {
            std.log.info("These are your device's partitions\n{s}:", .{device_filepath});
        }

        if (std.mem.eql(u8, selected_format, "json")) {
            try std.json.stringify(partitions.items, defaultStringify, std.io.getStdOut().writer());
            return;
        } else { // Not necessary to actually have a check here because there are only two options for now.
            try yaml.stringify(alloc, partitions.items, std.io.getStdOut().writer());
            return;
        }
    }

    if (args.subcommandMatches("plan")) |matches| {
        if (!matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }

        const device_path = matches.getSingleValue("DEVICE") orelse {
            std.log.err("Must contain argument [DEVICE]\n", .{});
            return;
        };

        const declaration_filepath = matches.getSingleValue("DECLARATION") orelse {
            std.log.err("Must contain argument [DECLARATION]\n", .{});
            return;
        };
        const real_path = try std.fs.realpathAlloc(alloc, declaration_filepath);

        const file = try std.fs.openFileAbsolute(real_path, .{});
        defer file.close();

        const data = try file.reader().readAllAlloc(alloc, 512);

        const context = fdisk.fdisk_new_context() orelse {
            return error.OutOfMemory;
        };

        if (fdisk.fdisk_assign_device(context, @ptrCast(device_path), 1) != 0) {
            std.log.err("Failed assigning to device {s}", .{device_path});
            return;
        }
        defer _ = fdisk.fdisk_deassign_device(context, 1);

        const partitions = get_context_partitions(alloc, context) catch |e| switch (e) {
            error.NoPartitions => {
                std.log.err("Failure finding partitions in device {s}", .{device_path});
                return;
            },
            error.NoPartType => {
                std.log.err("Failure finding partition type information", .{});
                return;
            },
            error.InvalidPartition => {
                std.log.err("Invalid partition found partition with no start", .{});
                return;
            },
            else => {
                std.log.err("Unexpected runtime error ocourred", .{});
                return e;
            },
        };
        defer partitions.deinit();

        var untyped = try yaml.Yaml.load(alloc, data);
        defer untyped.deinit();

        const userdecl = try untyped.parse(Declaration);

        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        std.log.info("This is your current system configuration", .{});
        try std.json.stringify(partitions.items, defaultStringify, bw.writer());

        _ = try bw.write("\n\n");
        try bw.flush();

        std.log.info("It will be replaced with this new configuration.", .{});
        try std.json.stringify(userdecl.partitions, defaultStringify, bw.writer());

        try bw.flush();
        return;
    }
}
