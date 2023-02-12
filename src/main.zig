// Copyright (c) 2022 Richard Palethorpe <io@richiejp.com>

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

const std = @import("std");
const net = std.net;
const mem = std.mem;
const fs = std.fs;
const io = std.io;

const BUFSIZ = 8196;

const ServeFileError = error{
    RecvHeaderEOF,
    RecvHeaderExceededBuffer,
    HeaderDidNotMatch,
};

fn serveFile(stream: *const net.Stream, dir: fs.Dir) !void {
    var recv_buf: [BUFSIZ]u8 = undefined;
    var recv_total: usize = 0;

    while (stream.read(recv_buf[recv_total..])) |recv_len| {
        if (recv_len == 0)
            return ServeFileError.RecvHeaderEOF;

        recv_total += recv_len;

        if (mem.containsAtLeast(u8, recv_buf[0..recv_total], 1, "\r\n\r\n"))
            break;

        if (recv_total >= recv_buf.len)
            return ServeFileError.RecvHeaderExceededBuffer;
    } else |read_err| {
        return read_err;
    }

    const recv_slice = recv_buf[0..recv_total];
    std.log.info(" <<<\n{s}", .{recv_slice});

    var file_path: []const u8 = undefined;
    var tok_itr = mem.tokenize(u8, recv_slice, " ");

    if (!mem.eql(u8, tok_itr.next() orelse "", "GET"))
        return ServeFileError.HeaderDidNotMatch;

    const path = tok_itr.next() orelse "";
    if (path[0] != '/')
        return ServeFileError.HeaderDidNotMatch;

    if (mem.eql(u8, path, "/"))
        file_path = "index"
    else
        file_path = path[1..];

    if (!mem.startsWith(u8, tok_itr.rest(), "HTTP/1.1\r\n"))
        return ServeFileError.HeaderDidNotMatch;

    var file_ext = fs.path.extension(file_path);
    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;

    if (file_ext.len == 0) {
        var path_fbs = io.fixedBufferStream(&path_buf);

        try path_fbs.writer().print("{s}.html", .{file_path});
        file_ext = ".html";
        file_path = path_fbs.getWritten();
    }

    std.log.info("Opening {s}", .{file_path});

    var body_file = dir.openFile(file_path, .{}) catch |err| {
        const http_404 = "HTTP/1.1 404 Not Found\r\n\r\n404";
        std.log.info(" >>>\n" ++ http_404, .{});
        try stream.writer().print(http_404, .{});
        return err;
    };
    defer body_file.close();

    const file_len = try body_file.getEndPos();

    const http_head =
        "HTTP/1.1 200 OK\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n";
    const mimes = .{
        .{ ".html", "text/html" },
        .{ ".css", "text/css" },
        .{ ".map", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".jpg", "image/jpg" },
        .{ ".png", "image/png" },
        .{ ".wasm", "application/wasm" },
    };
    var mime: []const u8 = "text/plain";

    inline for (mimes) |kv| {
        if (mem.eql(u8, file_ext, kv[0]))
            mime = kv[1];
    }

    std.log.info(" >>>\n" ++ http_head, .{ mime, file_len });
    try stream.writer().print(http_head, .{ mime, file_len });

    const zero_iovec = &[0]std.os.iovec_const{};
    var send_total: usize = 0;

    while (true) {
        const send_len = try std.os.sendfile(
            stream.handle,
            body_file.handle,
            send_total,
            file_len,
            zero_iovec,
            zero_iovec,
            0,
        );

        if (send_len == 0)
            break;

        send_total += send_len;
    }
}

pub fn main() anyerror!void {
    var args = std.process.args();
    const exe_name = args.next() orelse "zelf-zerve";
    const public_path = args.next() orelse {
        std.log.err("Usage: {s} <dir to serve files from>", .{exe_name});
        return;
    };

    var dir = try fs.cwd().openDir(public_path, .{});
    const self_addr = try net.Address.resolveIp("127.0.0.1", 9000);
    var listener = net.StreamServer.init(.{});
    try (&listener).listen(self_addr);

    std.log.info("Listening on http://{}; press Ctrl-C to exit...", .{self_addr});

    while ((&listener).accept()) |conn| {
        std.log.info("Accepted Connection from: {}", .{conn.address});

        serveFile(&conn.stream, dir) catch |err| {
            if (@errorReturnTrace()) |bt| {
                std.log.err("Failed to serve client: {}: {}", .{ err, bt });
            } else {
                std.log.err("Failed to serve client: {}", .{err});
            }
        };

        conn.stream.close();
    } else |err| {
        return err;
    }
}
