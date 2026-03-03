const std = @import("std");
const spider = @import("spider");
const Allocator = std.mem.Allocator;

const index_view = @embedFile("views/index.html");

const _users_integration_test = @import("db/users_integration_test.zig");
const _user_controller_integration_test = @import("controllers/user_controller_integration_test.zig");

const db = @import("db/conn.zig");
const users_db = @import("db/users.zig");
const user_routes = @import("routes/users.zig");

var user_router: user_routes.UserRouter = undefined;

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
var user_pool: db.Pool = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    repo = try ContactRepository.init(allocator);

    try repo.add("Jon", "jon@gmail.com");
    try repo.add("Maylla", "maylla@gmail.com");

    user_pool = try db.connect(allocator);
    user_router = user_routes.UserRouter.init(allocator, &user_pool);

    var app = try spider.Spider.init(allocator, io, "0.0.0.0", 8080);
    defer app.deinit();

    app.get("/up", handleUp)
        .get("/", indexController)
        .post("/contacts", createContact)
        .get("/users/register", registerPageHandler)
        .post("/users/register", registerHandler)
        .get("/home", homeHandler)
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

fn registerPageHandler(alc: Allocator, req: *spider.Request) !spider.Response {
    _ = alc;
    return try user_router.registerPage(req);
}

fn registerHandler(alc: Allocator, req: *spider.Request) !spider.Response {
    return try user_router.register(alc, req);
}

fn homeHandler(alc: Allocator, req: *spider.Request) !spider.Response {
    return try user_router.home(alc, req);
}
