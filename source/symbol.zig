//
// symbol.zig
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

const Section = @import("section.zig").Section;

pub const Symbol = packed struct {
    section: u2,
    offset: u30,

    pub fn name(self: *const Symbol) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrFromInt(@intFromPtr(self) + @sizeOf(Symbol))));
    }

    pub fn size(self: *const Symbol, alignment: u8) usize {
        return std.mem.alignForward(usize, @sizeOf(Symbol) + self.name().len + 1, alignment);
    }

    pub fn next(self: *const Symbol, alignment: u8) *const Symbol {
        return @ptrFromInt(@intFromPtr(self) + self.size(alignment));
    }
};

comptime {
    if (@sizeOf(Symbol) != 4) @compileError("Symbol sizeof is not 4");
    if (@alignOf(Symbol) != 4) @compileError("Symbol aligment is not 4");
}
