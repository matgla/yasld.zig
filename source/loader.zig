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
const Module = @import("module.zig").Module;
const Parser = @import("parser.zig").Parser;

const LoaderError = error{
    DataProcessingFailure,
    SymbolTableRelocationFailure,
};

pub const Loader = struct {
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) Loader {
        return .{
            .allocator = allocator,
        };
    }

    pub fn load_executable(self: Loader, module: *const anyopaque, stdout: anytype) !Executable {
        stdout.print("[yasld] loading executable from: 0x{x}\n", .{@intFromPtr(module)});
        var executable: Executable = .{};
        try self.load_module(&executable.module, module, stdout);
        return executable;
    }

    fn load_child_modules(_: Loader) void {}
    fn process_data_relocations(_: Loader) void {}
    fn process_symbol_table_relocations(_: Loader) !void {}
    fn import_child_modules(_: Loader) void {}
    fn process_data(_: Loader) !void {}
    fn process_local_relocations(_: Loader) void {}

    fn load_module(self: Loader, module: *Module, module_address: *const anyopaque, stdout: anytype) !void {
        stdout.write("[yasld] parsing header\n");
        const header = self.process_header(module_address) catch |err| return err;
        stdout.print("Header: {}\n", .{std.json.fmt(header.*, .{
            .whitespace = .indent_2,
        })});
        const parser = Parser.create(header);
        parser.print(stdout);

        const table_size: usize = header.symbol_table_relocations_amount + header.local_relocations_amount;
        module.name = parser.name;
        try module.allocate_lot(table_size);
        const text_ptr: [*]const u8 = @ptrFromInt(parser.text_address);
        module.text = text_ptr[0..header.code_length];
        const init_ptr: [*]const usize = @ptrFromInt(parser.init_address);
        try module.relocate_init(init_ptr[0..header.init_length]);

        self.import_child_modules();
        // import modules
        try self.process_data();
        module.exported_symbols = parser.exported_symbols;

        try self.process_symbol_table_relocations();

        self.process_local_relocations();
        self.process_data_relocations();
    }

    fn process_header(_: Loader, module_address: *const anyopaque) error{IncorrectSignature}!*const Header {
        const header: *const Header = @ptrCast(@alignCast(module_address));
        if (!std.mem.eql(u8, std.mem.asBytes(&header.marker), "YAFF")) {
            return error.IncorrectSignature;
        }
        return header;
    }
};
