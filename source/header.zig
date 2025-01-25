//
// header.zig
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

pub const Type = enum(u8) {
    Unknown = 0,
    Executable = 1,
    Library = 2,
};

pub const Architecture = enum(u16) {
    Unknown = 0,
    Armv6_m = 1,
};

pub const Header = packed struct {
    marker: u32,
    module_type: u8,
    arch: u16,
    yasiff_version: u8,
    code_length: u32,
    init_length: u32,
    data_length: u32,
    bss_length: u32,
    entry: u32,
    external_libraries_amount: u16,
    alignment: u8,
    _reserved: u8,
    version_major: u16,
    version_minor: u16,
    symbol_table_relocations_amount: u16,
    local_relocations_amount: u16,
    data_relocations_amount: u16,
    _reserved2: u16,
    exported_symbols_amount: u16,
    imported_symbols_amount: u16,
};

comptime {
    const std = @import("std");
    var buf: [30]u8 = undefined;
    if (@sizeOf(Header) != 48) @compileError("Header has incorrect size: " ++ (std.fmt.bufPrint(&buf, "{d}", .{@sizeOf(Header)}) catch "unknown"));
}
