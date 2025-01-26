//
// loader.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

const std = @import("std");

const Executable = @import("executable.zig").Executable;
const Header = @import("header.zig").Header;
const print_header = @import("header.zig").print_header;
const Module = @import("module.zig").Module;
const Parser = @import("parser.zig").Parser;
const Type = @import("header.zig").Type;
const Environment = @import("environment.zig").Environment;
const Section = @import("section.zig").Section;

const LoaderError = error{
    DataProcessingFailure,
    SymbolTableRelocationFailure,
    FileResolverNotSet,
    DependencyNotFound,
    DependencyIsNotLibrary,
    SymbolNotFound,
    OutOfMemory,
    ChildLoadingFailure,
};

pub const Loader = struct {
    // OS should provide pointer to XIP region, it must be copied to RAM if needed
    pub const FileResolver = *const fn (name: []const u8) ?*anyopaque;

    allocator: std.mem.Allocator,
    file_resolver: FileResolver,
    environment: Environment,

    pub fn create(allocator: std.mem.Allocator, environment: Environment, file_resolver: FileResolver) Loader {
        return .{
            .allocator = allocator,
            .environment = environment,
            .file_resolver = file_resolver,
        };
    }

    pub fn load_executable(self: Loader, module: *const anyopaque, stdout: anytype) !Executable {
        stdout.print("[yasld] loading executable from: 0x{x}\n", .{@intFromPtr(module)});
        var executable: Executable = .{ .module = Module.init(self.allocator) };
        try self.load_module(&executable.module, module, stdout);
        return executable;
    }

    fn import_child_modules(self: Loader, header: *const Header, parser: *const Parser, module: *Module, stdout: anytype) LoaderError!void {
        if (header.external_libraries_amount == 0) {
            return;
        }

        try module.allocate_modules(header.external_libraries_amount);

        var it = parser.imported_libraries.iter();
        var index: usize = 0;
        while (it) |library| : ({
            it = library.next();
            index += 1;
        }) {
            const maybe_address = self.file_resolver(library.data.name());
            if (maybe_address) |address| {
                const library_header = self.process_header(address) catch {
                    stdout.print("Incorrect 'YAFF' marking for '{s}'\n", .{library.data.name()});
                    return error.ChildLoadingFailure;
                };
                if (@as(Type, @enumFromInt(library_header.module_type)) != Type.Library) {
                    return LoaderError.DependencyIsNotLibrary;
                }

                self.load_module(&module.imported_modules.items[index], address, stdout) catch |err| {
                    stdout.print("Can't load child module '{s}': {s}\n", .{ library.data.name(), @errorName(err) });
                    return error.ChildLoadingFailure;
                };
            } else {
                return LoaderError.DependencyNotFound;
            }
        }
    }

    fn process_data(_: Loader, header: *const Header, parser: *const Parser, module: *Module) !void {
        const data_initializer = parser.get_data();
        try module.allocate_data(header.data_length, header.bss_length);
        @memcpy(module.data.?[0..header.data_length], data_initializer);
        @memset(module.bss.?[0..header.bss_length], 0);
    }

    fn process_symbol_table_relocations(self: Loader, parser: *const Parser, module: *Module, stdout: anytype) !void {
        for (parser.symbol_table_relocations.relocations) |rel| {
            const maybe_symbol = parser.imported_symbols.element_at(rel.symbol_index);
            if (maybe_symbol) |symbol| {
                const maybe_address = self.find_symbol(module, symbol.name());
                if (maybe_address) |address| {
                    module.lot.?[rel.index] = address;
                } else {
                    stdout.print("[yasld] Can't find symbol: '{s}'\n", .{symbol.name()});
                    return LoaderError.SymbolNotFound;
                }
            } else {
                return LoaderError.SymbolNotFound;
            }
        }
    }

    fn find_symbol(self: Loader, module: *Module, name: []const u8) ?usize {
        // symbols provided by OS have highest priority
        if (self.environment.find_symbol(name)) |symbol| {
            return symbol.address;
        }

        if (module.find_symbol(name)) |symbol| {
            return symbol;
        }

        return null;
    }

    fn process_local_relocations(_: Loader, parser: *const Parser, module: *Module) !void {
        for (parser.local_relocations.relocations) |rel| {
            const relocated_start_address: usize = try module.get_base_address(@enumFromInt(rel.section));
            const relocated = relocated_start_address + rel.target_offset;
            module.lot.?[rel.index] = relocated;
        }
    }

    fn process_data_relocations(_: Loader, parser: *const Parser, module: *Module) !void {
        for (parser.data_relocations.relocations) |rel| {
            const address_to_change: usize = @intFromPtr(module.data.?.ptr) + rel.to;
            const target: *usize = @ptrFromInt(address_to_change);
            const base_address_from: usize = try module.get_base_address(@enumFromInt(rel.section));
            const address_from: usize = base_address_from + rel.from;
            target.* = address_from;
        }
    }

    fn load_module(self: Loader, module: *Module, module_address: *const anyopaque, stdout: anytype) !void {
        stdout.write("[yasld] parsing header\n");
        const header = self.process_header(module_address) catch |err| return err;
        print_header(header, stdout);

        const parser = Parser.create(header);
        parser.print(stdout);

        const table_size: usize = header.symbol_table_relocations_amount + header.local_relocations_amount;
        module.name = parser.name;
        try module.allocate_lot(table_size);
        const text_ptr: [*]const u8 = @ptrFromInt(parser.text_address);
        module.text = text_ptr[0..header.code_length];
        try self.import_child_modules(header, &parser, module, stdout);
        // import modules
        try self.process_data(header, &parser, module);
        module.exported_symbols = parser.exported_symbols;

        const init_ptr: [*]const usize = @ptrFromInt(parser.init_address);
        try module.relocate_init(init_ptr[0..header.init_length]);

        try self.process_symbol_table_relocations(&parser, module, stdout);
        try self.process_local_relocations(&parser, module);
        try self.process_data_relocations(&parser, module);

        if (header.entry != 0xffffffff and header.module_type == @intFromEnum(Type.Executable)) {
            var section: Section = .Unknown;
            const text_limit: usize = module.text.?.len;
            const init_limit: usize = text_limit + module.init_memory.?.len * @sizeOf(usize);
            const data_limit: usize = init_limit + module.data.?.len;

            if (header.entry < text_limit) {
                section = .Code;
            } else if (header.entry < init_limit) {
                section = .Init;
            } else if (header.entry < data_limit) {
                section = .Data;
            } else {
                section = .Bss;
            }

            const base_address = try module.get_base_address(section);
            module.entry = base_address + header.entry;
        }
    }

    fn process_header(_: Loader, module_address: *const anyopaque) error{IncorrectSignature}!*const Header {
        const header: *const Header = @ptrCast(@alignCast(module_address));
        if (!std.mem.eql(u8, std.mem.asBytes(&header.marker), "YAFF")) {
            return error.IncorrectSignature;
        }
        return header;
    }
};
