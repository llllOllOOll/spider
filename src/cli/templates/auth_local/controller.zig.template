const std = @import("std");
const spider = @import("spider");
const model = @import("model.zig");
const repository = @import("repository.zig");
const Response = spider.Response;

// Login with the app's own users. A password is stored as a hash
// (spider.password) and a login is a signed cookie (spider.session): the
// middleware in src/main.zig reads it on every request and tells the
// routes who is there. Nothing here talks to another service.

pub fn loginForm(c: *spider.Ctx) !Response {
    return loginPage(c, "", null);
}

pub fn login(c: *spider.Ctx) !Response {
    const form = try c.parseForm(model.Credentials);
    const email = try model.tidyEmail(c.arena, form.email);
    const user = try repository.findByEmail(c.arena, email);

    // An account that does not exist is checked against a decoy hash, so
    // it takes as long to refuse as a wrong password, and both get the
    // same message: neither tells a stranger which emails have accounts.
    const stored = if (user) |u| u.password_hash else spider.password.decoy;
    const matches = spider.password.verify(c, stored, form.password);
    if (user == null or !matches) return loginPage(c, email, "Wrong email or password.");

    return signIn(c, user.?);
}

pub fn registerForm(c: *spider.Ctx) !Response {
    return registerPage(c, .{}, null);
}

/// Anyone can create an account. To close registration, remove the two
/// /auth/register routes from routes.zig (and the link in login.html).
pub fn register(c: *spider.Ctx) !Response {
    const form = try model.tidy(c.arena, try c.parseForm(model.Registration));
    if (model.problem(form)) |what| return registerPage(c, form, what);
    if (try repository.findByEmail(c.arena, form.email) != null) {
        return registerPage(c, form, "That email already has an account. Sign in instead.");
    }

    const hash = try spider.password.hash(c, form.password);
    const user = try repository.create(c.arena, form.name, form.email, hash);
    return signIn(c, user);
}

pub fn logout(c: *spider.Ctx) !Response {
    return c.redirectWith("/auth/login", try spider.session.end(c));
}

/// Who is signed in. Only reachable with a session (see routes.zig).
pub fn account(c: *spider.Ctx) !Response {
    return c.view("auth/account", .{
        .title = "Your account",
        .name = c.params.get("_auth_name") orelse "",
        .email = c.params.get("_auth_email") orelse "",
    }, .{});
}

/// Starts the session and goes to the home page.
fn signIn(c: *spider.Ctx, user: model.User) !Response {
    return c.redirectWith("/", try spider.session.start(c, .{
        .id = try std.fmt.allocPrint(c.arena, "{d}", .{user.id}),
        .email = user.email,
        .name = user.name,
        .roles = &.{user.role},
    }));
}

fn loginPage(c: *spider.Ctx, email: []const u8, problem: ?[]const u8) !Response {
    return c.view("auth/login", .{
        .title = "Sign in",
        .email = email,
        .problem = problem orelse "",
    }, .{ .status = if (problem == null) .ok else .unprocessable_entity });
}

fn registerPage(c: *spider.Ctx, form: model.Registration, problem: ?[]const u8) !Response {
    return c.view("auth/register", .{
        .title = "Create an account",
        .name = form.name,
        .email = form.email,
        .problem = problem orelse "",
    }, .{ .status = if (problem == null) .ok else .unprocessable_entity });
}
