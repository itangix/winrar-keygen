const std = @import("std");
const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;
const Limb = std.math.big.Limb;

pub const Element = [17]u16;

const ORDER_HEX = "1026dd85081b82314691ced9bbec30547840e4bf72d8b5e0d258442bbcd31";
const PRIV_HEX = "59fe6abcca90bdb95f0105271fa85fb9f11f467450c1ae9044b7fd61d65e";

// GF(2^15) log/exp tables, generator x with modulus x^15 + x + 1.
// Populated once by `initTables` (before any field arithmetic).
var EXP: [0x8000]u16 = undefined;
var LOG: [0x8000]u16 = undefined;
var tables_ready = false;

pub fn initTables() void {
    if (tables_ready) return;
    EXP[0] = 1;
    var i: usize = 1;
    while (i < 0x7fff) : (i += 1) {
        var temp: u32 = @as(u32, EXP[i - 1]) * 2;
        if (temp & 0x8000 != 0) temp ^= 0x8003;
        EXP[i] = @intCast(temp);
    }
    i = 0;
    while (i < 0x7fff) : (i += 1) {
        LOG[EXP[i]] = @intCast(i);
    }
    tables_ready = true;
}

fn zero() Element {
    return [_]u16{0} ** 17;
}

fn addAssign(a: *Element, b: *const Element) void {
    for (0..17) |i| a[i] ^= b[i];
}

fn add(a: *const Element, b: *const Element) Element {
    var r: Element = undefined;
    for (0..17) |i| r[i] = a[i] ^ b[i];
    return r;
}

fn eql(a: *const Element, b: *const Element) bool {
    return std.mem.eql(u16, a, b);
}

fn isZeroElement(a: *const Element) bool {
    for (a) |v| if (v != 0) return false;
    return true;
}

fn fullMul(m: usize, n: usize, out: []u16, a: []const u16, b: []const u16) void {
    @memset(out[0 .. m + n - 1], 0);
    for (0..m) |i| {
        if (a[i] == 0) continue;
        const la: u32 = LOG[a[i]];
        for (0..n) |j| {
            if (b[j] == 0) continue;
            var g = la + LOG[b[j]];
            if (g >= 0x7fff) g -= 0x7fff;
            out[i + j] ^= EXP[g];
        }
    }
}

// Modulus y^17 + y^3 + 1 over GF(2^15).
fn reduce(n: usize, a: []u16) void {
    var i = n;
    while (i > 17) {
        i -= 1;
        if (a[i] != 0) {
            a[i - 17] ^= a[i];
            a[i - 14] ^= a[i];
            a[i] = 0;
        }
    }
}

fn mul(r: *Element, a: *const Element, b: *const Element) void {
    var temp: [33]u16 = undefined;
    fullMul(17, 17, &temp, a, b);
    reduce(33, &temp);
    r.* = temp[0..17].*;
}

fn square(r: *Element, a: *const Element) void {
    var temp: [33]u16 = undefined;
    for (0..17) |i| {
        if (a[i] != 0) {
            var g: u32 = @as(u32, LOG[a[i]]) * 2;
            if (g >= 0x7fff) g -= 0x7fff;
            temp[2 * i] = EXP[g];
        } else {
            temp[2 * i] = 0;
        }
    }
    var k: usize = 1;
    while (k < 33) : (k += 2) temp[k] = 0;
    reduce(33, &temp);
    r.* = temp[0..17].*;
}

fn addScale(a: []u16, deg_a: *usize, alpha: u16, j: usize, b: []const u16, deg_b: usize) void {
    const log_alpha: u32 = LOG[alpha];
    for (0..deg_b + 1) |i| {
        if (b[i] != 0) {
            var g = log_alpha + LOG[b[i]];
            if (g >= 0x7fff) g -= 0x7fff;
            a[j + i] ^= EXP[g];
            if (a[j + i] != 0 and i + j > deg_a.*) deg_a.* = i + j;
        }
    }
    while (a[deg_a.*] == 0) deg_a.* -= 1;
}

fn inverse(result: *Element, a: *const Element) void {
    var B = [_]u16{0} ** 34;
    var C = [_]u16{0} ** 34;
    var F = [_]u16{0} ** 34;
    var G = [_]u16{0} ** 34;

    var deg_b: usize = 0;
    B[0] = 1;

    var deg_c: usize = 0;

    var deg_f: usize = 0;
    var is_zero = true;
    for (0..17) |i| {
        if (a[i] != 0) {
            is_zero = false;
            deg_f = i;
        }
        F[i] = a[i];
    }
    if (is_zero) @panic("Zero doesn't have inverse.");

    var deg_g: usize = 17;
    G[0] = 1;
    G[3] = 1;
    G[17] = 1;

    var pF: []u16 = &F;
    var pG: []u16 = &G;
    var pB: []u16 = &B;
    var pC: []u16 = &C;

    while (true) {
        if (deg_f == 0) {
            var i: usize = 0;
            while (i <= deg_b) : (i += 1) {
                if (pB[i] != 0) {
                    var g: i32 = @as(i32, LOG[pB[i]]) - @as(i32, LOG[pF[0]]);
                    if (g < 0) g += 0x7fff;
                    result[i] = EXP[@intCast(g)];
                } else {
                    result[i] = 0;
                }
            }
            while (i < 17) : (i += 1) result[i] = 0;
            break;
        }

        if (deg_f < deg_g) {
            std.mem.swap([]u16, &pF, &pG);
            std.mem.swap(usize, &deg_f, &deg_g);
            std.mem.swap([]u16, &pB, &pC);
            std.mem.swap(usize, &deg_b, &deg_c);
        }

        const j = deg_f - deg_g;
        var g: i32 = @as(i32, LOG[pF[deg_f]]) - @as(i32, LOG[pG[deg_g]]);
        if (g < 0) g += 0x7fff;
        const alpha = EXP[@intCast(g)];

        addScale(pF, &deg_f, alpha, j, pG, deg_g);
        addScale(pB, &deg_b, alpha, j, pC, deg_c);
    }
}

fn div(r: *Element, a: *const Element, b: *const Element) void {
    var inv: Element = undefined;
    inverse(&inv, b);
    mul(r, a, &inv);
}

// Pack 17 GF(2^15) coefficients LSB-first into 255 bits (32 bytes, little endian).
fn dumpField(v: *const Element, out: *[32]u8) void {
    @memset(out, 0);
    var bitpos: usize = 0;
    for (0..17) |i| {
        var val: u32 = v[i];
        var b: usize = 0;
        while (b < 15) : (b += 1) {
            if (val & 1 != 0) out[bitpos / 8] |= @as(u8, 1) << @intCast(bitpos % 8);
            val >>= 1;
            bitpos += 1;
        }
    }
}

const Point = struct {
    x: Element,
    y: Element,
};

const G_POINT: Point = .{
    .x = .{
        0x38CC, 0x052F, 0x2510, 0x45AA, 0x1B89, 0x4468, 0x4882, 0x0D67,
        0x4FEB, 0x55CE, 0x0025, 0x4CB7, 0x0CC2, 0x59DC, 0x289E, 0x65E3,
        0x56FD,
    },
    .y = .{
        0x31A7, 0x65F2, 0x18C4, 0x3412, 0x7388, 0x54C1, 0x539B, 0x4A02,
        0x4D07, 0x12D6, 0x7911, 0x3B5E, 0x4F0E, 0x216F, 0x2BF2, 0x1974,
        0x20DA,
    },
};

fn pointInfinity() Point {
    return .{ .x = zero(), .y = zero() };
}

fn pointIsInfinity(p: *const Point) bool {
    return isZeroElement(&p.x) and isZeroElement(&p.y);
}

fn pointDouble(p: *const Point) Point {
    if (pointIsInfinity(p)) return p.*;
    var inv: Element = undefined;
    inverse(&inv, &p.x);
    var m: Element = undefined;
    mul(&m, &p.y, &inv);
    addAssign(&m, &p.x);
    var newx: Element = undefined;
    square(&newx, &m);
    addAssign(&newx, &m);
    var mp1 = m;
    mp1[0] ^= 1;
    var newy: Element = undefined;
    mul(&newy, &mp1, &newx);
    var xs: Element = undefined;
    square(&xs, &p.x);
    addAssign(&newy, &xs);
    return .{ .x = newx, .y = newy };
}

fn pointAdd(p: *const Point, q: *const Point) Point {
    if (pointIsInfinity(p)) return q.*;
    if (pointIsInfinity(q)) return p.*;
    if (eql(&p.x, &q.x)) {
        if (eql(&p.y, &q.y)) return pointDouble(p);
        return pointInfinity();
    }
    var num = add(&p.y, &q.y);
    var den = add(&p.x, &q.x);
    var inv: Element = undefined;
    inverse(&inv, &den);
    var m: Element = undefined;
    mul(&m, &num, &inv);
    var newx: Element = undefined;
    square(&newx, &m);
    addAssign(&newx, &m);
    addAssign(&newx, &p.x);
    addAssign(&newx, &q.x);
    var t = add(&p.x, &newx);
    mul(&t, &t, &m);
    addAssign(&t, &newx);
    addAssign(&t, &p.y);
    return .{ .x = newx, .y = t };
}

// Scalar multiplication reading bits LSB-first from a little-endian scalar.
fn pointMulBytes(p: *const Point, bytes: []const u8) Point {
    var result = pointInfinity();
    var temp = p.*;
    const total_bits = bytes.len * 8;
    var i: usize = 0;
    while (i < total_bits) : (i += 1) {
        if ((bytes[i >> 3] >> @intCast(i & 7)) & 1 != 0) {
            result = pointAdd(&result, &temp);
        }
        temp = pointDouble(&temp);
    }
    return result;
}

fn intFromLEBytes(gpa: Allocator, bytes: []const u8) !Managed {
    var m = try Managed.init(gpa);
    errdefer m.deinit();
    const limb_bits = @bitSizeOf(Limb);
    const nlimbs = (bytes.len * 8 + limb_bits - 1) / limb_bits;
    try m.ensureCapacity(nlimbs + 1);
    var mm = m.toMutable();
    mm.readTwosComplement(bytes, bytes.len * 8, .little, .unsigned);
    m.setMetadata(mm.positive, mm.len);
    return m;
}

fn modInPlace(gpa: Allocator, r: *Managed, m: *const Managed) !void {
    var q = try Managed.init(gpa);
    defer q.deinit();
    try Managed.divFloor(&q, r, r, m);
}

fn generatePrivateKey(seed: []const u8) [15]u16 {
    var gen: [24]u8 = undefined;

    if (seed.len != 0) {
        var d: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(seed, &d, .{});
        for (0..5) |i| {
            const w = @byteSwap(std.mem.readInt(u32, d[4 * i ..][0..4], .little));
            std.mem.writeInt(u32, gen[4 * (i + 1) ..][0..4], w, .little);
        }
    } else {
        const constants = [5]u32{ 0xeb3eb781, 0x50265329, 0xdc5ef4a3, 0x6847b9d5, 0xcde43b4c };
        for (constants, 0..) |c, i| {
            std.mem.writeInt(u32, gen[4 * (i + 1) ..][0..4], c, .little);
        }
    }

    var raw: [15]u16 = undefined;
    for (0..15) |i| {
        std.mem.writeInt(u32, gen[0..4], @intCast(i + 1), .little);
        var d: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(&gen, &d, .{});
        raw[i] = @truncate(@byteSwap(std.mem.readInt(u32, d[0..4], .little)));
    }
    return raw;
}

fn hashInt(gpa: Allocator, message: []const u8) !Managed {
    var d: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(message, &d, .{});
    var raw: [30]u8 = undefined;
    for (0..5) |i| {
        const w = @byteSwap(std.mem.readInt(u32, d[4 * i ..][0..4], .little));
        std.mem.writeInt(u32, raw[4 * i ..][0..4], w, .little);
    }
    std.mem.writeInt(u32, raw[20..24], 0x0ffd8d43, .little);
    std.mem.writeInt(u32, raw[24..28], 0xb4e33c7c, .little);
    std.mem.writeInt(u16, raw[28..30], @truncate(@as(u32, 0x53461bd1)), .little);
    return intFromLEBytes(gpa, &raw);
}

pub const RegisterInfo = struct {
    user_name: []const u8,
    license_type: []const u8,
    uid: []const u8,
    items: [4][]const u8,
    checksum: u32,
    hex_data: []const u8,
};

const Sig = struct {
    r: Managed,
    s: Managed,
};

pub const Keygen = struct {
    gpa: Allocator,
    order: Managed,
    priv: Managed,

    pub fn init(gpa: Allocator) !Keygen {
        initTables();
        var order = try Managed.init(gpa);
        errdefer order.deinit();
        try order.setString(16, ORDER_HEX);
        var priv = try Managed.init(gpa);
        errdefer priv.deinit();
        try priv.setString(16, PRIV_HEX);
        return .{ .gpa = gpa, .order = order, .priv = priv };
    }

    pub fn deinit(self: *Keygen) void {
        self.order.deinit();
        self.priv.deinit();
    }

    fn sm2Compressed(self: *Keygen, arena: Allocator, message: []const u8) ![]u8 {
        const raw = generatePrivateKey(message);
        var keybytes: [30]u8 = undefined;
        for (0..15) |i| {
            std.mem.writeInt(u16, keybytes[2 * i ..][0..2], raw[i], .little);
        }

        const p = pointMulBytes(&G_POINT, &keybytes);

        var xb: [32]u8 = undefined;
        dumpField(&p.x, &xb);

        var inv: Element = undefined;
        inverse(&inv, &p.x);
        var z: Element = undefined;
        mul(&z, &p.y, &inv);

        var x = try intFromLEBytes(self.gpa, &xb);
        defer x.deinit();
        var x2 = try Managed.init(self.gpa);
        defer x2.deinit();
        try Managed.shiftLeft(&x2, &x, 1);
        if (z[0] & 1 != 0) {
            var one = try Managed.initSet(self.gpa, 1);
            defer one.deinit();
            try Managed.add(&x2, &x2, &one);
        }

        const hex = try x2.toString(self.gpa, 16, .lower);
        defer self.gpa.free(hex);

        const out = try arena.alloc(u8, 64);
        @memset(out, '0');
        @memcpy(out[64 - hex.len ..], hex);
        return out;
    }

    fn signOnce(self: *Keygen, rng: std.Random, data: []const u8) !Sig {
        var hash = try hashInt(self.gpa, data);
        defer hash.deinit();

        while (true) {
            var rawbytes: [30]u8 = undefined;
            rng.bytes(&rawbytes);
            var random = try intFromLEBytes(self.gpa, &rawbytes);

            const p = pointMulBytes(&G_POINT, &rawbytes);
            var xb: [32]u8 = undefined;
            dumpField(&p.x, &xb);

            var r = try intFromLEBytes(self.gpa, &xb);
            try Managed.add(&r, &r, &hash);
            try modInPlace(self.gpa, &r, &self.order);
            if (Managed.eqlZero(r)) {
                r.deinit();
                random.deinit();
                continue;
            }

            var sum = try Managed.init(self.gpa);
            defer sum.deinit();
            try Managed.add(&sum, &r, &random);
            if (Managed.eql(sum, self.order)) {
                r.deinit();
                random.deinit();
                continue;
            }

            var prod = try Managed.init(self.gpa);
            defer prod.deinit();
            try Managed.mul(&prod, &self.priv, &r);

            var s = try Managed.init(self.gpa);
            try Managed.sub(&s, &random, &prod);
            try modInPlace(self.gpa, &s, &self.order);
            random.deinit();

            if (Managed.eqlZero(s)) {
                r.deinit();
                s.deinit();
                continue;
            }

            return .{ .r = r, .s = s };
        }
    }

    fn signHex(self: *Keygen, rng: std.Random, arena: Allocator, data: []const u8) !struct { r: []const u8, s: []const u8 } {
        while (true) {
            var sig = try self.signOnce(rng, data);
            const rh = try sig.r.toString(self.gpa, 16, .lower);
            defer self.gpa.free(rh);
            const sh = try sig.s.toString(self.gpa, 16, .lower);
            defer self.gpa.free(sh);
            if (rh.len <= 60 and sh.len <= 60) {
                const rpad = try arena.alloc(u8, 60);
                @memset(rpad, '0');
                @memcpy(rpad[60 - rh.len ..], rh);
                const spad = try arena.alloc(u8, 60);
                @memset(spad, '0');
                @memcpy(spad[60 - sh.len ..], sh);
                sig.r.deinit();
                sig.s.deinit();
                return .{ .r = rpad, .s = spad };
            }
            sig.r.deinit();
            sig.s.deinit();
        }
    }

    fn calculateChecksum(self: *Keygen, info: *const RegisterInfo) u32 {
        _ = self;
        var crc = std.hash.crc.Crc32.init();
        crc.update(info.license_type);
        crc.update(info.user_name);
        for (info.items) |item| crc.update(item);
        return crc.final() ^ 0xFFFF_FFFF;
    }

    pub fn generateRegisterInfo(self: *Keygen, rng: std.Random, arena: Allocator, username: []const u8, license: []const u8) !RegisterInfo {
        var info: RegisterInfo = undefined;
        info.user_name = username;
        info.license_type = license;

        const temp = try self.sm2Compressed(arena, username);
        const item3 = try std.fmt.allocPrint(arena, "60{s}", .{temp[0..48]});
        const item0 = try self.sm2Compressed(arena, item3);
        const uid = try std.fmt.allocPrint(arena, "{s}{s}", .{ temp[48..64], item0[0..4] });

        const license_sig = try self.signHex(rng, arena, license);
        const item1 = try std.fmt.allocPrint(arena, "60{s}{s}", .{ license_sig.s, license_sig.r });

        const user_data = try std.fmt.allocPrint(arena, "{s}{s}", .{ username, item0 });
        const user_sig = try self.signHex(rng, arena, user_data);
        const item2 = try std.fmt.allocPrint(arena, "60{s}{s}", .{ user_sig.s, user_sig.r });

        info.items = .{ item0, item1, item2, item3 };
        info.uid = uid;
        info.checksum = self.calculateChecksum(&info);

        info.hex_data = try std.fmt.allocPrint(
            arena,
            "{d}{d}{d}{d}{s}{s}{s}{s}{d:0>10}",
            .{ item0.len, item1.len, item2.len, item3.len, item0, item1, item2, item3, info.checksum },
        );

        std.debug.assert(info.hex_data.len % 54 == 0);
        return info;
    }
};

test "sm2 compressed deterministic vectors" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var kg = try Keygen.init(gpa);
    defer kg.deinit();

    const temp = try kg.sm2Compressed(arena, "Github");
    try std.testing.expectEqualStrings("3a3d02329a32b63d", temp[48..64]);

    const item3 = try std.fmt.allocPrint(arena, "60{s}", .{temp[0..48]});
    const item0 = try kg.sm2Compressed(arena, item3);
    try std.testing.expectEqualStrings(
        "a7d8753c5e7037d83011171578c57042fa30c506caae9954e4853d415ec594e4",
        item0,
    );
}

test "signature is self-consistent" {
    const gpa = std.testing.allocator;
    var kg = try Keygen.init(gpa);
    defer kg.deinit();

    var prng = std.Random.DefaultPrng.init(0x1234_5678);
    const rng = prng.random();

    const msg = "test";
    var sig = try kg.signOnce(rng, msg);
    defer sig.r.deinit();
    defer sig.s.deinit();

    var hash = try hashInt(gpa, msg);
    defer hash.deinit();

    // Recover k = s + r * priv mod n, then check (x(k*G) + hash) mod n == r.
    var prod = try Managed.init(gpa);
    defer prod.deinit();
    try Managed.mul(&prod, &kg.priv, &sig.r);
    var k = try Managed.init(gpa);
    defer k.deinit();
    try Managed.add(&k, &sig.s, &prod);
    try modInPlace(gpa, &k, &kg.order);

    var buf: [32]u8 = undefined;
    @memset(&buf, 0);
    k.toConst().writeTwosComplement(&buf, .little);
    const p = pointMulBytes(&G_POINT, &buf);

    var xb: [32]u8 = undefined;
    dumpField(&p.x, &xb);
    var x = try intFromLEBytes(gpa, &xb);
    defer x.deinit();

    var sum = try Managed.init(gpa);
    defer sum.deinit();
    try Managed.add(&sum, &x, &hash);
    try modInPlace(gpa, &sum, &kg.order);

    try std.testing.expectEqual(std.math.Order.eq, Managed.order(sum, sig.r));
}

test "crc32 checksum matches reference convention" {
    // std Crc32.hash returns zlib crc32 (final xor applied); the keygen uses the
    // pre-final-xor value. 1808088940 is what the C++ HasherCrc32Traits chain
    // produces for "abc"+"defg"+"hij"+"kl"+""+"mnop".
    try std.testing.expectEqual(@as(u32, 1808088940), std.hash.crc.Crc32.hash("abcdefghijklmnop") ^ 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x340BC6D9), std.hash.crc.Crc32.hash("123456789") ^ 0xFFFF_FFFF);
}
