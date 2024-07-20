const std = @import("std");
const yazap = @import("yazap");
const yaml = @import("yaml");
const Arg = yazap.Arg;

fn osMessage(file: std.fs.File, data: []const u8) !usize {
    var bw = std.io.bufferedWriter(file.writer());
    const return_data = try bw.writer().write(data);
    try bw.flush();
    return return_data;
}

const DiskConfig = struct { version: []const u8, disks: []Disk };

const Disk = struct { device: []const u8, parititions: ?[]Partitions };

const Partitions = struct {
    label: ?[]const u8,
    type: ?[]const u8,
    format: ?[]const u8,
    filesystem: ?[]const u8,
    size: ?[]const u8,
    start: ?[]const u8,
    end: ?[]const u8,
};

pub fn main() !void {
    var app = yazap.App.init(std.heap.page_allocator, "dough", "Declarative disk management utility");
    defer app.deinit();

    var root = app.rootCommand();
    try root.addArg(Arg.booleanOption("version", null, null));

    var plan = app.createCommand("plan", "Plan changes before executing");
    try plan.addArgs(&[_]Arg{Arg.positional("DECLARATION", null, null)});
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
        _ = try osMessage(std.io.getStdOut(), "v0.1.0");
        return;
    }

    if (args.subcommandMatches("plan")) |plan_matches| {
        var declaration_filepath: []const u8 = "";
        if (plan_matches.getSingleValue("DECLARATION")) |val|
            declaration_filepath = val;

        if (declaration_filepath.len == 0) {
            _ = try osMessage(std.io.getStdErr(), "Must contain argument <DECLARATION>");
            return;
        }

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        var alloc = gpa.allocator();
        const real_path = try std.fs.realpathAlloc(alloc, declaration_filepath);
        defer alloc.free(real_path);
        const file = try std.fs.openFileAbsolute(real_path, .{});
        defer file.close();
        const data = try file.reader().readAllAlloc(gpa.allocator(), 512);
        defer alloc.free(data);

        var untyped = try yaml.Yaml.load(alloc, data);
        defer untyped.deinit();

        const shrimp = try untyped.parse(DiskConfig);

        for (shrimp.disks) |_| {
            // Get the disk, get the partitions and whatever else, then print that we are going to change these speciifc things with a git-like diff

        }
    }
}
