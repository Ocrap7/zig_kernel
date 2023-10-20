const std = @import("std");

const Node = struct {
    tag: Tag,
    name: Path,
    data: Data,

    pub const Tag = enum {
        Root,
        File,
        Directory,
        Device,
    };

    pub const Data = union {
        file: []u8,
        directory: struct {
            children: std.StringHashMap(FileSystem.NodeIndex),
        },
    };

    pub fn resolve(self: *const Node, fs: *const FileSystem, name: []const u8) ?*Node {
        switch (self.tag) {
            .File => {
                if (std.mem.eql(u8, self.name.path, name)) {
                    return self;
                } else {
                    return null;
                }
            },
            .Directory => {
                const index = self.data.directory.children.get(name) orelse return null;
                return fs.nodes.items[index];
            },
            else => return null
        }
    }

    pub fn deinit(self: *Node) void {
        switch (self.tag) {
            .Directory, .Root => {
                self.data.directory.children.deinit();
            },
            else => {}
        }
    }
};

const Path = struct {
    path: []u8,

    pub fn create(allocator: std.mem.Allocator, value: []const u8) !Path {
        const value_alloc= try allocator.dupe(u8, value);
        return .{
            .path = value_alloc,
        };
    }

    pub const Iter = std.mem.SplitIterator(u8, .scalar);

    pub fn iter(self: *const Path) Iter {
        return std.mem.splitScalar(u8, self.path, '/');
    }
};

const FileSystem = struct {
    nodes: std.ArrayList(Node),
    root: NodeIndex,

    paths: std.StringHashMap(NodeIndex),
    pool: std.heap.ArenaAllocator,

    pub const NodeIndex = usize;
    pub const PathIndex = usize;

    pub fn init(allocator: std.mem.Allocator) !FileSystem {
        var pool = std.heap.ArenaAllocator.init(allocator);

        var nodes = std.ArrayList(Node).init(pool.allocator());

        var fs = FileSystem{
            .nodes = nodes,
            .root = 0,
            .paths = std.StringHashMap(NodeIndex).init(pool.allocator()),
            .pool = pool,
        };
        
        const path = try Path.create(pool.allocator(), "root");

        try fs.addNode(.{
            .name = path,
            .tag = .Root,
            .data = .{
                .directory = .{
                    .children = std.StringHashMap(NodeIndex).init(pool.allocator()),
                }
            },
        }, path);

        return fs;
    }

    pub fn addNode(self: *FileSystem, node: Node, path_segment: Path) !void {
        const index = self.nodes.items.len;
        try self.nodes.append(node);
        try self.paths.put(path_segment.path, index);
    }

    pub fn resolve(self: *const FileSystem, path: Path) ?*Node {

        const root_node = &self.nodes.items[self.root];

        for (root_node.data.directory.children) |child_node| {
            _ = child_node;

            if (self.resolve_node(root_node, path.iter())) |found_node| {
                return found_node;
            }
        }

        return null;
    }

    fn resolve_node(self: *const FileSystem, node: *const Node, path_iter: *Path.Iter) ?*Node {
        const name = path_iter.next() orelse return null;

        if (node.resolve(self, name)) |child_node| {
            if (path_iter.peek()) |_| return self.resolve_node(child_node, path_iter)
            else {
                return child_node;
            }
        } else {
            if (path_iter.peek()) |_| {
                return self;
            } else  {
                return null;
            }
        }
    }

    pub fn deinit(self: *FileSystem) void {
        for (self.nodes.items) |*node| {
            _ = node;
            std.debug.print("Deinit node ", .{});
            // node.deinit();
        }

        self.pool.deinit();
    }
};

test "fs" {
    // const std = @import("std");

    // var allocator = std.testing.allocator
    var fs = try FileSystem.init(std.testing.allocator);
    defer fs.deinit();

    std.debug.print("{any}", .{fs});
}