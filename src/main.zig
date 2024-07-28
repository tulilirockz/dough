const std = @import("std");
const yazap = @import("yazap");
const yaml = @import("yaml");
const fdisk = @cImport(@cInclude("libfdisk/libfdisk.h"));

const DOUGH_VERSION = "v0.1.2";
const Arg = yazap.Arg;

const Declaration = struct {
    version: []const u8,
    // labels: []const u8,
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

fn get_context_partitions(alloc: std.mem.Allocator, cxt: *fdisk.fdisk_context, partable: *fdisk.struct_fdisk_table) !std.ArrayList(Partition) {
    if (fdisk.fdisk_get_npartitions(cxt) == 0) {
        return PartitionParsingErrors.NoPartitions;
    }

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
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    defer arena.deinit();
    const alloc = arena.allocator();

    var app = yazap.App.init(std.heap.page_allocator, "dough", "Declarative disk management utility");
    defer app.deinit();

    var root = app.rootCommand();
    try root.addArg(Arg.booleanOption("version", null, null));

    var apply = app.createCommand("apply", "Format device using manifest as the base");
    try apply.addArgs(&[_]Arg{ Arg.positional("DEVICE", null, null), Arg.positional("DECLARATION", null, null) });
    try root.addSubcommand(apply);

    var destroy = app.createCommand("destroy", "Destroy the partition table data from disk");
    try destroy.addArgs(
        &[_]Arg{ Arg.positional("DEVICE", null, null), Arg.booleanOption("quiet", 'q', "Only return data without any logging"), Arg.singleValueOptionWithValidValues("format", 'f', "Disk label partition type to be used", &[_][]const u8{ "sun", "dos", "gpt", "sgi" }) },
    );
    try root.addSubcommand(destroy);

    var plan = app.createCommand("plan", "Plan changes before formatting device");
    try plan.addArgs(&[_]Arg{
        Arg.positional("DEVICE", "Device whose info will be fetched from", null),
        Arg.positional("DECLARATION", "Declaration to be compared against", null),
        Arg.booleanOption("quiet", 'q', "Only return data without any logging"),
        Arg.singleValueOptionWithValidValues("input-format", 'i', "Format that will be input to the parser", &[_][]const u8{ "json", "yaml" }),
        Arg.singleValueOptionWithValidValues("output-format", 'o', "Format that will be output", &[_][]const u8{ "json", "yaml" }),
    });
    try root.addSubcommand(plan);

    var check = app.createCommand("check", "Check disk declaration for errors");
    try check.addArgs(&[_]Arg{
        Arg.positional("DECLARATION", "Declaration to be inspected", null),
        Arg.booleanOption("quiet", 'q', "Only return data without any logging"),
        Arg.singleValueOptionWithValidValues("format", 'f', "Format that will be output", &[_][]const u8{ "json", "yaml" }),
    });
    try root.addSubcommand(check);

    var dump = app.createCommand("dump", "Display device partitioning information");
    try dump.addArgs(&[_]Arg{
        Arg.positional("DEVICE", "Device to be inspected", null),
        Arg.booleanOption("quiet", 'q', "Only return data without any logging"),
        Arg.singleValueOptionWithValidValues("format", 'f', "Format that will be output", &[_][]const u8{ "json", "yaml" }),
    });
    try root.addSubcommand(dump);

    const args = try app.parseProcess();

    if (!args.containsArgs()) {
        try app.displayHelp();
        return;
    }

    if (args.containsArg("version")) {
        std.log.info("{s}", .{DOUGH_VERSION});
        return;
    }

    if (args.subcommandMatches("destroy")) |matches| {
        if (!matches.containsArgs()) {
            try app.displayHelp();
            return;
        }

        const device_path = matches.getSingleValue("DEVICE") orelse {
            std.log.err("Must contain argument [DEVICE]\n", .{});
            try app.displayHelp();
            return;
        };

        const device_filepath = try std.fs.realpathAlloc(alloc, device_path);

        const context = fdisk.fdisk_new_context() orelse {
            return error.OutOfMemory;
        };
        defer _ = fdisk.fdisk_unref_context(context);

        if (fdisk.fdisk_assign_device(context, @ptrCast(device_filepath), 0) != 0) {
            std.log.err("Failed assigning to device {s}", .{device_path});
            return;
        }
        defer _ = fdisk.fdisk_deassign_device(context, 1);

        if (fdisk.fdisk_enable_wipe(context, 1) != 0) {
            std.log.err("Failure enabling wipe mode for device {s}", .{device_filepath});
            return;
        }

        const partable = fdisk.fdisk_new_table() orelse {
            return error.OutOfMemory;
        };
        defer fdisk.fdisk_unref_table(partable);

        var currpart: usize = 0;
        while (fdisk.fdisk_table_get_partition(partable, currpart)) |partition| : (currpart += 1) {
            var partno: ?usize = null;
            if (fdisk.fdisk_partition_has_partno(partition) != 0) {
                return error.NoPartitions;
            }
            partno = fdisk.fdisk_partition_get_partno(partition);

            if (fdisk.fdisk_wipe_partition(context, partno.?, 1) <= 0) {
                return error.NoPartitions;
            }
        }

        const labeltype = matches.getSingleValue("format") orelse "gpt";
        if (fdisk.fdisk_create_disklabel(context, @ptrCast(labeltype)) != 0) {
            std.log.err("Failed creating new disk label with specified type {s}", .{labeltype});
            return;
        }
        if (fdisk.fdisk_write_disklabel(context) != 0) {
            std.log.err("Failed writing new disk label with specified type {s}", .{labeltype});
            return;
        }

        if (!matches.containsArg("quiet")) {
            std.log.info("Succesfully wiped device {s} and written a {s} disk label over it", .{ device_filepath, labeltype });
        }
        return;
    }

    if (args.subcommandMatches("check")) |matches| {
        if (!matches.containsArgs()) {
            try app.displayHelp();
            return;
        }

        const declaration_path = matches.getSingleValue("DECLARATION") orelse {
            std.log.err("Must contain argument [DECLARATION]\n", .{});
            try app.displayHelp();
            return;
        };
        const selected_format = matches.getSingleValue("format") orelse "yaml";
        const declaration_filepath = try std.fs.realpathAlloc(alloc, declaration_path);
        const file = try std.fs.openFileAbsolute(declaration_filepath, .{});
        defer file.close();

        const data = try file.reader().readAllAlloc(alloc, 2048);
        defer alloc.free(data);

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

    if (args.subcommandMatches("dump")) |matches| {
        if (!matches.containsArgs()) {
            try app.displayHelp();
            return;
        }

        const device_path = matches.getSingleValue("DEVICE") orelse {
            std.log.err("Must contain argument [DEVICE]\n", .{});
            return;
        };

        const selected_format = matches.getSingleValue("format") orelse "json";
        const device_filepath = try std.fs.realpathAlloc(alloc, device_path);
        defer alloc.free(device_filepath);

        const context = fdisk.fdisk_new_context() orelse {
            return error.OutOfMemory;
        };
        defer _ = fdisk.fdisk_unref_context(context);

        if (fdisk.fdisk_assign_device(context, @ptrCast(device_filepath), 1) != 0) {
            std.log.err("Failed assigning to device {s}", .{device_path});
            return;
        }
        defer _ = fdisk.fdisk_deassign_device(context, 1);

        const partable = fdisk.fdisk_new_table() orelse {
            return error.OutOfMemory;
        };
        defer fdisk.fdisk_unref_table(partable);
        const partitions = get_context_partitions(alloc, context, partable) catch |e| switch (e) {
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
            std.log.info("{s}:", .{device_filepath});
        }

        if (std.mem.eql(u8, selected_format, "json")) {
            try std.json.stringify(partitions.items, defaultStringify, std.io.getStdOut().writer());
        } else if (std.mem.eql(u8, selected_format, "yaml")) {
            try yaml.stringify(alloc, partitions.items, std.io.getStdOut().writer());
        }
        return;
    }

    if (args.subcommandMatches("plan")) |matches| {
        if (!matches.containsArgs()) {
            try app.displayHelp();
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

        const context = fdisk.fdisk_new_context() orelse {
            return error.OutOfMemory;
        };
        defer _ = fdisk.fdisk_unref_context(context);

        if (fdisk.fdisk_assign_device(context, @ptrCast(device_path), 1) != 0) {
            std.log.err("Failed assigning to device {s}", .{device_path});
            return;
        }
        defer _ = fdisk.fdisk_deassign_device(context, 1);

        const partable = fdisk.fdisk_new_table() orelse {
            return error.OutOfMemory;
        };
        defer fdisk.fdisk_unref_table(partable);
        const partitions = get_context_partitions(alloc, context, partable) catch |e| switch (e) {
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

        const input_format = matches.getSingleValue("input-format") orelse "json";
        const output_format = matches.getSingleValue("output-format") orelse "json";

        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        const stdout = bw.writer();
        const is_quiet = matches.containsArg("quiet");
        const DEFAULT_STRINGIFY_ERROR = "Failed writing configuration file to stdout";

        const real_path = try std.fs.realpathAlloc(alloc, declaration_filepath);
        const file = try std.fs.openFileAbsolute(real_path, .{});
        defer file.close();
        defer alloc.free(real_path);
        const raw_config_file_data = try file.reader().readAllAlloc(alloc, 2048);
        defer alloc.free(raw_config_file_data);

        var selected_declaration: ?Declaration = null;

        if (std.mem.eql(u8, input_format, "json")) {
            selected_declaration = try std.json.parseFromSliceLeaky(Declaration, alloc, raw_config_file_data, .{ .ignore_unknown_fields = true, .duplicate_field_behavior = .use_first });
        } else if (std.mem.eql(u8, input_format, "yaml")) {
            var untyped = try yaml.Yaml.load(alloc, raw_config_file_data);
            defer untyped.deinit();
            selected_declaration = try untyped.parse(Declaration);
        }

        if (!is_quiet)
            std.log.info("This is your current system configuration", .{});
        if (std.mem.eql(u8, output_format, "yaml")) {
            yaml.stringify(alloc, partitions.items, stdout) catch |e| {
                std.log.err(DEFAULT_STRINGIFY_ERROR, .{});
                return e;
            };
            _ = try bw.write("\n\n");
            try bw.flush();
            if (!is_quiet)
                std.log.info("It will be replaced with this new configuration.", .{});
            yaml.stringify(alloc, selected_declaration.?.partitions, stdout) catch |e| {
                std.log.err(DEFAULT_STRINGIFY_ERROR, .{});
                return e;
            };
            try bw.flush();
        } else if (std.mem.eql(u8, output_format, "json")) {
            std.json.stringify(partitions.items, defaultStringify, stdout) catch |e| {
                std.log.err(DEFAULT_STRINGIFY_ERROR, .{});
                return e;
            };

            _ = try bw.write("\n\n");
            try bw.flush();
            if (!is_quiet)
                std.log.info("It will be replaced with this new configuration.", .{});
            std.json.stringify(selected_declaration.?.partitions, defaultStringify, stdout) catch |e| {
                std.log.err(DEFAULT_STRINGIFY_ERROR, .{});
                return e;
            };
            try bw.flush();
        }
        try bw.flush();
        return;
    }
}
