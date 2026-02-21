const std = @import("std");
const spider = @import("spider");
const web = spider.web;

const controller = @import("controller.zig");

pub const Router = struct {
    pub fn init(app: *spider.Spider) !void {
        const group = app.group("/api/v1");

        try group.get("/products", controller.list);
        try group.get("/products/:id", controller.getById);
        try group.post("/products", controller.create);
        try group.put("/products/:id", controller.update);
        try group.delete("/products/:id", controller.delete);
    }
};
