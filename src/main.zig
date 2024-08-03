const std = @import("std");
const yazap = @import("yazap");
const yaml = @import("yaml");
const fdisk = @cImport(@cInclude("libfdisk/libfdisk.h"));

const DOUGH_VERSION = "v0.1.4";
const Arg = yazap.Arg;

const Declaration = struct {
    dough: []const u8 = DOUGH_VERSION,
    label: []const u8,
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

const DEFAULT_STRINGIFY = std.json.StringifyOptions{
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

const TextDataFormat = enum {
    json,
    yaml,
};

const DefaultDataFormat = struct {
    @"enum": TextDataFormat = .json,
    str: []const u8 = "json",
};
const DEFAULT_DATA_FORMAT: DefaultDataFormat = .{};

fn stringify_to_writer(allocator: std.mem.Allocator, input: anytype, output: anytype, format: TextDataFormat) !void {
    switch (format) {
        .json => _ = try output.write(try std.json.stringifyAlloc(allocator, input, DEFAULT_STRINGIFY)),
        .yaml => try yaml.stringify(allocator, input, output),
    }
}

fn parse_formatted_text_data(comptime T: type, allocator: std.mem.Allocator, filedata: *const []const u8, format: TextDataFormat) !T {
    switch (format) {
        .json => return try std.json.parseFromSliceLeaky(T, allocator, filedata.*, .{}),
        .yaml => {
            var untyped = try yaml.Yaml.load(allocator, filedata.*);
            defer untyped.deinit();
            return try untyped.parse(T);
        },
    }
}

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

        if (fdisk.fdisk_partition_has_partno(partition) != 0)
            pushpart.partno = fdisk.fdisk_partition_get_partno(partition);

        if (fdisk.fdisk_partition_has_end(partition) != 0)
            pushpart.end = fdisk.fdisk_partition_get_end(partition);

        if (fdisk.fdisk_partition_has_size(partition) != 0)
            pushpart.size = fdisk.fdisk_partition_get_size(partition);

        try partitions.append(pushpart);
    }
    return partitions;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var app = yazap.App.init(std.heap.page_allocator, "dough", "Declarative disk management utility");
    defer app.deinit();

    var root = app.rootCommand();
    try root.addArg(Arg.booleanOption("version", 'v', "Show version number"));
    try root.addArg(Arg.booleanOption("debug", 'd', "Enable debug mode in disk partitioning"));

    var apply = app.createCommand("apply", "Format device using manifest as the base");
    try apply.addArgs(&[_]Arg{
        Arg.positional("DEVICE", null, null),
        Arg.positional("DECLARATION", null, null),
        Arg.singleValueOptionWithValidValues("format", 'f', "Configuration format that will be parsed from", &[_][]const u8{ "json", "yaml" }),
        Arg.booleanOption("quiet", 'q', "Only return data without any logging"),
    });
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

    if (args.containsArg("debug")) {
        std.log.info("Enabled full debug mode in libfdisk", .{});
        fdisk.fdisk_init_debug(0xffff);
    }

    if (args.subcommandMatches("apply")) |matches| {
        if (!matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }

        const device_path = matches.getSingleValue("DEVICE") orelse {
            std.log.err("Must contain argument [DEVICE]\n", .{});
            try app.displaySubcommandHelp();
            return;
        };
        const declaration_path = matches.getSingleValue("DECLARATION") orelse {
            std.log.err("Must contain argument [DECLARATION]\n", .{});
            try app.displaySubcommandHelp();
            return;
        };

        const declaration_filepath = std.fs.realpathAlloc(alloc, declaration_path) catch declaration_path;

        var openfile = if (std.mem.eql(u8, declaration_path, "_")) std.io.getStdIn() else (try std.fs.openFileAbsolute(declaration_filepath, .{}));
        defer openfile.close();

        const file = openfile.reader();
        var freader = std.io.bufferedReader(file);
        var read = freader.reader();
        const filedata = try read.readAllAlloc(alloc, 4096);
        defer alloc.free(filedata);

        const format = if (std.mem.eql(u8, matches.getSingleValue("format") orelse "json", "json")) TextDataFormat.json else TextDataFormat.yaml;
        const decl = parse_formatted_text_data(Declaration, alloc, &filedata, format) catch |e| {
            std.log.err("Failed parsing data", .{});
            return e;
        };

        const context = fdisk.fdisk_new_context() orelse {
            return error.OutOfMemory;
        };
        defer _ = fdisk.fdisk_unref_context(context);

        const device_filepath = try std.fs.realpathAlloc(alloc, device_path);
        defer alloc.free(device_filepath);
        if (fdisk.fdisk_assign_device(context, @ptrCast(device_path), 0) != 0) {
            std.log.err("Failed assigning to device {s}", .{device_path});
            return;
        }
        defer _ = fdisk.fdisk_deassign_device(context, 0);

        if (fdisk.fdisk_enable_wipe(context, 1) != 0) {
            std.log.err("Failure enabling wipe mode for device {s}", .{device_filepath});
            return;
        }

        const label = try alloc.dupeZ(u8, decl.label);
        defer alloc.free(label);
        if (fdisk.fdisk_has_label(context) != 0) {
            if (fdisk.fdisk_create_disklabel(context, label.ptr) != 0) {
                return error.Unimplemented;
            }
            _ = fdisk.fdisk_write_disklabel(context);
        }

        if (fdisk.fdisk_create_disklabel(context, label.ptr) != 0) {
            return error.Unimplemented;
        }
        const table = fdisk.fdisk_new_table();
        defer fdisk.fdisk_unref_table(table);

        for (decl.partitions) |partition| {
            const newpart = fdisk.fdisk_new_partition() orelse {
                return error.OutOfMemory;
            };
            defer _ = fdisk.fdisk_unref_partition(newpart);

            const parttype = fdisk.fdisk_new_parttype();
            _ = fdisk.fdisk_parttype_set_code(parttype, @intCast(partition.type.code));
            _ = fdisk.fdisk_parttype_set_name(parttype, @ptrCast(partition.type.name));

            // UUIDs are applied automatically
            _ = fdisk.fdisk_partition_set_start(newpart, partition.start orelse return error.Unimplemented);
            _ = fdisk.fdisk_partition_set_partno(newpart, partition.partno orelse return error.Unimplemented);
            _ = fdisk.fdisk_partition_set_size(newpart, partition.size orelse return error.Unimplemented);
            _ = fdisk.fdisk_partition_set_type(newpart, parttype);
            _ = fdisk.fdisk_table_add_partition(table, newpart);
        }

        if (fdisk.fdisk_apply_table(context, table) != 0) {
            std.log.err("Failed writing partition table to memory", .{});
            return;
        }

        if (fdisk.fdisk_write_disklabel(context) != 0) {
            std.log.err("Failed applying partition table and disklabel information to device {s}", .{device_filepath});
            return;
        }

        if (!matches.containsArg("quiet"))
            std.log.info("Succesfully partitioned device {s}", .{device_filepath});
    }

    if (args.subcommandMatches("destroy")) |matches| {
        if (!matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }

        const device_path = matches.getSingleValue("DEVICE") orelse {
            std.log.err("Must contain argument [DEVICE]\n", .{});
            try app.displaySubcommandHelp();
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

        if (fdisk.fdisk_get_npartitions(context) != 0) {
            if (fdisk.fdisk_delete_all_partitions(context) != 0) {
                std.log.err("Failed deleting partition table data", .{});
                return;
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
            try app.displaySubcommandHelp();
            return;
        }

        const declaration_path = matches.getSingleValue("DECLARATION") orelse {
            std.log.err("Must contain argument [DECLARATION]\n", .{});
            try app.displaySubcommandHelp();
            return;
        };
        const declaration_filepath = try std.fs.realpathAlloc(alloc, declaration_path);
        const file = try std.fs.openFileAbsolute(declaration_filepath, .{});
        defer file.close();

        const data = try file.reader().readAllAlloc(alloc, 2048);
        defer alloc.free(data);

        const selected_format = std.meta.stringToEnum(TextDataFormat, matches.getSingleValue("format") orelse DEFAULT_DATA_FORMAT.str) orelse DEFAULT_DATA_FORMAT.@"enum";
        _ = parse_formatted_text_data(Declaration, alloc, &data, selected_format) catch |e| {
            std.log.err("Failed parsing configuration file", .{});
            return e;
        };

        if (!matches.containsArg("quiet")) {
            std.log.info("The declaration has been parsed successfully, good to go!", .{});
        }
    }

    if (args.subcommandMatches("dump")) |matches| {
        if (!matches.containsArgs()) {
            try app.displaySubcommandHelp();
            return;
        }

        const device_path = matches.getSingleValue("DEVICE") orelse {
            std.log.err("Must contain argument [DEVICE]\n", .{});
            return;
        };

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

        const disklabel = fdisk.fdisk_get_label(context, null) orelse {
            std.log.err("Failed parsing partition label information from disk {s}", .{device_filepath});
            return;
        };

        const printed: Declaration = .{
            .label = std.mem.span(fdisk.fdisk_label_get_name(disklabel)),
            .partitions = partitions.items,
        };

        if (!matches.containsArg("quiet")) {
            std.log.info("{s}:", .{device_filepath});
        }

        const selected_format = std.meta.stringToEnum(TextDataFormat, matches.getSingleValue("format") orelse DEFAULT_DATA_FORMAT.str) orelse DEFAULT_DATA_FORMAT.@"enum";
        try stringify_to_writer(alloc, printed, std.io.getStdOut().writer(), selected_format);
        return;
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

        const input_format = std.meta.stringToEnum(TextDataFormat, matches.getSingleValue("input-format") orelse DEFAULT_DATA_FORMAT.str) orelse DEFAULT_DATA_FORMAT.@"enum";
        const output_format = std.meta.stringToEnum(TextDataFormat, matches.getSingleValue("output-format") orelse DEFAULT_DATA_FORMAT.str) orelse DEFAULT_DATA_FORMAT.@"enum";

        const real_path = try std.fs.realpathAlloc(alloc, declaration_filepath);
        defer alloc.free(real_path);

        const file = try std.fs.openFileAbsolute(real_path, .{});
        defer file.close();

        const raw_config_file_data = try file.reader().readAllAlloc(alloc, 2048);
        defer alloc.free(raw_config_file_data);

        const selected_declaration = try parse_formatted_text_data(Declaration, alloc, &raw_config_file_data, input_format);

        const is_quiet = matches.containsArg("quiet");
        if (!is_quiet)
            std.log.info("Previous state", .{});

        var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
        const stdout = bw.writer();
        try stringify_to_writer(alloc, partitions.items, stdout, input_format);

        if (!is_quiet)
            std.log.info("New state", .{});
        try stringify_to_writer(alloc, selected_declaration.partitions, stdout, output_format);
        return;
    }
}
