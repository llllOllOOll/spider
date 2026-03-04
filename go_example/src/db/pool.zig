const spider_pg = @import("spider_pg");

var pool: ?*spider_pg.Pool = null;

pub fn init(p: *spider_pg.Pool) void {
    pool = p;
}

pub fn get() *spider_pg.Pool {
    return pool orelse @panic("DB pool not initialized");
}
