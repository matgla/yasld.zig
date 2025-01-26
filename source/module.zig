//
// module.zig
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

const SymbolTable = @import("item_table.zig").SymbolTable;
const Section = @import("section.zig").Section;

// move this to architecture implementation
pub const ForeignCallContext = extern struct {
    r9: usize = 0,
    lr: usize = 0,
    temp: [2]usize = .{ 0, 0 },
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    lot: ?[]usize = null,
    text: ?[]const u8 = null,
    data: ?[]u8 = null,
    init_memory: ?[]usize = null,
    bss: ?[]u8 = null,
    exported_symbols: ?SymbolTable = null,
    name: ?[]const u8 = null,
    foreign_call_context: ForeignCallContext,
    imported_modules: std.ArrayList(Module),
    // this needs to be corelated with thread info
    active: bool,
    entry: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Module {
        return .{
            .allocator = allocator,
            .foreign_call_context = .{},
            .imported_modules = std.ArrayList(Module).init(allocator),
            .active = false,
        };
    }

    pub fn deinit(self: *Module) void {
        if (self.lot) |lot| {
            self.allocator.free(lot);
        }
        if (self.data) |data| {
            self.allocator.free(data);
        }
        if (self.init_memory) |i| {
            self.allocator.free(i);
        }
        if (self.bss) |bss| {
            self.allocator.free(bss);
        }
        self.imported_modules.deinit();
    }

    pub fn allocate_lot(self: *Module, size: usize) !void {
        self.lot = try self.allocator.alloc(usize, size);
    }

    pub fn allocate_data(self: *Module, data_size: usize, bss_size: usize) !void {
        self.data = try self.allocator.alloc(u8, data_size);
        self.bss = try self.allocator.alloc(u8, bss_size);
    }

    // imported modules must use it's own memory thus cannot be shared
    pub fn allocate_modules(self: *Module, number_of_modules: usize) !void {
        _ = try self.imported_modules.addManyAsSlice(number_of_modules);
        for (self.imported_modules.items) |*module| {
            module.* = Module.init(self.allocator);
        }
    }

    pub fn get_base_address(self: Module, section: Section) error{UnknownSection}!usize {
        switch (section) {
            .Code => return @intFromPtr(self.text.?.ptr),
            .Data => return @intFromPtr(self.data.?.ptr),
            .Init => return @intFromPtr(self.init_memory.?.ptr),
            .Bss => return @intFromPtr(self.bss.?.ptr),
            .Unknown => return error.UnknownSection,
        }
    }

    pub fn find_symbol(self: Module, name: []const u8) ?usize {
        var it = self.exported_symbols.?.iter();

        while (it) |symbol| : (it = symbol.next()) {
            if (std.mem.eql(u8, symbol.data.name(), name)) {
                const base = self.get_base_address(@enumFromInt(symbol.data.section)) catch return null;
                return base + symbol.data.offset;
            }
        }

        for (self.imported_modules.items) |module| {
            const maybe_symbol = module.find_symbol(name);
            if (maybe_symbol) |symbol| {
                return symbol;
            }
        }

        return null;
    }

    pub fn save_caller_state(self: *Module, context: ForeignCallContext) void {
        self.foreign_call_context = context;
    }

    const ModuleError = error{
        UnhandledInitAddress,
    };

    pub fn relocate_init(self: *Module, initializers: []const usize) !void {
        self.init_memory = try self.allocator.alloc(usize, initializers.len);
        // @memcpy(self.init_memory.?[0..initializers.len], initializers);
        const text_end: usize = self.text.?.len;
        const init_end: usize = self.init_memory.?.len * @sizeOf(usize);
        const data_end: usize = self.data.?.len;
        const bss_end: usize = self.bss.?.len;

        for (0..initializers.len) |i| {
            if (initializers[i] < text_end) {
                self.init_memory.?[i] = initializers[i] + @intFromPtr(self.text.?.ptr);
            } else if (initializers[i] < init_end) {
                self.init_memory.?[i] = initializers[i] + @intFromPtr(self.init_memory.?.ptr);
            } else if (initializers[i] < data_end) {
                self.init_memory.?[i] = initializers[i] + @intFromPtr(self.data.?.ptr);
            } else if (initializers[i] < bss_end) {
                self.init_memory.?[i] = initializers[i] + @intFromPtr(self.bss.?.ptr);
            } else {
                return ModuleError.UnhandledInitAddress;
            }
        }
    }

    pub fn is_module_for_program_counter(self: Module, pc: usize, only_active: bool) bool {
        {
            const text_start = self.get_base_address(Section.Code);
            const text_end = text_start + self.text.len;
            if (pc >= text_start and pc < text_end) {
                if (self.active or !only_active) {
                    return true;
                } else {
                    return false;
                }
            }
        }
        {
            const data_start = self.get_base_address(Section.Data);
            const data_end = data_start + self.data.?.len;
            if (pc >= data_start and pc < data_end) {
                if (self.active or !only_active) {
                    return true;
                } else {
                    return false;
                }
            }
        }
        {
            const bss_start = @intFromPtr(self.bss.?.ptr);
            const bss_end = bss_start + self.bss.?.len;
            if (pc >= bss_start and pc < bss_end) {
                if (self.active or !only_active) {
                    return true;
                } else {
                    return false;
                }
            }
        }
        return false;
    }

    pub fn find_module_for_program_counter(self: *const Module, pc: usize, only_active: bool) ?*Module {
        if (self.is_module_for_program_counter(pc, only_active)) {
            return self;
        }

        for (self.imported_modules.items) |module| {
            const maybe_module = module.find_module_for_program_counter(pc, only_active);
            if (maybe_module) |m| {
                return m;
            }
        }

        return null;
    }

    pub fn find_module_with_lot(self: *const Module, lot_address: usize) ?*Module {
        if (lot_address == @as(usize, @intFromPtr(self.lot.?.ptr))) {
            return self;
        }

        for (self.imported_modules.items) |module| {
            const maybe_module = module.find_module_with_lot(lot_address);
            if (maybe_module) |m| {
                return m;
            }
        }
        return null;
    }
};
