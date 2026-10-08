//! What `spider <args>` should do, decided before anything runs.
//!
//! Help is checked first, anywhere on the line: `spider new --help` used to
//! create a project named "--help", and commands that take no arguments
//! (migrate, self-update) ignored the flag and ran. Unknown commands and
//! options are errors (exit 2) instead of being printed with exit 0 or
//! taken as an app name.

const std = @import("std");

pub const Command = enum {
    new,
    generate,
    migrate,
    routes,
    ui,
    icons,
    add,
    remove,
    check,
    dev,
    install,
    update,
    self_update,
    generate_vapid,
    version,
    help,

    pub fn fromName(name: []const u8) ?Command {
        const map = [_]struct { []const u8, Command }{
            .{ "new", .new },
            .{ "generate", .generate },
            .{ "g", .generate },
            .{ "migrate", .migrate },
            .{ "routes", .routes },
            .{ "ui", .ui },
            .{ "icons", .icons },
            .{ "add", .add },
            .{ "remove", .remove },
            .{ "check", .check },
            .{ "dev", .dev },
            .{ "install", .install },
            .{ "update", .update },
            .{ "self-update", .self_update },
            .{ "generate-vapid", .generate_vapid },
            .{ "version", .version },
            .{ "--version", .version },
            .{ "-v", .version },
            .{ "help", .help },
        };
        for (map) |m| if (std.mem.eql(u8, name, m[0])) return m[1];
        return null;
    }
};

pub const Action = union(enum) {
    /// Usage text: the overview (null) or one command's.
    help: ?Command,
    version,
    run: Command,
    unknown_command: []const u8,
};

pub fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// `args` excludes the program name.
pub fn decide(args: []const []const u8) Action {
    if (args.len == 0) return .{ .help = null };
    if (isHelpFlag(args[0])) return .{ .help = null };
    const cmd = Command.fromName(args[0]) orelse return .{ .unknown_command = args[0] };
    switch (cmd) {
        // `spider help new` -> help for `new`
        .help => return .{ .help = if (args.len > 1) Command.fromName(args[1]) else null },
        .version => return .version,
        else => {},
    }
    for (args[1..]) |a| if (isHelpFlag(a)) return .{ .help = cmd };
    return .{ .run = cmd };
}

pub const NewOptions = struct {
    app_name: []const u8,
    /// UI kit name (ui.zig kits): --ui=<kit>.
    ui: []const u8 = @import("ui.zig").default_kit,
    /// --daisyui was given: an alias of --ui=daisyui (the default), kept
    /// for old scripts.
    daisyui_alias: bool = false,
    pwa: bool = false,
    skip_downloads: bool = false,
    api: bool = false,
    no_db: bool = false,
    pg: bool = false,
};

pub const NewError = error{ MissingAppName, UnknownOption, ExtraArgument, UnknownUiKit, PwaNeedsViews };

/// `args` are the ones after `new`. `bad` receives the offending argument.
pub fn parseNew(args: []const []const u8, bad: *[]const u8) NewError!NewOptions {
    var o: NewOptions = .{ .app_name = "" };
    for (args) |a| {
        if (std.mem.eql(u8, a, "--daisyui")) {
            o.ui = "daisyui";
            o.daisyui_alias = true;
        } else if (std.mem.startsWith(u8, a, "--ui=")) {
            o.ui = a["--ui=".len..];
            if (@import("ui.zig").find(o.ui) == null) {
                bad.* = a;
                return error.UnknownUiKit;
            }
        } else if (std.mem.eql(u8, a, "--pwa")) {
            o.pwa = true;
        } else if (std.mem.eql(u8, a, "--skip-downloads")) {
            o.skip_downloads = true;
        } else if (std.mem.eql(u8, a, "--api")) {
            o.api = true;
        } else if (std.mem.eql(u8, a, "--no-db")) {
            o.no_db = true;
        } else if (std.mem.eql(u8, a, "--pg")) {
            o.pg = true;
        } else if (a.len > 0 and a[0] == '-') {
            bad.* = a;
            return error.UnknownOption;
        } else if (o.app_name.len > 0) {
            bad.* = a;
            return error.ExtraArgument;
        } else {
            o.app_name = a;
        }
    }
    if (o.app_name.len == 0) return error.MissingAppName;
    if (o.pwa and o.api) {
        bad.* = "--pwa";
        return error.PwaNeedsViews;
    }
    return o;
}

pub const overview =
    \\Spider CLI — spiderme.org
    \\
    \\Usage: spider <command> [options]
    \\
    \\Commands:
    \\  new <app_name>        Create a new Spider project
    \\  generate, g           Generate code: feature <name>, auth
    \\  migrate               Run pending database migrations
    \\  routes                List the app's routes (method, path, access, flags)
    \\  ui                    Show or switch the UI kit (daisyui, tailwind)
    \\  icons                 Show, add or remove icon sets (heroicons, lucide, tabler)
    \\  add pwa               Make the app an installable PWA (manifest, service worker)
    \\  remove pwa            Remove the PWA (and unregister it from browsers)
    \\  check                 Check the app follows Spider's conventions (file:line + fix)
    \\  dev                   Build, run, and restart the app after every successful build
    \\  install               Download frontend assets (tailwindcss, alpine, htmx, icons)
    \\  update                Update the spider dependency in this project
    \\  self-update           Update the spider CLI itself
    \\  generate-vapid [sub]  Generate VAPID keys for Web Push
    \\  version               Show CLI version (also --version, -v)
    \\  help [command]        Show help (also --help, -h)
    \\
    \\Run `spider <command> --help` for a command's options.
    \\
;

pub fn commandHelp(cmd: Command) []const u8 {
    return switch (cmd) {
        .new =>
        \\Usage: spider new <app_name> [options]
        \\
        \\Create a new Spider project in ./<app_name> (HTML views + SQLite by default).
        \\
        \\Options:
        \\  --pg              Use PostgreSQL instead of SQLite
        \\  --no-db           No database
        \\  --api             API-only project (JSON, no HTML views)
        \\  --ui=<kit>        UI kit: daisyui (default) or tailwind (plain, no library).
        \\                    Switch later with `spider ui use <kit>`.
        \\  --daisyui         Same as --ui=daisyui (the default)
        \\  --pwa             Installable PWA: manifest, service worker, icons
        \\                    (same as `spider add pwa` afterwards)
        \\  --skip-downloads  Don't download tailwindcss, alpine, htmx, icons now
        \\
        ,
        .generate =>
        \\Usage: spider generate <subcommand> [options]   (alias: spider g)
        \\
        \\Subcommands:
        \\  feature <name> [--api]
        \\      CRUD feature: src/features/<name>/ (controller, model, repository,
        \\      views), a migration, routes in src/main.zig. --api for JSON.
        \\      Apply the migration with `spider migrate` before using it.
        \\  auth [--provider=keycloak] [--api]
        \\      Keycloak login (--api: bearer tokens only). For Google sign-in, add
        \\      Google as an identity provider of the Keycloak realm.
        \\
        ,
        .migrate =>
        \\Usage: spider migrate
        \\
        \\Apply pending migrations from src/core/db/migrations/*.sql (the
        \\"-- migrate:up" part), in order. Reads the database from .env:
        \\SQLITE_PATH for SQLite, PG_HOST/PG_PORT/PG_USER/PG_PASSWORD/PG_DB for
        \\PostgreSQL. Run it from the project root.
        \\
        ,
        .routes =>
        \\Usage: spider routes [--json | --check | --lock | --diff]
        \\
        \\Build and start the app with SPIDER_ROUTES set (`zig build run`): it lists
        \\every route — method, path, access (public / org: / roles: / -) and flags
        \\(quiet_log, allow_http) — and exits before listening. The app's startup
        \\code runs up to listen() (e.g. it connects to the database); features'
        \\boot() hooks don't run.
        \\
        \\Options:
        \\  --json   the listing as one line of JSON (with "auth": whether a login
        \\           middleware is installed)
        \\  --check  exit 1 if the app has auth and some route declares no access
        \\           ("-": any logged-in user may call it)
        \\  --lock   write routes.lock; commit it
        \\  --diff   compare with routes.lock: exit 1 and show what changed,
        \\           exit 2 if there is no routes.lock
        \\
        ,
        .ui =>
        \\Usage: spider ui [use <kit> [--force]]
        \\
        \\Templates use ui-* classes (ui-btn, ui-input, ui-card, ui-menu, ...)
        \\defined in src/ui.css; only that file knows the UI kit. Without
        \\arguments: the kit in use and the available ones.
        \\
        \\  use <kit>   rewrite src/ui.css for <kit>: daisyui (daisyUI 5) or
        \\              tailwind (plain Tailwind, same color names). Refuses if
        \\              you edited src/ui.css, unless --force. Lists template
        \\              lines that still use the old kit's classes directly.
        \\
        ,
        .icons =>
        \\Usage: spider icons [add|remove <set>]
        \\
        \\Icons are classes: <span class="hero-home size-5"></span>. Each set's
        \\SVGs are downloaded to bin/icons/<set>/ (spider install) and src/styles.css
        \\loads one @plugin per set. Without arguments: the sets in use.
        \\
        \\Sets: heroicons (hero-*, the default), lucide (lucide-*), tabler (tabler-*).
        \\
        \\  add <set>      add the set's @plugin to src/styles.css and download it
        \\  remove <set>   remove it; lists template lines still using its classes
        \\
        ,
        .add =>
        \\Usage: spider add pwa
        \\
        \\Make the app an installable Progressive Web App. Writes public/
        \\manifest.webmanifest (name, start_url, scope, display, icons incl.
        \\maskable), public/sw.js (offline page for page loads, push
        \\notifications; it never caches pages or API responses), public/
        \\offline.html, public/js/pwa.js (registration, $store.pwa.install())
        \\and public/pwa/*.png, and adds a <!-- spider:pwa --> block to the
        \\layouts' <head>.
        \\
        ,
        .remove =>
        \\Usage: spider remove pwa
        \\
        \\Remove the PWA: deletes the manifest, offline page, pwa.js, icons and
        \\the layouts' <head> block, and replaces public/sw.js with one that
        \\clears its caches and unregisters itself in browsers that installed
        \\the app (deleting sw.js would leave them running the old one).
        \\
        ,
        .check =>
        \\Usage: spider check [--strict]
        \\
        \\Check the app follows Spider's conventions and print each problem with
        \\its file, line and fix. Errors (exit 1): a route outside a feature's
        \\routes.zig; a UI kit class (btn, card, ...) in a template instead of
        \\ui-*; an icon class from a set src/styles.css doesn't load; a feature
        \\missing from src/features/mod.zig; with auth, a route that declares no
        \\access. Warnings: inline style=, pasted <svg>, a feature without
        \\routes_test.zig. --strict fails on warnings too (for CI).
        \\
        \\Apps generated by `spider new` run the same checks in `zig build test`.
        \\
        ,
        .dev =>
        \\Usage: spider dev
        \\
        \\Build the app, run it, and replace it after every build that succeeds.
        \\Runs `zig build dev --watch` (incremental on x86_64 Linux), so the app's
        \\build.zig needs the `dev` step: `spider_build.devStep(...)`. While a
        \\build is running or after it fails, the app that is up keeps serving;
        \\the compiler's errors go to this terminal. Ctrl+C stops both.
        \\
        ,
        .install =>
        \\Usage: spider install
        \\
        \\Download the frontend assets into the current project: tailwindcss,
        \\alpine, htmx, daisyUI (when the UI kit uses it) and the icon sets in
        \\src/styles.css.
        \\
        ,
        .update =>
        \\Usage: spider update
        \\
        \\Update the spider dependency in this project's build.zig.zon.
        \\
        ,
        .self_update =>
        \\Usage: spider self-update
        \\
        \\Download and install the latest spider CLI.
        \\
        ,
        .generate_vapid =>
        \\Usage: spider generate-vapid [subject]
        \\
        \\Generate a VAPID key pair for Web Push. `subject` is a mailto: or
        \\https: URL identifying you to push services.
        \\
        ,
        .version =>
        \\Usage: spider version   (also --version, -v)
        \\
        ,
        .help => overview,
    };
}

const t = std.testing;

test "decide: help flags anywhere show help and run nothing" {
    try t.expectEqual(Action{ .help = null }, decide(&.{}));
    try t.expectEqual(Action{ .help = null }, decide(&.{"--help"}));
    try t.expectEqual(Action{ .help = null }, decide(&.{"-h"}));
    try t.expectEqual(Action{ .help = null }, decide(&.{"help"}));
    try t.expectEqual(Action{ .help = .new }, decide(&.{ "help", "new" }));
    try t.expectEqual(Action{ .help = .new }, decide(&.{ "new", "--help" }));
    try t.expectEqual(Action{ .help = .new }, decide(&.{ "new", "app", "-h" }));
    try t.expectEqual(Action{ .help = .generate }, decide(&.{ "g", "feature", "--help" }));
    try t.expectEqual(Action{ .help = .migrate }, decide(&.{ "migrate", "--help" }));
    try t.expectEqual(Action{ .help = .self_update }, decide(&.{ "self-update", "-h" }));
}

test "decide: version, commands, aliases, unknown" {
    try t.expectEqual(Action.version, decide(&.{"--version"}));
    try t.expectEqual(Action.version, decide(&.{"-v"}));
    try t.expectEqual(Action.version, decide(&.{"version"}));
    try t.expectEqual(Action{ .run = .generate }, decide(&.{ "g", "feature", "posts" }));
    try t.expectEqual(Action{ .run = .migrate }, decide(&.{"migrate"}));
    switch (decide(&.{"bogus"})) {
        .unknown_command => |c| try t.expectEqualStrings("bogus", c),
        else => return error.TestUnexpectedResult,
    }
    switch (decide(&.{"--pg"})) {
        .unknown_command => {},
        else => return error.TestUnexpectedResult,
    }
}

test "parseNew: flags, one name, errors" {
    var bad: []const u8 = "";
    const o = try parseNew(&.{ "--pg", "shop", "--skip-downloads" }, &bad);
    try t.expectEqualStrings("shop", o.app_name);
    try t.expect(o.pg and o.skip_downloads and !o.api);

    try t.expectError(error.MissingAppName, parseNew(&.{"--api"}, &bad));
    try t.expectError(error.UnknownOption, parseNew(&.{ "shop", "--postgres" }, &bad));
    try t.expectEqualStrings("--postgres", bad);
    try t.expectError(error.ExtraArgument, parseNew(&.{ "shop", "other" }, &bad));
    try t.expectEqualStrings("other", bad);
}

test "every command has help text" {
    inline for (@typeInfo(Command).@"enum".field_names) |name| {
        try t.expect(commandHelp(@field(Command, name)).len > 0);
    }
}
