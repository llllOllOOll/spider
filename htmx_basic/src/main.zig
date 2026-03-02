const std = @import("std");
const spider = @import("spider");
const Allocator = std.mem.Allocator;

const index_view = @embedFile("views/index.html");

const Contact = struct {
    name: []const u8,
    email: []const u8,
};

const Data = struct {
    contacts: []const Contact,
};

const ContactRepository = struct {
    allocator: Allocator,
    contacts: std.ArrayList(Contact),

    fn init(allocator: Allocator) !ContactRepository {
        return .{
            .allocator = allocator,
            .contacts = std.ArrayList(Contact).empty,
        };
    }

    fn deinit(self: *ContactRepository) void {
        for (self.contacts.items) |contact| {
            self.allocator.free(contact.name);
            self.allocator.free(contact.email);
        }
        self.contacts.deinit(self.allocator);
    }

    fn add(self: *ContactRepository, name: []const u8, email: []const u8) !void {
        const name_owned = try self.allocator.dupe(u8, name);
        const email_owned = try self.allocator.dupe(u8, email);
        try self.contacts.append(self.allocator, .{ .name = name_owned, .email = email_owned });
    }
};

var repo: ContactRepository = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    repo = try ContactRepository.init(allocator);

    try repo.add("Jon", "jon@gmail.com");
    try repo.add("Maylla", "maylla@gmail.com");

    var app = try spider.Spider.init(allocator, io, "0.0.0.0", 8080);
    defer app.deinit();

    app.get("/up", handleUp)
        .get("/", indexController)
        .post("/contacts", createContact)
        .listen() catch |err| return err;
}

fn indexController(alc: Allocator, req: *spider.Request) !spider.Response {
    _ = req;
    const data = Data{ .contacts = repo.contacts.items };
    return try spider.renderBlock(alc, index_view, "index", data);
}

fn createContact(alc: Allocator, req: *spider.Request) !spider.Response {
    const name = (try req.formParam("name", alc)) orelse "";
    const email = (try req.formParam("email", alc)) orelse "";

    try repo.add(name, email);

    const data = Data{ .contacts = repo.contacts.items };
    return try spider.renderBlock(alc, index_view, "display", data);
}

fn handleUp(alc: Allocator, req: *spider.Request) !spider.Response {
    _ = req;
    return try spider.Response.text(alc, "OK");
}

// const std = @import("std");
// const Allocator = std.mem.Allocator;
//
// const spider = @import("spider");
//
// const indexView: []const u8 = @embedFile("views/index.html");
//
// pub fn main(init: std.process.Init) !void {
//     const io = init.io;
//     const alc = init.gpa;
//
//     const s = try spider.Spider.init(alc, io, "127.0.0.1", 8088);
//
//     s.get("/up", handleUp)
//         .get("/", indexController)
//         .post("/count", updateCounter)
//         .post("/users", userCreate)
//         .listen() catch |err| return err;
// }
//
// const Contact = struct {
//     name: []const u8,
//     email: []const u8,
// };
//
// fn newContact(name: []const u8, email: []const u8) Contact {
//     return .{
//         .name = name,
//         .email = email,
//     };
// }
//
// type Contacts = []Contact;
//
// type Data = struct {
//     Contacts : contacts,
// };
//
// fn newData() Data{
//     return Contact: []Contacts{
//         newContact("Jon", "ss@gmail.com"),
//     }
// }
//
// const Count = struct {
//     count: i32,
// };
//
// var count: Count = .{ .count = 0 };
//
// fn indexController(alc: Allocator, req: *spider.Request) !spider.Response {
//     _ = req;
//     return try spider.renderBlock(alc, indexView, "index", count);
// }
//
// fn updateCounter(alc: Allocator, req: *spider.Request) !spider.Response {
//     _ = req;
//     count.count += 1;
//     return try spider.renderBlock(alc, indexView, "count", count);
// }
//
// const Count = struct {
//     count: i32,
// };
//
// var count: Count = Count{ .count = 1 };
//
// fn indexController(alc: Allocator, req: *spider.Request) !spider.Response {
//     _ = req;
//
//     return try spider.render(alc, indexView, count);
// }
//
// fn updateCounter(alc: Allocator, req: *spider.Request) !spider.Response {
//     _ = req;
//
//     count.count += 1;
//
//     return try spider.render(alc, indexView, count);
// }

// fn userController(alc: Allocator, req: *spider.Request) !spider.Response {
//     _ = req;
//
//     const users = [_]User{ .{ .name = "Seven" }, .{ .name = "Maylla" } };
//     return try spider.render(alc, indexView, users);
// }
//
// fn userCreate(alc: Allocator, req: *spider.Request) !spider.Response {
//     const name = try req.formParam("name", alc) orelse "";
//     const email = try req.formParam("email", alc) orelse "";
//
//     std.debug.print("name: {s} email: {s}\n", .{ name, email });
//     return spider.Response.text(alc, "OK");
// }
//
// const User = struct {
//     name: []const u8,
// };
//
// fn handleUp(alc: Allocator, req: *spider.Request) !spider.Response {
//     _ = req;
//     return try spider.Response.text(alc, "OK");
// }
